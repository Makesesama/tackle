defmodule Tackle.Runtime.MessagingTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Runtime.Envelope
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.Messaging

  test "deferred notices retain launch recovery and deliver completion with a full ordinary inbox" do
    scope = start_scope(root: [mode: :manual])
    root = scope.root_agent_ref
    {:ok, %{session_id: session_id}} = Tackle.Runtime.subscribe(root)
    {:ok, turn_id} = Tackle.Runtime.submit(root, "stay busy")
    assert_receive {:adapter_called, task, "echo", _opts}

    Enum.each(1..32, fn n ->
      assert :ok = Tackle.Runtime.tell(root, root, "queued #{n}")
    end)

    assert {:error, :inbox_full} = Tackle.Runtime.tell(root, root, "extra")

    {:ok, launch} =
      Envelope.new(:launch, root, "work started", %{turn_id: turn_id, tool_call_id: "tool-1"})

    {:ok, completion} = Envelope.new(:completion, root, "work finished")
    assert :ok = Messaging.deliver(root, launch)
    assert :ok = Messaging.deliver(root, completion)

    {:ok, session} = Tackle.Runtime.session_pid(root)
    assert Enum.count(Tackle.Session.inbox(session)) == 34

    send(task, {:respond, "first"})
    assert_receive {:adapter_called, next_task, "echo", opts}, 2_000
    messages = Keyword.fetch!(opts, :messages)
    assert Enum.any?(messages, &String.contains?(Map.get(&1, :content, ""), "work finished"))
    refute Enum.any?(messages, &String.contains?(Map.get(&1, :content, ""), "work started"))
    assert [%Envelope{kind: :launch}] = Tackle.Session.inbox(session)

    send(next_task, {:respond, "second"})
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _}}, 2_000
    assert {:ok, _next_turn} = Tackle.Runtime.submit(root, "check launch")
    assert_receive {:adapter_called, final_task, "echo", final_opts}, 2_000

    assert Enum.any?(Keyword.fetch!(final_opts, :messages), fn message ->
             String.contains?(Map.get(message, :content, ""), "work started")
           end)

    send(final_task, {:respond, "done"})
  end

  test "deferred envelope overflow is explicit and separate from ordinary message capacity" do
    scope = start_scope(root: [mode: :manual])
    root = scope.root_agent_ref
    {:ok, turn_id} = Tackle.Runtime.submit(root, "stay busy")
    assert_receive {:adapter_called, task, "echo", _opts}

    Enum.each(1..128, fn n ->
      {:ok, notice} =
        Envelope.new(:launch, root, "started #{n}", %{turn_id: turn_id, tool_call_id: "tool-#{n}"})

      assert :ok = Messaging.deliver(root, notice)
    end)

    {:ok, completion} = Envelope.new(:completion, root, "done")
    assert {:error, :deferred_inbox_full} = Messaging.deliver(root, completion)
    assert :ok = Tackle.Runtime.tell(root, root, "ordinary message")
    send(task, {:respond, "done"})
  end

  test "envelopes validate their kind and scope" do
    first = start_scope()
    second = start_scope()

    assert {:error, :scope_mismatch} =
             Messaging.deliver(
               first.root_agent_ref,
               %Envelope{kind: :completion, from: second.root_agent_ref, message: "done"}
             )

    assert {:error, {:invalid_envelope, _, _, _, _}} =
             Envelope.new(:launch, first.root_agent_ref, "launch")

    assert {:error, {:invalid_envelope, _, _, _, _}} =
             Envelope.new(:completion, first.root_agent_ref, "")
  end

  test "in-scope messages join a busy child's active turn at the next boundary" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        limits: Limits.new!(max_concurrent_turns: 3, max_agents_per_fleet: 3),
        profiles: %{
          "worker" =>
            agent_spec("worker",
              allow_delegation: true,
              mode: :manual,
              content: "first"
            )
        }
      )

    {:ok, child} =
      Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "start",
        retention: :until_collected,
        owner: :parent
      )

    assert_receive {:adapter_called, child_task, "echo", _opts}, 2_000
    assert :ok = Tackle.Runtime.tell(scope.root_agent_ref, child.agent_ref, "new facts")
    assert [%Envelope{from: from, message: "new facts"}] = inbox(child.agent_ref)
    assert from == scope.root_agent_ref

    send(child_task, {:respond, "first"})
    assert_receive {:adapter_called, child_task, "echo", opts}, 2_000

    assert Enum.any?(Keyword.fetch!(opts, :messages), fn
             %{role: :user, content: content} -> content =~ "new facts"
             _message -> false
           end)

    send(child_task, {:respond, "second"})

    assert_eventually(fn ->
      Tackle.Runtime.session_pid(child.agent_ref) == {:error, :not_found}
    end)
  end

  test "messages reject cross-scope routing and bound a recipient inbox" do
    first = start_scope()
    second = start_scope()

    {:ok, _turn_id} = Tackle.submit(first.root_agent_ref, "keep inbox busy")
    assert_receive {:adapter_called, task, "echo", _opts}
    {:ok, session} = Tackle.Runtime.session_pid(first.root_agent_ref)

    :sys.suspend(session)

    callers =
      Enum.map(1..33, fn i ->
        Task.async(fn ->
          Tackle.Runtime.tell(first.root_agent_ref, first.root_agent_ref, "message #{i}")
        end)
      end)

    Process.sleep(20)
    :sys.resume(session)
    results = Task.await_many(callers)
    assert Enum.count(results, &(&1 == :ok)) == 32
    assert Enum.count(results, &(&1 == {:error, :inbox_full})) == 1

    assert {:error, :scope_mismatch} =
             Tackle.Runtime.tell(first.root_agent_ref, second.root_agent_ref, "nope")

    send(task, {:respond, "done"})
    assert_receive {:adapter_called, task, "echo", opts}

    assert Enum.count(Keyword.fetch!(opts, :messages), fn
             %{role: :user, content: content} ->
               String.starts_with?(content, "Message from agent")

             _message ->
               false
           end) == 32

    send(task, {:respond, "done again"})
  end

  defp inbox(agent_ref) do
    {:ok, session} = Tackle.Runtime.session_pid(agent_ref)
    Tackle.Session.inbox(session)
  end

  defp assert_eventually(fun), do: assert(:ok = eventually(fun))
end
