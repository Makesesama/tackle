defmodule Tackle.Runtime.MessagingTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Runtime.Limits

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
    assert [%{from: from, message: "new facts"}] = inbox(child.agent_ref)
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
