defmodule Tackle.Runtime.AgentSupervisor do
  @moduledoc """
  Per-agent execution subtree.

  Every agent receives a dedicated tool `Task.Supervisor`; the backend process
  is the other child. `:one_for_all` with no restarts makes both resources one
  lifecycle unit and prevents an empty agent from being reconstructed.

  When the backend's optional `services/2` callback returns child specs, a
  `Tackle.Runtime.ServiceSupervisor` is appended after the backend process as a
  `:temporary` child. Temporary children never trigger the restart strategy,
  so a failing service, even one exceeding its own restart bound, leaves the
  agent running. It starts after and stops before the backend.
  """

  use Supervisor

  alias Tackle.Runtime.AgentBackend
  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Registry
  alias Tackle.Runtime.ServiceSupervisor

  @doc false
  def start_link({_backend, %AgentSpec{}, %AgentContext{}} = arg) do
    Supervisor.start_link(__MODULE__, arg)
  end

  @doc false
  def child_spec({_backend, %AgentSpec{}, %AgentContext{} = context} = arg) do
    %{
      id: {:runtime_agent, context.agent_ref.agent_id},
      start: {__MODULE__, :start_link, [arg]},
      restart: if(context.kind == :root, do: :permanent, else: :temporary),
      type: :supervisor
    }
  end

  @impl true
  def init({backend, %AgentSpec{} = spec, %AgentContext{} = context}) do
    tool_supervisor = Registry.tool_supervisor_name(context.agent_ref)
    service_task_supervisor = Registry.service_task_supervisor_name(context.agent_ref)

    context = %{
      context
      | tool_supervisor: tool_supervisor,
        service_task_supervisor: service_task_supervisor
    }

    services = AgentBackend.services(backend, spec, context)
    context = if services == [], do: %{context | service_task_supervisor: nil}, else: context

    backend_child =
      backend
      |> then(& &1.child_spec(spec, context))
      |> Supervisor.child_spec(
        id: {:agent_backend, context.agent_ref.agent_id},
        restart: :permanent
      )

    children =
      [{Task.Supervisor, name: tool_supervisor}, backend_child] ++
        service_children(services, context)

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0, max_seconds: 1)
  end

  defp service_children([], _context), do: []

  defp service_children(services, context) do
    [
      {ServiceSupervisor,
       agent_ref: context.agent_ref,
       task_supervisor: context.service_task_supervisor,
       services: services}
    ]
  end
end
