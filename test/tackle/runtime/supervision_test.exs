defmodule Tackle.Runtime.SupervisionTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.Outcome

  test "starting a root agent creates exactly one scope and one shared work supervisor" do
    scope = start_scope()

    assert {:ok, _pid} = Tackle.Runtime.Registry.scope(scope.scope_ref)
    assert {:ok, coordinator} = Tackle.Runtime.Registry.coordinator(scope.scope_ref)
    assert {:ok, _work} = Tackle.Runtime.Registry.work_supervisor(scope.scope_ref)
    assert {:ok, root_ref} = Tackle.Runtime.root_agent_ref(scope.scope_ref)
    assert root_ref == scope.root_agent_ref
    assert {:ok, _session} = Tackle.Runtime.session_pid(root_ref)

    snapshot = scope_snapshot!(scope.scope_ref)
    assert snapshot.agent_count == 1
    assert snapshot.active_turns == 0
    assert {:ok, root_snapshot} = Tackle.Runtime.agent_snapshot(root_ref)
    assert root_snapshot.depth == 0
    assert root_snapshot.status == :live

    assert %{agent_count: 1} = Tackle.AgentScope.Coordinator.snapshot(coordinator)
  end

  test "two root agents are isolated in different scopes" do
    first = start_scope()
    second = start_scope()

    refute first.scope_ref == second.scope_ref
    refute first.root_agent_ref == second.root_agent_ref

    assert {:ok, _} = Tackle.Runtime.session_pid(first.root_agent_ref)
    assert {:ok, _} = Tackle.Runtime.session_pid(second.root_agent_ref)

    :ok = Tackle.Runtime.stop_scope(first.scope_ref)

    assert_eventually(fn ->
      Tackle.Runtime.session_pid(first.root_agent_ref) == {:error, :not_found}
    end)

    assert {:ok, _} = Tackle.Runtime.session_pid(second.root_agent_ref)
    assert {:ok, _} = Tackle.Runtime.scope_snapshot(second.scope_ref)
  end

  test "stopping a scope terminates the root, descendants, and work supervisor" do
    scope =
      start_scope(
        root: [allow_recursion: true],
        profiles: %{"child" => agent_spec("child", mode: :manual)}
      )

    {:ok, run_ref} = Tackle.Runtime.request_agent(scope.root_agent_ref, "child", "work")
    assert_eventually(fn -> match?({:ok, _}, Tackle.Runtime.session_pid(run_ref.agent_ref)) end)
    {:ok, child_session} = Tackle.Runtime.session_pid(run_ref.agent_ref)
    {:ok, work_supervisor} = Tackle.Runtime.Registry.work_supervisor(scope.scope_ref)
    work_monitor = Process.monitor(work_supervisor)
    child_monitor = Process.monitor(child_session)

    assert :ok = Tackle.Runtime.stop_scope(scope.scope_ref)

    assert_receive {:DOWN, ^work_monitor, :process, ^work_supervisor, _reason}, 2_000
    assert_receive {:DOWN, ^child_monitor, :process, ^child_session, _reason}, 2_000

    assert_eventually(fn ->
      Tackle.Runtime.Registry.scope(scope.scope_ref) == {:error, :not_found}
    end)

    assert_eventually(fn ->
      Tackle.Runtime.session_pid(scope.root_agent_ref) == {:error, :not_found}
    end)
  end

  test "a scope-critical root session crash tears down the complete scope" do
    scope = start_scope()
    {:ok, root_session} = Tackle.Runtime.session_pid(scope.root_agent_ref)
    {:ok, work_supervisor} = Tackle.Runtime.Registry.work_supervisor(scope.scope_ref)

    scope_monitor = Process.monitor(scope.pid)
    work_monitor = Process.monitor(work_supervisor)

    Process.exit(root_session, :kill)

    assert_receive {:DOWN, ^scope_monitor, :process, _pid, _reason}, 2_000
    assert_receive {:DOWN, ^work_monitor, :process, ^work_supervisor, _reason}, 2_000

    assert_eventually(fn ->
      Tackle.Runtime.Registry.scope(scope.scope_ref) == {:error, :not_found}
    end)
  end

  test "a descendant crash does not terminate an unrelated sibling" do
    scope =
      start_scope(
        root: [allow_recursion: true],
        profiles: %{
          "crash" => agent_spec("crash", model: "test/echo", mode: :manual),
          "healthy" => agent_spec("healthy", model: "test/child", mode: :manual)
        }
      )

    {:ok, crash_run} = Tackle.Runtime.request_agent(scope.root_agent_ref, "crash", "go")
    {:ok, healthy_run} = Tackle.Runtime.request_agent(scope.root_agent_ref, "healthy", "go")

    assert_eventually(fn -> match?({:ok, _}, Tackle.Runtime.session_pid(crash_run.agent_ref)) end)

    assert_eventually(fn ->
      match?({:ok, _}, Tackle.Runtime.session_pid(healthy_run.agent_ref))
    end)

    {:ok, crash_session} = Tackle.Runtime.session_pid(crash_run.agent_ref)
    crash_monitor = Process.monitor(crash_session)
    Process.exit(crash_session, :kill)
    assert_receive {:DOWN, ^crash_monitor, :process, ^crash_session, _reason}, 2_000

    assert_receive {:adapter_called, healthy_task, "child", _opts}, 2_000
    send(healthy_task, {:respond, "healthy answer"})

    healthy = Tackle.Runtime.await(healthy_run, 5_000)
    assert healthy.status == :ok
    assert Tackle.Runtime.Outcome.answer(healthy) == "healthy answer"

    assert {:ok, root_snapshot} = Tackle.Runtime.agent_snapshot(scope.root_agent_ref)
    assert root_snapshot.status == :live
    assert {:ok, snapshot} = Tackle.Runtime.scope_snapshot(scope.scope_ref)
    assert snapshot.agent_count >= 1
  end

  test "registry entries disappear when their processes terminate" do
    scope =
      start_scope(
        root: [allow_recursion: true],
        profiles: %{"child" => agent_spec("child", mode: :manual)}
      )

    {:ok, run_ref} = Tackle.Runtime.request_agent(scope.root_agent_ref, "child", "go")
    assert_eventually(fn -> match?({:ok, _}, Tackle.Runtime.session_pid(run_ref.agent_ref)) end)
    assert {:ok, _pid} = Tackle.Runtime.Registry.whereis(run_ref)

    assert_receive {:adapter_called, task, _, _opts}, 2_000
    send(task, {:respond, "done"})
    assert %Outcome{status: :ok} = Tackle.Runtime.await(run_ref, 5_000)

    assert_eventually(fn ->
      Tackle.Runtime.session_pid(run_ref.agent_ref) == {:error, :not_found}
    end)

    :ok = Tackle.Runtime.stop_scope(scope.scope_ref)

    assert_eventually(fn ->
      Tackle.Runtime.Registry.whereis(run_ref) == {:error, :not_found}
    end)
  end

  test "limits default to the accepted values and can be narrowed" do
    scope = start_scope(limits: Limits.new!(max_agents_per_fleet: 2, max_concurrent_turns: 1))
    snapshot = scope_snapshot!(scope.scope_ref)

    assert snapshot.limits.max_agents_per_fleet == 2
    assert snapshot.limits.max_concurrent_turns == 1
  end

  defp assert_eventually(fun), do: assert(:ok = eventually(fun))

  defp scope_snapshot!(scope_ref) do
    assert {:ok, snapshot} = Tackle.Runtime.scope_snapshot(scope_ref)
    snapshot
  end
end
