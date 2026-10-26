defmodule Tackle.Runtime.DelegationTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Runtime.Envelope
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.Outcome
  alias Tackle.Session

  defmodule ProgressTool do
    use Tackle.Lib.Tool

    alias Tackle.Lib.Event

    tool_name("progress")
    description("Produces progress during long work")

    def run(_args, context) do
      for _ <- 1..5 do
        Process.sleep(60)
        context.event_callback.(Event.new(:tool_progress, %{delta: "working"}))
      end

      {:ok, "done"}
    end
  end

  test "tool progress keeps a delegated session alive beyond its idle window" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{
          "worker" =>
            agent_spec("worker",
              mode: :tool_then_answer,
              tools: [ProgressTool],
              llm_opts: [
                tool_call: %{"id" => "progress-1", "name" => "progress", "arguments" => %{}}
              ],
              content: "finished"
            )
        }
      )

    {:ok, run_ref} =
      Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "go", timeout: 200)

    assert %Outcome{status: :ok} = outcome = Tackle.Runtime.await(run_ref, 5_000)
    assert Outcome.answer(outcome) == "finished"
  end

  defmodule HoldTurnEndHook do
    @behaviour Tackle.Lib.Hook

    @impl true
    def before_turn_end(_state, context) do
      send(context.test_pid, {:turn_ending, self()})
      receive do: (:proceed -> :ok)
    end
  end

  test "a delegated run answers a message that arrives while its turn ends" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{
          "worker" =>
            agent_spec("worker",
              mode: :echo_messages,
              hooks: [HoldTurnEndHook],
              context: %{test_pid: self()}
            )
        }
      )

    {:ok, run_ref} = Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "go")
    assert_receive {:turn_ending, hook}, 5_000

    # The loop has taken its last queued messages; this one is acknowledged.
    {:ok, child} = Tackle.Runtime.session_pid(run_ref.agent_ref)
    {:ok, envelope} = Envelope.new(:message, scope.root_agent_ref, "note")
    assert :ok = Session.deliver(child, envelope)
    send(hook, :proceed)

    assert_receive {:turn_ending, hook}, 5_000
    send(hook, :proceed)

    assert %Outcome{status: :ok} = outcome = Tackle.Runtime.await(run_ref, 5_000)
    assert Outcome.answer(outcome) =~ "note"
  end

  test "concurrent delegated runs are correlated by run reference" do
    profiles =
      Map.new(1..4, fn i ->
        {"worker#{i}", agent_spec("worker#{i}", mode: :immediate, content: "answer #{i}")}
      end)

    scope = start_scope(root: [allow_delegation: true], profiles: profiles)

    tasks =
      for i <- 1..4 do
        Task.async(fn ->
          {:ok, run_ref} =
            Tackle.Runtime.request_agent(scope.root_agent_ref, "worker#{i}", "prompt #{i}")

          {i, Tackle.Runtime.await(run_ref, 5_000)}
        end)
      end

    for {i, outcome} <- Task.await_many(tasks, 5_000) do
      assert %Outcome{status: :ok} = outcome
      assert Outcome.answer(outcome) == "answer #{i}"
    end
  end

  test "each delegated run receives its own answer" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{
          "alpha" => agent_spec("alpha", model: "test/echo", content: "alpha answer"),
          "beta" => agent_spec("beta", model: "test/child", content: "beta answer")
        }
      )

    {:ok, alpha} = Tackle.Runtime.request_agent(scope.root_agent_ref, "alpha", "go")
    {:ok, beta} = Tackle.Runtime.request_agent(scope.root_agent_ref, "beta", "go")

    alpha_outcome = Tackle.Runtime.await(alpha, 5_000)
    beta_outcome = Tackle.Runtime.await(beta, 5_000)

    assert Outcome.answer(alpha_outcome) == "alpha answer"
    assert Outcome.answer(beta_outcome) == "beta answer"
  end

  test "a provider error settles as a library error with agent state" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{"worker" => agent_spec("worker", mode: :error)}
      )

    {:ok, run_ref} = Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "go")
    outcome = Tackle.Runtime.await(run_ref, 5_000)

    assert %Outcome{status: :error} = outcome
    assert outcome.agent_state
    assert Outcome.library?(outcome)
  end

  test "a turn task crash settles as a runtime error" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{"worker" => agent_spec("worker", mode: :crash)}
      )

    {:ok, run_ref} = Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "go")
    outcome = Tackle.Runtime.await(run_ref, 5_000)

    assert %Outcome{status: :runtime_error} = outcome
    refute Outcome.library?(outcome)
  end

  test "a cancelled delegated run records the runtime's cancellation reason" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{"worker" => agent_spec("worker", mode: :block)}
      )

    root = scope.root_agent_ref
    {:ok, run_ref} = Tackle.Runtime.request_agent(root, "worker", "go")
    assert_receive {:adapter_called, _turn, _model, _opts}, 5_000

    assert {:ok, :cancelling} = Tackle.Runtime.cancel_run(root, run_ref, :stop_now)

    assert %Outcome{status: :cancelled, agent_state: agent_state} =
             Tackle.Runtime.await(root, run_ref, 5_000)

    assert agent_state.error == inspect(:stop_now)
  end

  test "an inactivity timeout settles as timeout and cleans up the child" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{"worker" => agent_spec("worker", mode: :block)}
      )

    {:ok, run_ref} =
      Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "go", timeout: 150)

    assert_eventually(fn -> match?({:ok, _}, Tackle.Runtime.session_pid(run_ref.agent_ref)) end)

    assert %Outcome{status: :timeout} = Tackle.Runtime.await(run_ref, 5_000)

    assert_eventually(fn ->
      Tackle.Runtime.session_pid(run_ref.agent_ref) == {:error, :not_found}
    end)
  end

  test "requester termination cancels and cleans up attached work" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{"worker" => agent_spec("worker", mode: :block)}
      )

    parent = self()

    requester =
      spawn(fn ->
        {:ok, run_ref} =
          Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "go", timeout: 10_000)

        send(parent, {:run_ref, run_ref})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:run_ref, run_ref}, 2_000
    assert_eventually(fn -> match?({:ok, _}, Tackle.Runtime.session_pid(run_ref.agent_ref)) end)

    Process.exit(requester, :kill)

    assert_eventually(fn ->
      Tackle.Runtime.session_pid(run_ref.agent_ref) == {:error, :not_found}
    end)
  end

  test "unknown profiles are rejected by name" do
    scope = start_scope(root: [allow_delegation: true])

    assert {:error, {:unknown_profile, "nope"}} =
             Tackle.Runtime.request_agent(scope.root_agent_ref, "nope", "go")
  end

  test "recursion must be granted by the parent" do
    scope =
      start_scope(root: [allow_delegation: false], profiles: %{"worker" => agent_spec("worker")})

    assert {:error, {:rejected, :delegation_not_allowed}} =
             Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "go")
  end

  test "max_spawn_depth is enforced" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        limits: Limits.new!(max_spawn_depth: 1),
        profiles: %{"worker" => agent_spec("worker", allow_delegation: true, mode: :block)}
      )

    {:ok, run_ref} = Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "go")
    assert_eventually(fn -> match?({:ok, _}, Tackle.Runtime.session_pid(run_ref.agent_ref)) end)

    assert {:error, {:rejected, :max_spawn_depth}} =
             Tackle.Runtime.request_agent(run_ref.agent_ref, "worker", "go")
  end

  test "max_children_per_agent is enforced" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        limits: Limits.new!(max_children_per_agent: 1, max_agents_per_fleet: 16),
        profiles: %{"worker" => agent_spec("worker", mode: :block)}
      )

    {:ok, first} = Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "one")
    assert_eventually(fn -> match?({:ok, _}, Tackle.Runtime.session_pid(first.agent_ref)) end)

    assert {:error, {:rejected, :max_children_per_agent}} =
             Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "two")
  end

  test "max_agents_per_fleet is enforced under concurrent admission" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        limits: Limits.new!(max_agents_per_fleet: 3, max_children_per_agent: 16),
        profiles: %{"worker" => agent_spec("worker", mode: :block)}
      )

    parent = self()

    tasks =
      for i <- 1..4 do
        Task.async(fn ->
          result = Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "p#{i}")
          send(parent, {:request_result, result})

          receive do
            :release -> :ok
          end
        end)
      end

    results =
      for _ <- 1..4 do
        assert_receive {:request_result, result}, 2_000
        result
      end

    admitted = Enum.filter(results, &match?({:ok, _}, &1))

    rejected =
      Enum.filter(results, &match?({:error, {:rejected, :max_agents_per_fleet}}, &1))

    assert [_, _] = admitted
    assert [_, _] = rejected

    Enum.each(tasks, &send(&1.pid, :release))
    Task.await_many(tasks, 2_000)
  end

  defp assert_eventually(fun), do: assert(:ok = eventually(fun))
end
