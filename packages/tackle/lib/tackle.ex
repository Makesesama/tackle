defmodule Tackle do
  @moduledoc """
  Public facade for the frontend-independent Tackle developer harness.

  The harness is started as a *scope*: one root agent plus every descendant it
  creates. Starting a scope returns a PID-free `Tackle.Runtime.Scope` containing
  a `Tackle.Runtime.ScopeRef` for lifecycle operations and the root
  `Tackle.Runtime.AgentRef` for agent operations. Every agent operation addresses
  a stable reference, never a session PID.

      {:ok, scope} = Tackle.start_scope(scope_spec)

      {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
      {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, prompt)

      :ok = Tackle.stop_scope(scope.scope_ref)

  `Tackle.Config.load/1` loads exactly one agent's execution configuration.
  Trusted host or distribution code composes that value into a
  `Tackle.Runtime.AgentSpec` and `Tackle.Runtime.ScopeSpec` before starting the
  runtime.
  """

  alias Tackle.Config
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Scope
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.ScopeSpec
  alias Tackle.Session.Spec, as: SessionSpec
  alias Tackle.Session.Store

  @doc """
  Starts a root-agent scope from a trusted `Tackle.Runtime.ScopeSpec`.

  Returns a PID-free `Tackle.Runtime.Scope`. Invalid delegation grants and
  limits fail validation before any process starts.
  """
  @spec start_scope(ScopeSpec.t()) :: {:ok, Scope.t()} | {:error, term()}
  def start_scope(%ScopeSpec{} = spec), do: Runtime.start_scope(spec)

  @doc "Stops one root scope and every process beneath it."
  @spec stop_scope(ScopeRef.t()) :: :ok | {:error, term()}
  def stop_scope(%ScopeRef{} = scope_ref), do: Runtime.stop_scope(scope_ref)

  @doc "Returns the fleet/scope control-plane snapshot."
  @spec scope_snapshot(ScopeRef.t()) :: {:ok, map()} | {:error, term()}
  def scope_snapshot(%ScopeRef{} = scope_ref), do: Runtime.scope_snapshot(scope_ref)

  @doc "Loads validated frontend-independent configuration through the harness plugin registry."
  @spec load_config(keyword()) :: {:ok, Config.t()} | {:error, term()}
  def load_config(opts \\ []) when is_list(opts), do: Config.load(opts)

  @doc "Returns canonical model references available through configured adapters."
  @spec available_models() :: {:ok, [String.t()]} | {:error, term()}
  def available_models, do: Tackle.Plugins.available_model_refs()

  @doc """
  Monitors the process behind an agent reference without exposing its PID.

  Returns a monitor reference for `{:DOWN, ref, :process, pid, reason}`
  deliveries; stale references return an explicit error.
  """
  @spec monitor_agent(AgentRef.t()) :: {:ok, reference()} | {:error, term()}
  def monitor_agent(%AgentRef{} = agent_ref), do: Runtime.monitor_agent(agent_ref)

  @doc "Starts a turn and appends one user message."
  @spec submit(AgentRef.t(), String.t()) ::
          {:ok, String.t() | :queued} | {:error, term()}
  def submit(%AgentRef{} = agent_ref, input), do: Runtime.submit(agent_ref, input)

  @doc "Continues the conversation without appending another user message."
  @spec continue(AgentRef.t()) :: {:ok, String.t()} | {:error, term()}
  def continue(%AgentRef{} = agent_ref), do: Runtime.continue(agent_ref)

  @doc "Requests cooperative cancellation of the active turn."
  @spec cancel(AgentRef.t()) :: :ok | {:error, term()}
  def cancel(%AgentRef{} = agent_ref), do: Runtime.cancel_turn(agent_ref)

  @doc "Updates model and thinking settings while the agent is idle."
  @spec reconfigure(AgentRef.t(), keyword()) ::
          {:ok, Tackle.Session.Snapshot.t()} | {:error, term()}
  def reconfigure(%AgentRef{} = agent_ref, opts), do: Runtime.reconfigure(agent_ref, opts)

  @doc "Returns the agent's atomic conversation snapshot."
  @spec snapshot(AgentRef.t()) :: {:ok, Tackle.Session.Snapshot.t()} | {:error, term()}
  def snapshot(%AgentRef{} = agent_ref), do: Runtime.session_snapshot(agent_ref)

  @doc """
  Runs one manual compaction of an idle agent's model-visible context.

  The canonical transcript is preserved; only the provider-visible projection
  becomes a synthetic checkpoint plus a verbatim recent tail, committed durably
  before the in-memory replacement is installed. Returns the post-compaction
  snapshot and the durable `Tackle.Lib.Compaction.Record`.
  """
  @spec compact(AgentRef.t(), keyword()) ::
          {:ok, Tackle.Session.Snapshot.t(), Tackle.Lib.Compaction.Record.t()}
          | {:error, term()}
  def compact(%AgentRef{} = agent_ref, opts \\ []), do: Runtime.compact(agent_ref, opts)

  @doc """
  Reads an agent's conversation tree, or `nil` when branching is disabled.
  """
  @spec tree(AgentRef.t()) :: {:ok, Tackle.Lib.Tree.t() | nil} | {:error, term()}
  def tree(%AgentRef{} = agent_ref), do: Runtime.tree(agent_ref)

  @doc """
  Navigates an idle agent's conversation tree.

  Navigation never runs a turn, re-executes a tool, or edits existing entries.
  The destination is persisted before it is installed, and unsafe continuation
  points are rejected with `{:error, {:unsafe_continuation, id}}`. An edit
  target returns the selected user message as a draft.
  """
  @spec navigate(AgentRef.t(), Tackle.Lib.Tree.Navigator.target(), keyword()) ::
          {:ok, Tackle.Session.Snapshot.t(), Tackle.Lib.Tree.Navigator.outcome()}
          | {:error, term()}
  def navigate(%AgentRef{} = agent_ref, target, opts \\ []),
    do: Runtime.navigate(agent_ref, target, opts)

  @doc "Subscribes the caller to correlated session events and terminal outcomes."
  @spec subscribe(AgentRef.t()) :: {:ok, Tackle.Session.Snapshot.t()} | {:error, term()}
  def subscribe(%AgentRef{} = agent_ref), do: Runtime.subscribe(agent_ref)

  @doc "Unsubscribes the caller from session deliveries."
  @spec unsubscribe(AgentRef.t()) :: :ok | {:error, term()}
  def unsubscribe(%AgentRef{} = agent_ref), do: Runtime.unsubscribe(agent_ref)

  @doc """
  Explicitly abandons an interrupted durable turn for an agent.

  A resumed session whose journal ends with `turn.started` and no terminal
  event is interrupted. If unresolved tools may have produced external effects,
  automatic continuation is prohibited until the frontend records the recovery
  decision. This appends `turn.abandoned` and clears the recovery gate.
  """
  @spec abandon_turn(AgentRef.t()) :: :ok | {:error, term()}
  def abandon_turn(%AgentRef{} = agent_ref), do: Runtime.abandon_turn(agent_ref)

  @doc """
  Resumes a durable session into a new root scope.

  The scope spec supplies the trusted agent configuration; the session id
  selects the durable conversation. `opts` may carry `:repair`,
  `:override_config`, `:storage`, and `:cwd`. The recorded model is re-resolved
  through the current adapters unless `:override_config` is set, in which case
  a durable configuration change is recorded.
  """
  @spec resume_session(String.t(), ScopeSpec.t(), keyword()) ::
          {:ok, Scope.t()} | {:error, term()}
  def resume_session(session_id, %ScopeSpec{} = spec, opts \\ []) do
    with {:ok, session} <- SessionSpec.new(Keyword.merge(opts, session_id: session_id)),
         {:ok, spec} <- ScopeSpec.new(%{spec | session: session}) do
      start_scope(spec)
    end
  end

  @doc "Reads and projects a durable session without starting a runtime scope."
  @spec inspect_session(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_session(session_id, opts \\ []), do: Store.inspect_session(session_id, opts)

  @doc "Returns chronological settled token usage for one durable session."
  @spec session_usage_timeline(String.t(), keyword()) ::
          {:ok, Tackle.Session.UsageTimeline.t()} | {:error, term()}
  def session_usage_timeline(session_id, opts \\ []), do: Store.usage_timeline(session_id, opts)

  @doc "Returns chronological settled token usage across every durable session."
  @spec all_usage_timeline(keyword()) ::
          {:ok, Tackle.Session.UsageTimeline.t()} | {:error, term()}
  def all_usage_timeline(opts \\ []), do: Store.all_usage_timeline(opts)

  @doc "Lists durable sessions with stable cursor pagination."
  @spec list_sessions(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def list_sessions(filters \\ %{}), do: Store.list(filters)

  @doc "Searches durable sessions using the default indexed fields."
  @spec search_sessions(String.t(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def search_sessions(query, filters \\ %{}), do: Store.search(query, filters)

  @doc "Returns the derived catalog summary for one session."
  @spec session_summary(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def session_summary(session_id, opts \\ []), do: Store.summary(session_id, opts)

  @doc "Materializes a new self-contained session from validated parent history."
  @spec fork_session(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def fork_session(session_id, opts \\ []), do: Store.fork(session_id, opts)

  @doc "Moves an inactive session into the trash and removes it from the catalog."
  @spec delete_session(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_session(session_id, opts \\ []), do: Store.delete(session_id, opts)

  @doc "Runs an explicit durability barrier for a live durable session."
  @spec flush_session(String.t()) :: :ok | {:error, term()}
  def flush_session(session_id), do: Store.flush(session_id)
end
