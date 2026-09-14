defmodule Tackle.Tools.SubagentAsyncTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Event
  alias Tackle.Runtime.Outcome
  alias Tackle.Tools.{Subagent, SubagentStatus}

  test "background launch survives the tool caller and retains its result until collected" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{"worker" => agent_spec("worker", mode: :manual, content: "worker answer")}
      )

    parent = self()
    handle = handle(scope)

    caller =
      spawn(fn ->
        result =
          Subagent.run(
            %{"profile" => "worker", "prompt" => "do work", "background" => true},
            %{runtime: handle, event_callback: &send(parent, {:event, &1})}
          )

        send(parent, {:launched, result})
      end)

    caller_monitor = Process.monitor(caller)

    assert_receive {:launched, {:ok, launch_message}}, 2_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 2_000
    [run_id] = Regex.run(~r/subagent ([^.]*)\./, launch_message, capture: :all_but_first)

    assert {:ok, "Subagent " <> status} =
             SubagentStatus.run(%{"run_id" => run_id}, %{runtime: handle})

    assert status =~ "still running"

    assert_receive {:adapter_called, child_task, "echo", _opts}, 2_000
    send(child_task, {:respond, "worker answer"})

    assert_eventually(fn ->
      match?({:ok, {:completed, %Outcome{status: :ok}}}, run_status(scope, run_id))
    end)

    assert {:ok, collected} = SubagentStatus.run(%{"run_id" => run_id}, %{runtime: handle})
    assert collected =~ "worker answer"

    assert {:error, message} = SubagentStatus.run(%{"run_id" => run_id}, %{runtime: handle})
    assert message =~ "already collected"
  end

  test "background launch survives parent turn cancellation and the next turn" do
    subagent_call = %{
      "id" => "background-child",
      "name" => "subagent",
      "arguments" => %{
        "profile" => "worker",
        "prompt" => "do work",
        "background" => true
      }
    }

    blocking_call = %{
      "id" => "keep-parent-busy",
      "name" => "blocking",
      "arguments" => %{"name" => "parent"}
    }

    scope =
      start_scope(
        session: session_spec(tree: true),
        root: [
          allow_delegation: true,
          mode: :tools_then_answer,
          tools: [Subagent, Tackle.Test.BlockingTool],
          context: %{test_pid: self()},
          llm_opts: [tool_calls: [subagent_call, blocking_call]]
        ],
        profiles: %{"worker" => agent_spec("worker", model: "test/child", mode: :manual)}
      )

    {:ok, %{session_id: session_id}} = Tackle.Runtime.subscribe(scope.root_agent_ref)
    {:ok, first_turn} = Tackle.Runtime.submit(scope.root_agent_ref, "delegate")

    assert_receive {:tackle_event, ^session_id, ^first_turn,
                    %Event{type: :subagent_started, data: %{run_id: run_id}}},
                   2_000

    assert_receive {:adapter_called, child_task, "child", _opts}, 2_000
    assert_receive {:tool_entered, "parent", _blocking_task}, 2_000
    child_monitor = Process.monitor(child_task)
    {:ok, run_ref} = Tackle.Runtime.RunRef.new(scope.scope_ref.scope_id, run_id)
    {:ok, request} = Tackle.Runtime.Registry.whereis(run_ref)
    request_monitor = Process.monitor(request)

    assert :ok = Tackle.Runtime.cancel_turn(scope.root_agent_ref)

    assert_receive {:tackle_turn_finished, ^session_id, ^first_turn, {:cancelled, _state}},
                   2_000

    assert {:ok, :running} = run_status(scope, run_id)
    refute_receive {:DOWN, ^request_monitor, :process, ^request, _reason}, 20
    refute_receive {:DOWN, ^child_monitor, :process, ^child_task, _reason}, 20
    assert Process.alive?(child_task)

    assert {:ok, second_turn} = Tackle.Runtime.submit(scope.root_agent_ref, "continue")
    assert_receive {:tackle_turn_finished, ^session_id, ^second_turn, {:ok, _state}}, 2_000
    assert {:ok, _session} = Tackle.Runtime.session_pid(scope.root_agent_ref)

    send(child_task, {:respond, "worker answer"})

    assert_eventually(fn ->
      match?({:ok, {:completed, %Outcome{status: :ok}}}, run_status(scope, run_id))
    end)
  end

  test "completion is queued for the parent's next turn" do
    scope =
      start_scope(
        root: [allow_delegation: true, mode: :echo_messages],
        profiles: %{"worker" => agent_spec("worker", content: "worker answer")}
      )

    handle = handle(scope)

    assert {:ok, launch_message} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "do work", "background" => true},
               %{runtime: handle, event_callback: fn _event -> :ok end}
             )

    [run_id] = Regex.run(~r/subagent ([^.]*)\./, launch_message, capture: :all_but_first)

    assert_eventually(fn ->
      match?(
        {:ok, {:completed, %Outcome{status: :ok}}},
        run_status(scope, run_id)
      )
    end)

    {:ok, parent_session} = Tackle.Runtime.session_pid(scope.root_agent_ref)

    assert_eventually(fn ->
      Enum.any?(Tackle.Session.inbox(parent_session), fn envelope ->
        envelope.message =~ "Background subagent #{run_id} completed"
      end)
    end)

    assert {:ok, _turn_id} = Tackle.Runtime.submit(scope.root_agent_ref, "what completed?")

    assert_eventually(fn ->
      is_nil(
        Tackle.Runtime.session_snapshot(scope.root_agent_ref)
        |> elem(1)
        |> Map.get(:active_turn)
      )
    end)

    {:ok, snapshot} = Tackle.Runtime.session_snapshot(scope.root_agent_ref)

    assert Tackle.Lib.last_answer(snapshot.agent_state) =~
             "Background subagent #{run_id} completed"
  end

  test "completion publishes after the launching turn has settled" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{"worker" => agent_spec("worker", mode: :manual, content: "worker answer")}
      )

    {:ok, %{session_id: session_id}} = Tackle.Runtime.subscribe(scope.root_agent_ref)

    assert {:ok, launch_message} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "do work", "background" => true},
               %{runtime: handle(scope), event_callback: fn _event -> :ok end}
             )

    [run_id] = Regex.run(~r/subagent ([^.]*)\./, launch_message, capture: :all_but_first)
    assert_receive {:adapter_called, child_task, "echo", _opts}, 2_000
    send(child_task, {:respond, "worker answer"})

    assert_receive {:tackle_event, ^session_id, nil,
                    %Tackle.Lib.Event{
                      type: :subagent_finished,
                      data: %{run_id: ^run_id, status: :ok}
                    }},
                   2_000
  end

  test "only the logical parent can collect a background run" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{"worker" => agent_spec("worker", mode: :block)}
      )

    {:ok, run_ref} =
      Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "go",
        retention: :until_collected,
        owner: :parent
      )

    other_scope = start_scope(root: [allow_delegation: true])
    other_handle = handle(other_scope)

    assert {:error, message} =
             SubagentStatus.run(%{"run_id" => run_ref.run_id}, %{runtime: other_handle})

    assert message =~ "not found"
    :ok = Tackle.Runtime.cancel(run_ref)
  end

  defp run_status(scope, run_id) do
    {:ok, run_ref} = Tackle.Runtime.RunRef.new(scope.scope_ref.scope_id, run_id)
    Tackle.Runtime.run_status(run_ref)
  end

  defp assert_eventually(fun), do: assert(:ok = eventually(fun))
end
