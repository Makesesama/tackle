defmodule Tackle.AgentScope do
  @moduledoc """
  Physical execution scope for one root agent and every descendant.

  The scope owns the shared work supervisor, admission coordinator, and root
  agent subtree. Backends provide concrete agent processes; the runtime keeps
  their supervision, stable identity, limits, and cancellation generic.
  """

  use Supervisor

  alias Tackle.AgentScope.Coordinator
  alias Tackle.AgentScope.WorkSupervisor
  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.AgentSupervisor, as: RuntimeAgentSupervisor
  alias Tackle.Runtime.ID
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.ScopeSpec

  @doc false
  @spec start_link({ScopeSpec.t(), AgentRef.t()}) :: Supervisor.on_start()
  def start_link({%ScopeSpec{} = spec, %AgentRef{} = root_agent_ref}) do
    Supervisor.start_link(__MODULE__, {spec, root_agent_ref}, name: via(spec.scope_ref))
  end

  @doc false
  def via(%ScopeRef{scope_id: scope_id}) do
    {:via, Registry, {Tackle.Runtime.Registry, {:scope, scope_id}}}
  end

  @doc false
  def child_spec({%ScopeSpec{} = spec, %AgentRef{}} = arg) do
    %{
      id: {:agent_scope, spec.scope_ref.scope_id},
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary,
      type: :supervisor
    }
  end

  @impl true
  def init({%ScopeSpec{} = spec, %AgentRef{} = root_agent_ref}) do
    :ok = register_root(spec.scope_ref, root_agent_ref, spec.backend)

    coordinator = Coordinator.via(spec.scope_ref)
    work_supervisor = WorkSupervisor.via(spec.scope_ref)

    context = %AgentContext{
      kind: :root,
      scope_ref: spec.scope_ref,
      agent_ref: root_agent_ref,
      coordinator: coordinator,
      work_supervisor: work_supervisor,
      lifetime: :explicit,
      allow_delegation: spec.root_spec.allow_delegation,
      limits: spec.limits,
      parent: nil,
      terminal: nil,
      scope_options: spec.session
    }

    children = [
      {WorkSupervisor, spec.scope_ref},
      {Coordinator, %{spec: spec, root_agent_ref: root_agent_ref}},
      {RuntimeAgentSupervisor, {spec.backend, spec.root_spec, context}}
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0, max_seconds: 1)
  end

  defp register_root(%ScopeRef{scope_id: scope_id}, %AgentRef{} = root_ref, backend) do
    values = [
      {{:root_agent, scope_id}, root_ref},
      {{:backend, scope_id}, backend}
    ]

    Enum.each(values, fn {key, value} ->
      case Registry.register(Tackle.Runtime.Registry, key, value) do
        {:ok, _pid} -> :ok
        {:error, {:already_registered, _pid}} -> :ok
      end
    end)

    :ok
  end

  @doc "Mints a root agent reference for a scope spec."
  @spec root_agent_ref(ScopeSpec.t(), String.t() | nil) :: AgentRef.t()
  def root_agent_ref(%ScopeSpec{} = spec, agent_id \\ nil) do
    AgentRef.new!(spec.scope_ref.scope_id, agent_id || ID.generate())
  end
end
