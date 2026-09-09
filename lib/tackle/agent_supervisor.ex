defmodule Tackle.AgentSupervisor do
  @moduledoc """
  Global DynamicSupervisor owning root-agent scopes.

  Scopes are temporary children: they are never restarted. Stopping one scope
  physically terminates everything beneath it. This supervisor owns scopes, not
  individual sessions; descendant work lives under each scope's work
  supervisor.
  """

  use DynamicSupervisor

  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.ScopeSpec

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts one root-agent scope.

  Returns the scope reference and the minted root agent reference so callers can
  address the root agent without a PID.
  """
  @spec start_scope(ScopeSpec.t(), keyword()) ::
          {:ok, %{scope_ref: ScopeRef.t(), root_agent_ref: AgentRef.t(), pid: pid()}}
          | {:error, term()}
  def start_scope(%ScopeSpec{} = spec, opts \\ []) do
    root_agent_ref = Tackle.AgentScope.root_agent_ref(spec, Keyword.get(opts, :root_agent_id))

    case DynamicSupervisor.start_child(__MODULE__, {Tackle.AgentScope, {spec, root_agent_ref}}) do
      {:ok, pid} ->
        {:ok, %{scope_ref: spec.scope_ref, root_agent_ref: root_agent_ref, pid: pid}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Stops one root-agent scope and every process beneath it."
  @spec stop_scope(ScopeRef.t()) :: :ok | {:error, term()}
  def stop_scope(%ScopeRef{} = scope_ref) do
    case Tackle.Runtime.Registry.scope(scope_ref) do
      {:ok, pid} -> terminate(pid)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp terminate(pid) do
    case DynamicSupervisor.terminate_child(__MODULE__, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      other -> other
    end
  end
end
