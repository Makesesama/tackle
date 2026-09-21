defmodule Tackle.Session.RuntimeRootSupervisor do
  @moduledoc false

  use Supervisor

  alias Tackle.Config
  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.RootBackend
  alias Tackle.Session.Spec, as: SessionSpec

  def start_link({%Config{}, %AgentContext{}} = arg) do
    Supervisor.start_link(__MODULE__, arg)
  end

  @impl true
  def init({%Config{} = config, %AgentContext{} = context}) do
    session_spec = session_plan(context.scope_options)
    opts = RootBackend.session_opts(context)
    opts = if session_spec, do: Keyword.put(opts, :durable, session_spec), else: opts

    session_child =
      Supervisor.child_spec({Tackle.Session, {config, opts}},
        id: {:root_session, context.agent_ref.agent_id},
        restart: :permanent
      )

    children = Enum.reverse([session_child | journal_children(config, session_spec)])
    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0, max_seconds: 1)
  end

  defp session_plan(nil), do: nil

  defp session_plan(%SessionSpec{} = session) do
    SessionSpec.with_session_id(session, SessionSpec.session_id(session))
  end

  defp journal_children(_config, nil), do: []

  defp journal_children(%Config{} = config, %SessionSpec{} = session) do
    opts = [
      session_id: session.session_id,
      cwd: session.cwd,
      parent: session.parent,
      repair: session.repair,
      title: session.title,
      tags: session.tags,
      model_ref: session.model_ref || config.model_ref,
      thinking: session.thinking || Tackle.Thinking.from_llm_opts(config.llm_opts),
      tree: session.tree
    ]

    [{Tackle.Session.Journal, opts ++ session.storage}]
  end
end
