defmodule Tackle.Test.SequentialWorkflow do
  @moduledoc false
  use Tackle.Runtime.Workflow

  alias Tackle.Runtime.Outcome

  @impl true
  def init(input), do: {:ok, %{phase: :research}, [{"researcher", input}]}

  @impl true
  def handle_result(_run_ref, outcome, %{phase: :research} = state) do
    {:ok, %{state | phase: :review}, [{"reviewer", "review " <> Outcome.answer(outcome)}]}
  end

  def handle_result(_run_ref, outcome, %{phase: :review} = state) do
    {:ok, %{state | phase: :write}, [{"writer", "write " <> Outcome.answer(outcome)}]}
  end

  def handle_result(_run_ref, outcome, %{phase: :write} = state) do
    {:stop, {:ok, Outcome.answer(outcome)}, state}
  end
end

defmodule Tackle.Test.ParallelWorkflow do
  @moduledoc false
  use Tackle.Runtime.Workflow

  alias Tackle.Runtime.Outcome

  @impl true
  def init(_input),
    do: {:ok, %{phase: :research, results: []}, [{"researcher", "a"}, {"researcher", "b"}]}

  @impl true
  def handle_result(_run_ref, outcome, %{phase: :research} = state) do
    results = [Outcome.answer(outcome) | state.results]

    if length(results) < 2 do
      {:ok, %{state | results: results}}
    else
      prompt = "aggregate " <> Enum.join(Enum.sort(results), ",")
      {:ok, %{state | results: results, phase: :aggregate}, [{"aggregator", prompt}]}
    end
  end

  def handle_result(_run_ref, outcome, %{phase: :aggregate} = state) do
    {:stop, {:ok, Outcome.answer(outcome)}, state}
  end
end

defmodule Tackle.Test.FailingWorkflow do
  @moduledoc false
  use Tackle.Runtime.Workflow

  alias Tackle.Runtime.Outcome

  @impl true
  def init(_input), do: {:ok, :running, [{"worker", "go"}]}

  @impl true
  def handle_result(_run_ref, outcome, state) do
    {:stop, {:ok, Outcome.answer(outcome)}, state}
  end

  @impl true
  def handle_failure(_run_ref, outcome, state) do
    {:stop, {:error, {:worker_failed, outcome.status}}, state}
  end
end

defmodule Tackle.Test.SucceedWorkflow do
  @moduledoc false
  use Tackle.Runtime.Workflow

  alias Tackle.Runtime.Outcome

  @impl true
  def init(_input), do: {:ok, :running, [{"worker", "go"}]}

  @impl true
  def handle_result(_run_ref, outcome, state) do
    {:stop, {:ok, Outcome.answer(outcome)}, state}
  end
end

defmodule Tackle.Runtime.WorkflowTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Runtime
  alias Tackle.Test.{FailingWorkflow, ParallelWorkflow, SequentialWorkflow, SucceedWorkflow}

  test "sequential workflows feed each outcome into the next request" do
    scope =
      start_scope(
        root: [allow_recursion: true],
        profiles: %{
          "researcher" => agent_spec("researcher", mode: :echo_prompt),
          "reviewer" => agent_spec("reviewer", mode: :echo_prompt),
          "writer" => agent_spec("writer", mode: :echo_prompt)
        }
      )

    {:ok, workflow_ref} = Runtime.start_workflow(handle(scope), SequentialWorkflow, "topic")

    assert {:ok, "write review topic"} = Runtime.await_workflow(workflow_ref, 5_000)
  end

  test "parallel workflows overlap and correlate results regardless of completion order" do
    scope =
      start_scope(
        root: [allow_recursion: true],
        profiles: %{
          "researcher" => agent_spec("researcher", mode: :manual),
          "aggregator" => agent_spec("aggregator", mode: :echo_prompt)
        }
      )

    {:ok, workflow_ref} = Runtime.start_workflow(handle(scope), ParallelWorkflow, "topic")

    assert_receive {:adapter_called, first_task, _, _opts}, 2_000
    assert_receive {:adapter_called, second_task, _, _opts}, 2_000

    assert {:ok, snapshot} = Runtime.scope_snapshot(scope.scope_ref)
    assert snapshot.workflow_count == 1

    # Answer out of launch order; correlation must still be unambiguous.
    send(second_task, {:respond, "second"})
    send(first_task, {:respond, "first"})

    assert {:ok, "aggregate first,second"} = Runtime.await_workflow(workflow_ref, 5_000)
  end

  test "child failure follows explicit workflow policy" do
    scope =
      start_scope(
        root: [allow_recursion: true],
        profiles: %{"worker" => agent_spec("worker", mode: :error)}
      )

    {:ok, workflow_ref} = Runtime.start_workflow(handle(scope), FailingWorkflow, "topic")

    assert {:error, {:worker_failed, :error}} = Runtime.await_workflow(workflow_ref, 5_000)
  end

  test "workflow cancellation cancels every outstanding attached run" do
    scope =
      start_scope(
        root: [allow_recursion: true],
        profiles: %{"researcher" => agent_spec("researcher", mode: :block)}
      )

    {:ok, workflow_ref} = Runtime.start_workflow(handle(scope), ParallelWorkflow, "topic")

    assert_receive {:adapter_called, _task, _, _opts}, 2_000
    assert_receive {:adapter_called, _task, _, _opts}, 2_000

    sessions = running_child_sessions(scope)
    assert length(sessions) == 2

    assert :ok = Runtime.cancel(workflow_ref, :user_cancelled)
    assert {:error, {:cancelled, :user_cancelled}} = Runtime.await_workflow(workflow_ref, 5_000)

    assert_eventually(fn -> Enum.all?(sessions, &(not Process.alive?(&1))) end)
  end

  test "a completed workflow terminates and releases scope accounting" do
    scope =
      start_scope(
        root: [allow_recursion: true],
        profiles: %{"worker" => agent_spec("worker", content: "done")}
      )

    {:ok, workflow_ref} =
      Runtime.start_workflow(handle(scope), SucceedWorkflow, "topic")

    assert {:ok, "done"} = Runtime.await_workflow(workflow_ref, 5_000)

    assert_eventually(fn -> Runtime.Registry.workflow(workflow_ref) == {:error, :not_found} end)

    assert {:ok, snapshot} = Runtime.scope_snapshot(scope.scope_ref)
    assert snapshot.workflow_count == 0
  end

  test "unknown workflow run profiles are rejected without starting the workflow" do
    scope = start_scope(root: [allow_recursion: true])

    {:ok, workflow_ref} =
      Runtime.start_workflow(handle(scope), FailingWorkflow, "topic")

    assert {:error, {:request_failed, {:unknown_profile, "worker"}}} =
             Runtime.await_workflow(workflow_ref, 5_000)
  end

  defp running_child_sessions(scope) do
    {:ok, snapshot} = Runtime.scope_snapshot(scope.scope_ref)

    snapshot.agents
    |> Map.values()
    |> Enum.reject(&(&1.depth == 0))
    |> Enum.flat_map(fn agent ->
      case Runtime.session_pid(agent.ref) do
        {:ok, pid} -> [pid]
        {:error, _} -> []
      end
    end)
  end

  defp assert_eventually(fun), do: assert(:ok = eventually(fun))
end
