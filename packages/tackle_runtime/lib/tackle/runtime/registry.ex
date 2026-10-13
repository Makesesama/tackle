defmodule Tackle.Runtime.Registry do
  @moduledoc """
  Unique Registry mapping stable runtime references to live local processes.

  This is the only PID resolution boundary in the runtime. Public APIs accept
  references; internal routing resolves them here. Entries disappear
  automatically when their process terminates; lookups treat an entry whose
  process has already exited as not found.

  Besides scope, coordinator, work-supervisor, agent, and run registrations,
  the registry also holds each agent's per-session tool
  `Task.Supervisor` under `{:tool_supervisor, scope_id, agent_id}` and, for
  agents with services, the service `Task.Supervisor` under
  `{:service_tasks, scope_id, agent_id}`, and named services under
  `{:service, scope_id, agent_id, key}`. Those are process names keyed by
  agent reference, not runtime references of their own.
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

  @doc """
  Returns the via name for an agent's service `Task.Supervisor`.

  The supervisor only exists while the agent runs backend services; see
  `Tackle.Runtime.ServiceSupervisor`.
  """
  @spec service_task_supervisor_name(AgentRef.t()) :: {:via, module(), {module(), tuple()}}
  def service_task_supervisor_name(%AgentRef{scope_id: scope_id, agent_id: agent_id}) do
    {:via, Registry, {@name, {:service_tasks, scope_id, agent_id}}}
  end

  @doc "Returns the live service task supervisor pid for an agent, or an explicit error."
  @spec service_task_supervisor(AgentRef.t()) :: {:ok, pid()} | {:error, :not_found}
  def service_task_supervisor(%AgentRef{scope_id: scope_id, agent_id: agent_id}) do
    Registry.lookup(@name, {:service_tasks, scope_id, agent_id}) |> first()
  end

  @doc """
  Returns the via name a backend service registers under for one agent.

  `key` distinguishes services of the same agent (typically the service
  module), so callers can tell whether a service is running for an agent
  without holding its pid. The registration ends with the process.
  """
  @spec service_name(AgentRef.t(), term()) :: {:via, module(), {module(), tuple()}}
  def service_name(%AgentRef{scope_id: scope_id, agent_id: agent_id}, key) do
    {:via, Registry, {@name, {:service, scope_id, agent_id, key}}}
  end

  @doc "Returns the live pid of an agent's named service, or an explicit error."
  @spec service(AgentRef.t(), term()) :: {:ok, pid()} | {:error, :not_found}
  def service(%AgentRef{scope_id: scope_id, agent_id: agent_id}, key) do
    Registry.lookup(@name, {:service, scope_id, agent_id, key}) |> first()
  end

  @doc "Returns the root agent reference registered for a scope."
  @spec root_agent_ref(Ref.t()) :: {:ok, Tackle.Runtime.AgentRef.t()} | {:error, :not_found}
  def root_agent_ref(ref) do
    case Registry.lookup(@name, {:root_agent, Ref.scope_id(ref)}) do
      [{_pid, %Tackle.Runtime.AgentRef{} = agent_ref}] -> {:ok, agent_ref}
      _other -> {:error, :not_found}
    end
  end

  @doc "Returns the host backend registered for a scope."
  @spec backend(Ref.t()) :: {:ok, module()} | {:error, :not_found}
  def backend(ref) do
    case Registry.lookup(@name, {:backend, Ref.scope_id(ref)}) do
      [{_pid, backend}] when is_atom(backend) -> {:ok, backend}
      _other -> {:error, :not_found}
    end
  end

  # Registry removes a dead process's entries asynchronously, so a lookup can
  # briefly return a process that has already exited. Treat it as gone.
  defp first([{pid, _value}]) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_found}
  end

  defp first(_other), do: {:error, :not_found}
end
