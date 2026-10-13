defmodule Tackle.Runtime.ServiceSupervisor do
  @moduledoc """
  Supervises the backend-provided services of one agent.

  Its first child is a `Task.Supervisor` registered under the agent's
  `Tackle.Runtime.Registry.service_task_supervisor_name/1`, for short-lived
  asynchronous service work; the services from
  `c:Tackle.Runtime.AgentBackend.services/2` follow in order.

  `Tackle.Runtime.AgentSupervisor` starts this supervisor after the backend
  process, as a `:temporary` child, so it stops before the backend and its
  termination never triggers the agent subtree's `:one_for_all` strategy.
  Services are restarted `:one_for_one` within a small bound; once that is
  exceeded the supervisor exits and the agent keeps running without services.

  Services are started after the supervisor initializes, one by one. A service
  that fails to start is logged and skipped rather than preventing the agent
  from starting. Each start runs inside the starting agent subtree, so
  service `init/1` callbacks must be quick and must not call the agent's
  supervisors; calling the already running agent process is safe.
  """

  use Supervisor

  require Logger

  alias Tackle.Runtime.AgentRef

  @max_restarts 3
  @max_seconds 5

  @type option ::
          {:agent_ref, AgentRef.t()}
          | {:task_supervisor, GenServer.name()}
          | {:services, [Supervisor.child_spec() | {module(), term()} | module()]}

  @doc false
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :supervisor
    }
  end

  @doc """
  Starts the supervisor and then each service.

  Options are `:agent_ref`, `:task_supervisor` (the service task supervisor
  name), and `:services` (child specs).
  """
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts) do
    with {:ok, pid} <- Supervisor.start_link(__MODULE__, Keyword.fetch!(opts, :task_supervisor)) do
      agent_ref = Keyword.fetch!(opts, :agent_ref)
      Enum.each(Keyword.fetch!(opts, :services), &start_service(pid, agent_ref, &1))
      {:ok, pid}
    end
  end

  @impl true
  def init(task_supervisor) do
    children = [{Task.Supervisor, name: task_supervisor}]

    Supervisor.init(children,
      strategy: :one_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end

  defp start_service(pid, agent_ref, service) do
    result =
      try do
        Supervisor.start_child(pid, service)
      rescue
        exception -> {:error, {:invalid_service, Exception.message(exception)}}
      catch
        # The supervisor may already have given up on an earlier service.
        :exit, reason -> {:error, {:service_supervisor_unavailable, reason}}
      end

    case result do
      {:ok, _child} ->
        :ok

      {:ok, _child, _info} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "agent service #{inspect(service)} for #{inspect(agent_ref)} " <>
            "failed to start: #{inspect(reason)}"
        )
    end
  end
end
