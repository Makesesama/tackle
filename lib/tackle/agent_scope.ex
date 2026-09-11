defmodule Tackle.AgentScope do
  @moduledoc """
  Physical execution scope for one root agent and every descendant it creates.

  The scope is a static supervisor whose children are the shared work
  supervisor, the scope coordinator, and the root agent session. A scope is a
  temporary child of `Tackle.AgentSupervisor`: it is never restarted, so a
  scope-critical crash terminates the complete scope instead of reconstructing
  empty in-memory state.

  Stopping the scope physically terminates the root agent, all descendants,
  workflows, request helpers, and active turn tasks.
  """

  use Supervisor

  alias Tackle.AgentScope.Coordinator
  alias Tackle.AgentScope.WorkSupervisor
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.ID
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.ScopeSpec
  alias Tackle.Session.Spec, as: SessionSpec

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
    :ok = register_root(spec.scope_ref, root_agent_ref)

    session_spec = session_plan(spec)

    children =
      journal_children(spec, session_spec) ++
        [
          {WorkSupervisor, spec.scope_ref},
          {Coordinator, %{spec: spec, root_agent_ref: root_agent_ref}},
          root_session_child(spec, root_agent_ref, session_spec)
        ]

    Supervisor.init(children,
      strategy: :one_for_all,
      max_restarts: 0,
      max_seconds: 1
    )
  end

  defp session_plan(%ScopeSpec{session: nil}), do: nil

  defp session_plan(%ScopeSpec{session: %SessionSpec{} = session}) do
    SessionSpec.with_session_id(session, SessionSpec.session_id(session))
  end

  defp journal_children(_spec, nil), do: []

  defp journal_children(%ScopeSpec{} = spec, %SessionSpec{} = session) do
    config = spec.root_spec.config

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

  defp register_root(%ScopeRef{scope_id: scope_id}, %AgentRef{} = root_agent_ref) do
    case Registry.register(Tackle.Runtime.Registry, {:root_agent, scope_id}, root_agent_ref) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  defp root_session_child(%ScopeSpec{} = spec, %AgentRef{} = root_agent_ref, session_spec) do
    opts = [
      scope_ref: spec.scope_ref,
      agent_ref: root_agent_ref,
      lifetime: :explicit,
      allow_delegation: spec.root_spec.allow_delegation,
      limits: spec.limits,
      coordinator: Coordinator.via(spec.scope_ref),
      work_supervisor: WorkSupervisor.via(spec.scope_ref),
      restart: :permanent,
      id: {:session, root_agent_ref.agent_id}
    ]

    opts = if session_spec, do: Keyword.put(opts, :durable, session_spec), else: opts

    {Tackle.Session.Supervisor, {spec.root_spec.config, opts}}
  end

  @doc "Mints a root agent reference for a scope spec."
  @spec root_agent_ref(ScopeSpec.t(), String.t() | nil) :: AgentRef.t()
  def root_agent_ref(%ScopeSpec{} = spec, agent_id \\ nil) do
    AgentRef.new!(spec.scope_ref.scope_id, agent_id || ID.generate())
  end
end
