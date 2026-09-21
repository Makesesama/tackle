defmodule Tackle.Runtime.AgentSupervisor do
  @moduledoc """
  Per-agent execution subtree.

  Every agent receives a dedicated tool `Task.Supervisor`; the backend process
  is the other child. `:one_for_all` with no restarts makes both resources one
  lifecycle unit and prevents an empty agent from being reconstructed.
  """

  use Supervisor

  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Runtime.Registry

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
    context = %{context | tool_supervisor: tool_supervisor}

    backend_child =
      backend
      |> then(& &1.child_spec(spec, context))
      |> Supervisor.child_spec(
        id: {:agent_backend, context.agent_ref.agent_id},
        restart: :permanent
      )

    children = [
      {Task.Supervisor, name: tool_supervisor},
      backend_child
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0, max_seconds: 1)
  end
end
