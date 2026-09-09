defmodule Tackle.AgentScope.WorkSupervisor do
  @moduledoc """
  Shared DynamicSupervisor for all descendant work in one root-agent scope.

  It owns descendant agent sessions, workflows, request helpers, and turn tasks.
  There is no supervisor per subagent or workflow: physical scope cleanup is
  provided by the enclosing `Tackle.AgentScope`, while the scope coordinator
  records the logical ownership tree.
  """

  use DynamicSupervisor

  alias Tackle.Runtime.Ref

  @doc false
  @spec start_link(Ref.t()) :: Supervisor.on_start()
  def start_link(scope_ref) do
    DynamicSupervisor.start_link(__MODULE__, scope_ref, name: via(scope_ref))
  end

  @impl true
  def init(_scope_ref) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Starts a temporary child under the scope's work supervisor."
  @spec start_child(Ref.t(), Supervisor.child_spec()) :: DynamicSupervisor.on_start_child()
  def start_child(scope_ref, child_spec) do
    case Tackle.Runtime.Registry.work_supervisor(scope_ref) do
      {:ok, supervisor} -> DynamicSupervisor.start_child(supervisor, child_spec)
      {:error, :not_found} = error -> error
    end
  end

  @doc "Returns the number of live children under the work supervisor."
  @spec count_children(Ref.t()) :: map() | {:error, :not_found}
  def count_children(scope_ref) do
    case Tackle.Runtime.Registry.work_supervisor(scope_ref) do
      {:ok, supervisor} -> DynamicSupervisor.count_children(supervisor)
      {:error, :not_found} = error -> error
    end
  end

  @doc false
  def via(scope_ref),
    do: {:via, Registry, {Tackle.Runtime.Registry, {:work_supervisor, Ref.scope_id(scope_ref)}}}
end
