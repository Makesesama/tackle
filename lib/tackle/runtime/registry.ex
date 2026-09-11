defmodule Tackle.Runtime.Registry do
  @moduledoc """
  Unique Registry mapping stable runtime references to live local processes.

  This is the only PID resolution boundary in the runtime. Public APIs accept
  references; internal routing resolves them here. Entries disappear
  automatically when their process terminates.

  Besides scope, coordinator, work-supervisor, agent, workflow, and run
  registrations, the registry also holds each agent's per-session tool
  `Task.Supervisor` under `{:tool_supervisor, scope_id, agent_id}`. That is a
  process name keyed by agent reference, not a runtime reference of its own.
  """

  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Ref

  @name __MODULE__

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Registry, :start_link, [[keys: :unique, name: @name]]},
      type: :supervisor
    }
  end

  @doc "Registers the calling process under a runtime reference."
  @spec register(Ref.t(), term()) :: {:ok, pid()} | {:error, term()}
  def register(ref, value \\ nil) do
    Registry.register(@name, Ref.registry_key(ref), value)
  end

  @doc "Removes the calling process registration for a runtime reference."
  @spec unregister(Ref.t()) :: :ok
  def unregister(ref) do
    Registry.unregister(@name, Ref.registry_key(ref))
  end

  @doc "Returns the process registered for a reference, or an explicit error."
  @spec whereis(Ref.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(ref), do: Ref.whereis(ref)

  @doc "Returns all live processes registered under a reference key prefix."
  @spec lookup_all(tuple()) :: [{pid(), term()}]
  def lookup_all(key) when is_tuple(key), do: Registry.lookup(@name, key)

  @doc "Returns the scope supervisor pid for a scope reference."
  @spec scope(Ref.t()) :: {:ok, pid()} | {:error, :not_found}
  def scope(ref), do: Registry.lookup(@name, {:scope, Ref.scope_id(ref)}) |> first()

  @doc "Returns the coordinator pid for a scope reference."
  @spec coordinator(Ref.t()) :: {:ok, pid()} | {:error, :not_found}
  def coordinator(ref) do
    Registry.lookup(@name, {:coordinator, Ref.scope_id(ref)}) |> first()
  end

  @doc "Returns the work supervisor pid for a scope reference."
  @spec work_supervisor(Ref.t()) :: {:ok, pid()} | {:error, :not_found}
  def work_supervisor(ref) do
    Registry.lookup(@name, {:work_supervisor, Ref.scope_id(ref)}) |> first()
  end

  @doc """
  Returns the via name for an agent's per-session tool `Task.Supervisor`.

  The name is derived from the agent reference, so tool supervisors stay
  discoverable without dynamic atom generation.
  """
  @spec tool_supervisor_name(AgentRef.t()) :: {:via, module(), {module(), tuple()}}
  def tool_supervisor_name(%AgentRef{scope_id: scope_id, agent_id: agent_id}) do
    {:via, Registry, {@name, {:tool_supervisor, scope_id, agent_id}}}
  end

  @doc "Returns the live tool supervisor pid for an agent, or an explicit error."
  @spec tool_supervisor(AgentRef.t()) :: {:ok, pid()} | {:error, :not_found}
  def tool_supervisor(%AgentRef{scope_id: scope_id, agent_id: agent_id}) do
    Registry.lookup(@name, {:tool_supervisor, scope_id, agent_id}) |> first()
  end

  @doc "Returns the root agent reference registered for a scope."
  @spec root_agent_ref(Ref.t()) :: {:ok, Tackle.Runtime.AgentRef.t()} | {:error, :not_found}
  def root_agent_ref(ref) do
    case Registry.lookup(@name, {:root_agent, Ref.scope_id(ref)}) do
      [{_pid, %Tackle.Runtime.AgentRef{} = agent_ref}] -> {:ok, agent_ref}
      _other -> {:error, :not_found}
    end
  end

  @doc "Returns the workflow server pid for a workflow reference."
  @spec workflow(Ref.t()) :: {:ok, pid()} | {:error, :not_found}
  def workflow(ref), do: Registry.lookup(@name, Ref.registry_key(ref)) |> first()

  @doc "Counts live workflows in one scope."
  @spec workflow_count(Ref.t()) :: non_neg_integer()
  def workflow_count(ref) do
    scope_id = Ref.scope_id(ref)

    @name
    |> Registry.select([{{{:workflow, scope_id, :_}, :_, :_}, [], [true]}])
    |> length()
  end

  defp first([{pid, _value}]) when is_pid(pid), do: {:ok, pid}
  defp first(_other), do: {:error, :not_found}
end
