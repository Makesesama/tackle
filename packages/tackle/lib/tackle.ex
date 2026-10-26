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
  alias Tackle.Session.Compression
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

  @doc "Returns canonical `provider_id/model` references of the available providers."
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

  @doc "Withdraws a matching queued user message before it reaches the agent."
  @spec withdraw_queued(AgentRef.t(), String.t()) :: :ok | {:error, term()}
  def withdraw_queued(%AgentRef{} = agent_ref, content),
    do: Runtime.withdraw_queued(agent_ref, content)

  @doc "Continues the conversation without appending another user message."
  @spec continue(AgentRef.t()) :: {:ok, String.t()} | {:error, term()}
  def continue(%AgentRef{} = agent_ref), do: Runtime.continue(agent_ref)

  @doc """
  Requests cooperative cancellation of the active turn, or of a running manual
  compaction (`compact/2` then returns `{:error, {:cancelled, reason}}`).
  """
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
  snapshot and the durable `Tackle.Lib.Compaction.Record`. `cancel/1` stops a
  running compaction before it commits.
  """
  @spec compact(AgentRef.t(), keyword()) ::
          {:ok, Tackle.Session.Snapshot.t(), Tackle.Lib.Compaction.Record.t()}
          | {:error, term()}
  def compact(%AgentRef{} = agent_ref, opts \\ []), do: Runtime.compact(agent_ref, opts)

  @doc """
  Navigates an idle agent's conversation tree.

  Navigation never runs a turn, re-executes a tool, or edits existing entries.
  The destination is persisted before it is installed, and unsafe continuation
  points are rejected with `{:error, {:unsafe_continuation, id}}`. A session
  without branching rejects navigation with `{:error, :tree_disabled}`. An
  edit target returns the selected user message as a draft.
  """
  @spec navigate(AgentRef.t(), Tackle.Lib.Tree.Navigator.target(), keyword()) ::
          {:ok, Tackle.Session.Snapshot.t(), Tackle.Lib.Tree.Navigator.Outcome.t()}
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

  @doc """
  Lists durable sessions with stable cursor pagination.

  Archived sessions are excluded unless the `:archived` filter is `true`
  (archived only) or `:all`.
  """
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

  @doc """
  Archives an inactive session: it leaves the default listing but stays
  readable and restorable. See `Tackle.Session.Store.archive/2`.
  """
  @spec archive_session(String.t(), keyword()) :: :ok | {:error, term()}
  def archive_session(session_id, opts \\ []), do: Store.archive(session_id, opts)

  @doc "Restores an archived session to the active sessions."
  @spec unarchive_session(String.t(), keyword()) :: :ok | {:error, term()}
  def unarchive_session(session_id, opts \\ []), do: Store.unarchive(session_id, opts)

  @doc """
  Compresses idle session journals and recovery copies in the background-safe
  way described in `Tackle.Session.Compression.compress_idle/1`.

  Compressed sessions stay listable, readable, and resumable. Hosts call this
  periodically, for example when a frontend starts; frequent calls return
  `{:ok, :recently_run}`.
  """
  @spec compress_idle_sessions(keyword()) :: {:ok, map() | :recently_run} | {:error, term()}
  def compress_idle_sessions(opts \\ []), do: Compression.compress_idle(opts)

  @doc "Moves an inactive session into the trash and removes it from the catalog."
  @spec delete_session(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_session(session_id, opts \\ []), do: Store.delete(session_id, opts)

  @doc "Runs an explicit durability barrier for a live durable session."
  @spec flush_session(String.t()) :: :ok | {:error, term()}
  def flush_session(session_id), do: Store.flush(session_id)
end
