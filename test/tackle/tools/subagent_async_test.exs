defmodule Tackle.Test.InterruptedBackgroundSubagent do
  @moduledoc false

  @behaviour Tackle.Lib.Tool

  alias Tackle.Lib.Event
  alias Tackle.Tools.Subagent

  @impl true
  def name, do: "interrupted_background_subagent"

  @impl true
  def description, do: "Starts a background subagent but does not return its launch result."

  @impl true
  def parameters_schema do
    [
      profile: [type: :string, required: true],
      prompt: [type: :string, required: true]
    ]
  end

  @impl true
  def execute(args, context) do
    test_pid = Map.fetch!(context, :test_pid)

    event_callback = fn
      %Event{type: :subagent_started, data: %{run_id: run_id}} ->
        send(test_pid, {:background_launch_paused, self(), run_id})

        receive do
          :return_background_launch -> :ok
        end

      _event ->
        :ok
    end

    args
    |> Map.put("background", true)
    |> Subagent.run(Map.put(context, :event_callback, event_callback))
  end
end

defmodule Tackle.Tools.SubagentAsyncTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Event
  alias Tackle.Runtime.{Outcome, RunRef}
  alias Tackle.Tools.{Subagent, SubagentStatus, SubagentWait}

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

    assert_receive {:event, %Event{type: :subagent_started, data: %{run_id: ^run_id}}}, 2_000

    assert_receive {:event,
                    %Event{
                      type: :subagent_progress,
                      data: %{run_id: ^run_id, event: %Event{type: :turn_start}}
                    }},
                   2_000

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

  test "parent wait blocks for and collects a background result" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{"worker" => agent_spec("worker", mode: :manual)}
      )

    handle = handle(scope)

    assert {:ok, launch_message} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "do work", "background" => true},
               %{runtime: handle}
             )

    [run_id] = Regex.run(~r/subagent ([^.]*)\./, launch_message, capture: :all_but_first)
    assert_receive {:adapter_called, child_task, "echo", _opts}, 2_000

    waiter =
      Task.async(fn -> SubagentWait.run(%{"run_id" => run_id}, %{runtime: handle}) end)

    refute Task.yield(waiter, 20)
    send(child_task, {:respond, "worker answer"})

    assert {:ok, result} = Task.await(waiter, 2_000)
    assert result =~ "Subagent #{run_id} completed"
    assert result =~ "worker answer"

    assert {:error, message} = SubagentStatus.run(%{"run_id" => run_id}, %{runtime: handle})
    assert message =~ "already collected"
  end

  test "cancelling a parent wait leaves the background run available" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{"worker" => agent_spec("worker", mode: :manual)}
      )

    handle = handle(scope)

    assert {:ok, launch_message} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "do work", "background" => true},
               %{runtime: handle}
             )

    [run_id] = Regex.run(~r/subagent ([^.]*)\./, launch_message, capture: :all_but_first)
    assert_receive {:adapter_called, child_task, "echo", _opts}, 2_000

    waiter =
      Task.async(fn -> SubagentWait.run(%{"run_id" => run_id}, %{runtime: handle}) end)

    refute Task.yield(waiter, 20)
    assert nil == Task.shutdown(waiter, :brutal_kill)
    assert {:ok, :running} = run_status(scope, run_id)

    send(child_task, {:respond, "worker answer"})

    assert_eventually(fn ->
      match?({:ok, {:completed, %Outcome{status: :ok}}}, run_status(scope, run_id))
    end)

    assert {:ok, result} = SubagentStatus.run(%{"run_id" => run_id}, %{runtime: handle})
    assert result =~ "worker answer"
  end

  test "parent wait rejects runs owned by another root" do
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

    assert {:error, :not_owner} =
             Tackle.Runtime.await(run_ref.agent_ref, run_ref, :infinity)

    other_scope = start_scope(root: [allow_delegation: true])

    assert {:error, message} =
             SubagentWait.run(%{"run_id" => run_ref.run_id}, %{runtime: handle(other_scope)})

    assert message =~ "not found"
    :ok = Tackle.Runtime.cancel(run_ref)
  end

  test "parent wait validates its context and run id" do
    assert {:error, message} = SubagentWait.run(%{"run_id" => "missing"}, %{})
    assert message =~ "no runtime handle"
    assert {:error, "subagent_wait requires a run_id"} = SubagentWait.run(%{}, %{})
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
    {:ok, run_ref} = RunRef.new(scope.scope_ref.scope_id, run_id)
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

    assert_receive {:tackle_turn_started, ^session_id, automatic_turn, :background_notice}, 2_000

    assert_receive {:tackle_turn_finished, ^session_id, ^automatic_turn, {:ok, _state}}, 2_000
    assert {:ok, _session} = Tackle.Runtime.session_pid(scope.root_agent_ref)
  end

  test "a committed background launch does not duplicate its run id on the next turn" do
    tool_call = %{
      "id" => "committed-background",
      "name" => "subagent",
      "arguments" => %{
        "profile" => "worker",
        "prompt" => "do work",
        "background" => true
      }
    }

    scope =
      start_scope(
        root: [
          allow_delegation: true,
          mode: :tools_then_answer,
          tools: [Subagent],
          llm_opts: [tool_calls: [tool_call]]
        ],
        profiles: %{"worker" => agent_spec("worker", model: "test/child", mode: :manual)}
      )

    {:ok, %{session_id: session_id}} = Tackle.Runtime.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.Runtime.submit(scope.root_agent_ref, "delegate")

    assert_receive {:adapter_called, child_task, "child", _opts}, 2_000
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 2_000
    {:ok, parent} = Tackle.Runtime.session_pid(scope.root_agent_ref)
    assert Tackle.Session.inbox(parent) == []

    send(child_task, {:respond, "worker answer"})
  end

  test "an interrupted background launch gives its run id to the parent's next turn" do
    tool_call = %{
      "id" => "interrupted-background",
      "name" => "interrupted_background_subagent",
      "arguments" => %{"profile" => "worker", "prompt" => "do work"}
    }

    scope =
      start_scope(
        root: [
          allow_delegation: true,
          mode: :tools_then_answer,
          tools: [Tackle.Test.InterruptedBackgroundSubagent],
          context: %{test_pid: self()},
          llm_opts: [tool_calls: [tool_call]]
        ],
        profiles: %{"worker" => agent_spec("worker", model: "test/child", mode: :manual)}
      )

    {:ok, %{session_id: session_id}} = Tackle.Runtime.subscribe(scope.root_agent_ref)
    {:ok, first_turn} = Tackle.Runtime.submit(scope.root_agent_ref, "delegate")

    assert_receive {:adapter_called, _root_task, "echo", _opts}, 2_000
    assert_receive {:background_launch_paused, tool_task, run_id}, 2_000
    assert_receive {:adapter_called, child_task, "child", _opts}, 2_000
    tool_monitor = Process.monitor(tool_task)

    assert {:ok, :running} = run_status(scope, run_id)
    assert :ok = Tackle.Runtime.cancel_turn(scope.root_agent_ref)

    assert_receive {:tackle_turn_finished, ^session_id, ^first_turn,
                    {:cancelled, cancelled_state}},
                   2_000

    refute Enum.any?(cancelled_state.messages, fn message ->
             message.role == :tool and message.tool_call_id == "interrupted-background"
           end)

    assert_receive {:DOWN, ^tool_monitor, :process, ^tool_task, _reason}, 2_000
    {:ok, parent} = Tackle.Runtime.session_pid(scope.root_agent_ref)

    assert [%{message: launch_message}] = Tackle.Session.inbox(parent)
    assert launch_message =~ "Started background subagent #{run_id}."
    assert launch_message =~ "subagent_status"
    assert {:ok, :running} = run_status(scope, run_id)

    {:ok, second_turn} = Tackle.Runtime.submit(scope.root_agent_ref, "continue")
    assert_receive {:adapter_called, _root_task, "echo", second_opts}, 2_000

    assert Enum.any?(Keyword.fetch!(second_opts, :messages), fn
             %{role: :user, content: content} when is_binary(content) -> content =~ run_id
             _message -> false
           end)

    assert :ok = Tackle.Runtime.cancel_turn(scope.root_agent_ref)

    assert_receive {:tackle_turn_finished, ^session_id, ^second_turn, {:cancelled, _state}},
                   2_000

    send(child_task, {:respond, "worker answer"})

    assert_eventually(fn ->
      match?({:ok, {:completed, %Outcome{status: :ok}}}, run_status(scope, run_id))
    end)

    assert {:ok, result} = SubagentStatus.run(%{"run_id" => run_id}, %{runtime: handle(scope)})
    assert result =~ "worker answer"
  end

  test "completion automatically continues an idle parent with the terminal notice" do
    scope =
      start_scope(
        root: [allow_delegation: true, mode: :echo_messages],
        profiles: %{"worker" => agent_spec("worker", content: "worker answer")}
      )

    {:ok, %{session_id: session_id}} = Tackle.Runtime.subscribe(scope.root_agent_ref)

    assert {:ok, launch_message} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "do work", "background" => true},
               %{runtime: handle(scope), event_callback: fn _event -> :ok end}
             )

    assert launch_message =~ "you will be notified"
    [run_id] = Regex.run(~r/subagent ([^.]*)\./, launch_message, capture: :all_but_first)

    assert_receive {:tackle_event, ^session_id, nil,
                    %Event{type: :subagent_finished, data: %{run_id: ^run_id, status: :ok}}},
                   2_000

    assert_receive {:tackle_turn_started, ^session_id, automatic_turn, :background_notice}, 2_000

    assert_receive {:tackle_turn_finished, ^session_id, ^automatic_turn, {:ok, _state}}, 2_000

    {:ok, snapshot} = Tackle.Runtime.session_snapshot(scope.root_agent_ref)

    assert Tackle.Lib.last_answer(snapshot.agent_state) =~
             "Background subagent #{run_id} completed"

    {:ok, parent_session} = Tackle.Runtime.session_pid(scope.root_agent_ref)
    assert Tackle.Session.inbox(parent_session) == []
  end

  test "every non-success terminal state automatically notifies the parent" do
    cases = [
      {:error, :error, %{}, "finished with Failed to get response"},
      {:crash, :runtime_error, %{}, "finished with runtime_error"},
      {:block, :timeout, %{"timeout_ms" => 25}, "finished with timeout"}
    ]

    Enum.each(cases, fn {mode, expected_status, extra_args, expected_notice} ->
      scope =
        start_scope(
          root: [allow_delegation: true, mode: :echo_messages],
          profiles: %{"worker" => agent_spec("worker", mode: mode)}
        )

      {:ok, %{session_id: session_id}} = Tackle.Runtime.subscribe(scope.root_agent_ref)

      args =
        Map.merge(
          %{"profile" => "worker", "prompt" => "do work", "background" => true},
          extra_args
        )

      assert {:ok, launch_message} = Subagent.run(args, %{runtime: handle(scope)})
      [run_id] = Regex.run(~r/subagent ([^.]*)\./, launch_message, capture: :all_but_first)

      assert_receive {:tackle_event, ^session_id, nil,
                      %Event{
                        type: :subagent_finished,
                        data: %{run_id: ^run_id, status: ^expected_status}
                      }},
                     2_000

      assert_receive {:tackle_turn_started, ^session_id, automatic_turn, :background_notice},
                     2_000

      assert_receive {:tackle_turn_finished, ^session_id, ^automatic_turn, {:ok, _state}}, 2_000

      {:ok, snapshot} = Tackle.Runtime.session_snapshot(scope.root_agent_ref)
      answer = Tackle.Lib.last_answer(snapshot.agent_state)
      assert answer =~ "Background subagent #{run_id}"
      assert answer =~ expected_notice
    end)
  end

  test "a cancelled background run automatically notifies the parent" do
    scope =
      start_scope(
        root: [allow_delegation: true, mode: :echo_messages],
        profiles: %{"worker" => agent_spec("worker", mode: :block)}
      )

    {:ok, %{session_id: session_id}} = Tackle.Runtime.subscribe(scope.root_agent_ref)

    assert {:ok, launch_message} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "do work", "background" => true},
               %{runtime: handle(scope)}
             )

    [run_id] = Regex.run(~r/subagent ([^.]*)\./, launch_message, capture: :all_but_first)
    {:ok, run_ref} = RunRef.new(scope.scope_ref.scope_id, run_id)
    assert :ok = Tackle.Runtime.cancel(run_ref)

    assert_receive {:tackle_event, ^session_id, nil,
                    %Event{
                      type: :subagent_finished,
                      data: %{run_id: ^run_id, status: :cancelled}
                    }},
                   2_000

    assert_receive {:tackle_turn_started, ^session_id, automatic_turn, :background_notice}, 2_000
    assert_receive {:tackle_turn_finished, ^session_id, ^automatic_turn, {:ok, _state}}, 2_000

    {:ok, snapshot} = Tackle.Runtime.session_snapshot(scope.root_agent_ref)
    assert Tackle.Lib.last_answer(snapshot.agent_state) =~ "finished with cancelled"
  end

  test "completion waits for an active parent turn to settle before continuing it" do
    scope =
      start_scope(
        root: [allow_delegation: true, mode: :manual],
        profiles: %{
          "worker" => agent_spec("worker", model: "test/child", content: "worker answer")
        }
      )

    {:ok, %{session_id: session_id}} = Tackle.Runtime.subscribe(scope.root_agent_ref)
    assert {:ok, parent_turn} = Tackle.Runtime.submit(scope.root_agent_ref, "stay busy")
    assert_receive {:adapter_called, parent_task, "echo", _opts}, 2_000

    assert {:ok, launch_message} =
             Subagent.run(
               %{"profile" => "worker", "prompt" => "do work", "background" => true},
               %{runtime: handle(scope), event_callback: fn _event -> :ok end}
             )

    [run_id] = Regex.run(~r/subagent ([^.]*)\./, launch_message, capture: :all_but_first)
    assert_receive {:adapter_called, _child_task, "child", _opts}, 2_000

    assert_receive {:tackle_event, ^session_id, nil,
                    %Event{type: :subagent_finished, data: %{run_id: ^run_id, status: :ok}}},
                   2_000

    refute_receive {:tackle_turn_started, ^session_id, _turn_id, :background_notice}, 20

    send(parent_task, {:respond, "parent done"})
    assert_receive {:tackle_turn_finished, ^session_id, ^parent_turn, {:ok, _state}}, 2_000

    assert_receive {:tackle_turn_started, ^session_id, automatic_turn, :background_notice}, 2_000
    assert_receive {:adapter_called, automatic_task, "echo", automatic_opts}, 2_000

    assert Enum.any?(Keyword.fetch!(automatic_opts, :messages), fn
             %{role: :user, content: content} when is_binary(content) ->
               content =~ "Background subagent #{run_id} completed"

             _message ->
               false
           end)

    send(automatic_task, {:respond, "notice handled"})
    assert_receive {:tackle_turn_finished, ^session_id, ^automatic_turn, {:ok, _state}}, 2_000
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
    {:ok, run_ref} = RunRef.new(scope.scope_ref.scope_id, run_id)
    Tackle.Runtime.run_status(run_ref)
  end

  defp assert_eventually(fun), do: assert(:ok = eventually(fun))
end
