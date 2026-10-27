defmodule Tackle.Runtime.AgentContext do
  @moduledoc """
  Trusted runtime context supplied when a backend starts an agent.

  Backends use `register/2` from their agent process during initialization. This
  binds the stable `AgentRef` to the live process and completes coordinator
  admission without exposing PIDs through the public runtime API.

  `tool_supervisor` names the agent's tool `Task.Supervisor`.
  `service_task_supervisor` names the `Task.Supervisor` of the agent's
  `Tackle.Runtime.ServiceSupervisor` and is `nil` when the backend runs no
  services for the agent.

  A delegated agent's events reach its request through the backend's
  `:subscribe` operation (see `Tackle.Runtime.AgentBackend`); the request
  passes them on to its caller's `:event_callback`.
  """

  alias Tackle.AgentScope.Coordinator
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Registry
  alias Tackle.Runtime.ScopeRef

  @enforce_keys [
    :kind,
    :scope_ref,
    :agent_ref,
    :coordinator,
    :work_supervisor,
    :lifetime,
    :allow_delegation,
    :limits
  ]
  defstruct [
    :kind,
    :scope_ref,
    :agent_ref,
    :coordinator,
    :work_supervisor,
    :tool_supervisor,
    :service_task_supervisor,
    :lifetime,
    :allow_delegation,
    :limits,
    :parent,
    :terminal,
    :scope_options
  ]

  @type t :: %__MODULE__{
          kind: :root | :child,
          scope_ref: ScopeRef.t(),
          agent_ref: AgentRef.t(),
          coordinator: GenServer.server(),
          work_supervisor: GenServer.server(),
          tool_supervisor: Supervisor.supervisor() | nil,
          service_task_supervisor: Supervisor.supervisor() | nil,
          lifetime: :explicit | :ephemeral,
          allow_delegation: boolean(),
          limits: Tackle.Runtime.Limits.t(),
          parent: map() | nil,
          terminal: map() | nil,
          scope_options: term()
        }

  @doc "Registers the calling backend process as the live agent for this context."
  @spec register(t(), pid()) :: :ok | {:error, term()}
  def register(%__MODULE__{} = context, pid \\ self()) when is_pid(pid) do
    with {:ok, _pid} <- register_runtime(context.agent_ref, pid) do
      Coordinator.register_agent(context.coordinator, context.agent_ref, pid)
    end
  end

  defp register_runtime(agent_ref, pid) when pid == self() do
    case Registry.register(agent_ref, :agent) do
      {:ok, _pid} -> {:ok, pid}
      {:error, {:already_registered, ^pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_runtime(_agent_ref, _pid), do: {:error, :registration_must_be_called_by_agent}
end
