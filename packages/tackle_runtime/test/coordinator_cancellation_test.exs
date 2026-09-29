defmodule Tackle.AgentScope.CoordinatorCancellationTest do
  use ExUnit.Case, async: true

  alias Tackle.AgentScope.Coordinator
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.ScopeSpec

  defmodule Backend do
    @behaviour Tackle.Runtime.AgentBackend

    @impl true
    def validate_spec(_spec), do: :ok

    @impl true
    def child_spec(_spec, _context), do: {Task, fn -> :ok end}

    @impl true
    def call(_pid, _operation, _args), do: :ok
  end

  setup do
    root_spec = AgentSpec.new!(name: "root", config: %{}, allow_delegation: true)
    child_spec = AgentSpec.new!(name: "child", config: %{}, allow_delegation: true)
    spec = ScopeSpec.new!(backend: Backend, root_spec: root_spec)
    root_ref = AgentRef.new!(spec.scope_ref.scope_id, Tackle.Runtime.ID.generate())
    {:ok, coordinator} = start_supervised({Coordinator, %{spec: spec, root_agent_ref: root_ref}})
    %{coordinator: coordinator, root_ref: root_ref, child_spec: child_spec}
  end

  test "agent snapshot returns scope limits even with pending descendants", %{
    coordinator: coordinator,
    root_ref: root_ref,
    child_spec: child_spec
  } do
    assert {:ok, %{agent_ref: child_ref}} =
             Coordinator.admit_agent(coordinator, root_ref, child_spec)

    limits = Coordinator.snapshot(coordinator).limits
    assert {:ok, %{limits: ^limits}} = Coordinator.agent_snapshot(coordinator, root_ref)
    assert {:ok, %{limits: ^limits}} = Coordinator.agent_snapshot(coordinator, child_ref)
  end

  test "a cancelled pending reservation cannot register, acquire a turn, or admit children", %{
    coordinator: coordinator,
    root_ref: root_ref,
    child_spec: child_spec
  } do
    assert {:ok, %{agent_ref: child_ref}} =
             Coordinator.admit_agent(coordinator, root_ref, child_spec)

    assert :ok = Coordinator.cancel_branch(coordinator, child_ref)
    assert {:error, :cancelled} = Coordinator.register_agent(coordinator, child_ref, self())
    assert {:error, :cancelled} = Coordinator.acquire_turn(coordinator, child_ref)

    assert {:error, {:rejected, :cancelled}} =
             Coordinator.admit_agent(coordinator, child_ref, child_spec)

    assert {:ok, %{cancelled: true, status: :pending, pid: nil}} =
             Coordinator.agent_snapshot(coordinator, child_ref)

    assert %{active_turns: 0, agent_count: 2} = Coordinator.snapshot(coordinator)
  end

  test "branch cancellation blocks live agents and their pending descendants, but not siblings",
       %{
         coordinator: coordinator,
         root_ref: root_ref,
         child_spec: child_spec
       } do
    assert :ok = Coordinator.register_agent(coordinator, root_ref, self())

    assert {:ok, %{agent_ref: branch}} =
             Coordinator.admit_agent(coordinator, root_ref, child_spec)

    assert :ok = Coordinator.register_agent(coordinator, branch, self())
    assert :ok = Coordinator.acquire_turn(coordinator, branch)
    assert {:ok, %{agent_ref: pending}} = Coordinator.admit_agent(coordinator, branch, child_spec)

    assert {:ok, %{agent_ref: sibling}} =
             Coordinator.admit_agent(coordinator, root_ref, child_spec)

    assert :ok = Coordinator.cancel_branch(coordinator, branch)
    assert_receive {:runtime_cancel, :cancelled}
    assert {:error, :cancelled} = Coordinator.acquire_turn(coordinator, branch)
    assert {:error, :cancelled} = Coordinator.register_agent(coordinator, pending, self())

    assert {:error, {:rejected, :cancelled}} =
             Coordinator.admit_agent(coordinator, pending, child_spec)

    assert :ok = Coordinator.register_agent(coordinator, sibling, self())
    assert :ok = Coordinator.acquire_turn(coordinator, sibling)
    assert :ok = Coordinator.release_turn(coordinator, branch)
    assert {:ok, %{cancelled: true}} = Coordinator.agent_snapshot(coordinator, pending)
    assert %{active_turns: 1} = Coordinator.snapshot(coordinator)
  end

  test "scope cancellation prevents pending registration", %{
    coordinator: coordinator,
    root_ref: root_ref
  } do
    assert :ok =
             Coordinator.cancel_branch(
               coordinator,
               Tackle.Runtime.ScopeRef.new!(root_ref.scope_id)
             )

    assert {:error, :cancelled} = Coordinator.register_agent(coordinator, root_ref, self())
  end
end
