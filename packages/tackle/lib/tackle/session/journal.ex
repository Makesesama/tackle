defmodule Tackle.Session.Journal do
  @moduledoc """
  Supervised owner of one append-only session journal.

  Exactly one `Journal` process owns one `:disk_log` in `:internal`, `:halt`
  mode. It assigns the monotonic session sequence, validates each commit,
  applies the durability barrier, owns the log lifecycle, and exposes one narrow
  API to the session and its internal persistence hook. Callers never open or
  write the journal file directly.

  ## Write-behind appends

  Loop-driven facts (`append_message/4` and `tool_started/3` with
  `sync: false`), `turn.started`, and terminal events are validated,
  sequenced, and appended in order, but not synced. `:disk_log` hands them to
  the OS within about two seconds, after which they survive an application
  crash; only power loss or a kernel crash can lose them. They become durable
  at the next sync: any synced commit or `flush/1` covers everything appended
  before it, so one sync settles a whole batch.
  The host calls `await_durable/1` before effects that must not happen without
  a durable record (tools with external effects). A crash can lose the
  appended-but-unsynced tail; replay then sees a consistent prefix, and a tool
  intent without a durable result is reported as uncertain. Unlike `flush/1`,
  `await_durable/1` does not touch the disk when nothing is unsynced.
  `await_idle/1` waits behind earlier requests (for example a stalled sync)
  without syncing. The derived catalog is updated at sync points and when a
  turn settles.

  Durable operations are guarded by an independent watchdog. A missed deadline
  stops the owner and its durable scope rather than abandoning a request while
  execution continues. The commit outcome may be unknown: replay is required
  before any retry. Diagnostics contain stage and stack information, not payloads.

  ## Rejections and failures

  A request the journal refuses before writing anything returns
  `{:error, reason}` and leaves the journal usable: an invalid message, tool
  call, settlement, or commit, including one that does not fold into the
  projection (`{:invalid_commit, reason}`, for example a duplicate entry id or
  a navigation to an unknown entry); a branch in a session without branching
  (`:tree_disabled`); a write without an active turn (`:no_active_turn`); or a
  settlement of another turn (`:turn_mismatch`). The caller decides what the
  refusal means for its own state.

  Anything that fails once bytes may have been written (append, sync, a lost
  writer lock, a `:disk_log` error notification), and a storage failure while
  opening, is fatal to further durable execution: the owner stops, which
  terminates its durable scope rather than continuing with memory-only state,
  and the caller receives `{:error, {:journal_failure, reason}}`.
  """

  use GenServer, restart: :permanent
  require Logger

  alias Tackle.Config
  alias Tackle.Lib.Message
  alias Tackle.Lib.Thinking
  alias Tackle.Lib.Tree
  alias Tackle.Lib.Tree.Change
  alias Tackle.Runtime.ID
  alias Tackle.Session.Catalog
  alias Tackle.Session.Codec
  alias Tackle.Session.Compression
  alias Tackle.Session.Journal.Watchdog
  alias Tackle.Session.Log
  alias Tackle.Session.Projection
  alias Tackle.Session.ProjectionError
  alias Tackle.Session.Reader
  alias Tackle.Session.Storage
  alias Tackle.Session.Storage.Lock
  alias Tackle.StatusRedaction

  @registry Tackle.Session.JournalRegistry
  @call_timeout 60_000
  # Lets the watchdog's guarded cleanup deadline expire before the supervisor
  # kills the owner, so a stalled cleanup still leaves its diagnostic.
  @shutdown_margin 1_000

  @type turn :: %{turn_id: String.t(), operation: atom()}

  @type state :: %{
          session_id: String.t(),
          path: String.t(),
          name: tuple() | nil,
          lock: Tackle.Session.Storage.Lock.t() | nil,
          next_seq: pos_integer() | nil,
          synced_seq: non_neg_integer() | nil,
          projection: Projection.t() | nil,
          active_turn: turn() | nil,
          recovered: map() | nil,
          materialized?: boolean(),
          open_opts: keyword() | nil
        }

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {:session_journal, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: shutdown(opts),
      type: :worker
    }
  end

  # Closing the log, writing the summary sidecar, and releasing the lock may
  # take up to the journal timeout, which the watchdog enforces.
  defp shutdown(opts) do
    case Watchdog.timeout(opts) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout + @shutdown_margin
      _invalid -> 5_000
    end
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @doc "Returns the registry key for a session journal."
  @spec via(String.t()) :: GenServer.name()
  def via(session_id) do
    {:via, Registry, {@registry, {:session_journal, session_id}}}
  end

  @doc "Resolves the live journal owner for a session id."
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(session_id) do
    case Registry.lookup(@registry, {:session_journal, session_id}) do
      [{pid, _value}] when is_pid(pid) -> {:ok, pid}
      _other -> {:error, :not_found}
    end
  end

  @spec begin_turn(GenServer.server(), :run | :continue | :repair, String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def begin_turn(journal, operation, input)
      when operation in [:run, :continue, :repair] do
    begin_turn(journal, operation, input, ID.generate())
  end

  @doc """
  Appends `turn.started` (write-behind) before the turn task may begin.

  The caller mints the turn id so library events, terminal outcomes, and
  durable commits all correlate on one identifier. Returns the turn id once
  the commit is appended; it becomes durable at the next sync.
  """
  @spec begin_turn(GenServer.server(), :run | :continue | :repair, String.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def begin_turn(journal, operation, input, turn_id)
      when operation in [:run, :continue, :repair] and is_binary(turn_id) do
    durable_call(journal, {:begin_turn, operation, input, turn_id})
  end

  @doc """
  Persists a settled message on the current turn.

  By default the commit is synced before this returns. With `sync: false` it is
  appended in order and becomes durable at the next sync or `flush/1`; see
  "Write-behind appends".

  `parent` is `:none`, which attaches the message to the active entry, or
  `{:tree, parent_id}`, the tree entry it attaches to (`nil` for a new root),
  which a branching session commits with the message payload. A session
  without branching keeps its journal format: a parent that is the active
  entry is not written, and any other is refused with
  `{:error, :tree_disabled}`.
  """
  @spec append_message(GenServer.server(), Message.t(), term(), keyword()) ::
          :ok | {:error, term()}
  def append_message(journal, %Message{} = message, parent \\ :none, opts \\ []),
    do: durable_call(journal, {:append_message, message, parent, sync?(opts)})

  @doc """
  Persists tool execution intent before the tool is invoked.

  Accepts `sync: false` like `append_message/4`. The caller must then call
  `await_durable/1` before the tool runs.
  """
  @spec tool_started(GenServer.server(), map(), keyword()) :: :ok | {:error, term()}
  def tool_started(journal, call, opts \\ []),
    do: durable_call(journal, {:tool_started, call, sync?(opts)})

  @doc """
  Persists one durable compaction replacement.

  The event data replaces the model-surface prefix with `summary_message` while
  the canonical transcript is untouched. The commit is appended to the active
  turn when one exists and synced before the caller installs the in-memory
  replacement. Like `append_message/4`, a session without branching keeps its
  format: a `"parent_id"` that is the active entry is not written, and any
  other is refused with `{:error, :tree_disabled}`.
  """
  @spec context_compacted(GenServer.server(), map()) :: :ok | {:error, term()}
  def context_compacted(journal, data), do: durable_call(journal, {:context_compacted, data})

  @doc """
  Settles a turn with a terminal event (write-behind).

  The turn is the active one or, in a journal opened with an interrupted turn,
  that turn. A `"turn_id"` in `data` must name it; without one the turn is
  implied. Settling another turn, or a turn twice, is refused with
  `{:error, :turn_mismatch}`; with no turn to settle the error is
  `{:error, :no_active_turn}`.
  """
  @spec settle_turn(GenServer.server(), atom(), map()) :: :ok | {:error, term()}
  def settle_turn(journal, type, data \\ %{}),
    do: durable_call(journal, {:settle_turn, type, data})

  @doc """
  Persists one committed navigation before the library installs it.

  Navigation is durable on its own, so a session that is resumed after the
  user exits without sending another prompt restores the selected position,
  including the position before the first message.
  """
  @spec tree_navigated(GenServer.server(), Change.t()) :: :ok | {:error, term()}
  def tree_navigated(journal, %Change{} = change),
    do: durable_call(journal, {:tree_navigated, change})

  @doc """
  Records the explicit `tree.enabled` transition for a legacy linear session.

  The durable file is not rewritten; the event only records that later writes
  may branch. An already-enabled or unmaterialized session is a no-op.
  """
  @spec enable_tree(GenServer.server()) :: :ok | {:error, term()}
  def enable_tree(journal), do: durable_call(journal, :enable_tree)

  @doc "Persists an accepted idle configuration change."
  @spec configuration_changed(GenServer.server(), Config.t()) :: :ok | {:error, term()}
  def configuration_changed(journal, %Config{} = config),
    do: durable_call(journal, {:configuration_changed, config})

  @doc "Persists session metadata such as title and tags."
  @spec metadata_changed(GenServer.server(), map()) :: :ok | {:error, term()}
  def metadata_changed(journal, attrs), do: durable_call(journal, {:metadata_changed, attrs})

  @doc "Runs an explicit durability barrier: always syncs the journal."
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(journal), do: durable_call(journal, :flush)

  @doc """
  Returns once every appended commit is durable.

  Syncs only when a write-behind commit is still unsynced; otherwise it returns
  `:ok` without touching the disk. Requests are serialized, so it also waits
  behind any sync already in progress.
  """
  @spec await_durable(GenServer.server()) :: :ok | {:error, term()}
  def await_durable(journal), do: durable_call(journal, :await_durable)

  @doc """
  Returns once every journal request admitted before this one has completed.

  It never syncs. A caller uses it to stay behind a busy or paused journal, so
  it makes no progress while storage is stalled, and to observe a failed
  journal as an error.
  """
  @spec await_idle(GenServer.server()) :: :ok | {:error, term()}
  def await_idle(journal), do: durable_call(journal, :await_idle)

  @doc """
  Returns the journal's durable projection.

  A new session that has not received its first prompt is not materialized yet,
  so it returns a provisional, empty projection carrying the metadata that
  `session.created` will record. It contains no history and no durable file.
  """
  @spec projection(GenServer.server()) :: {:ok, Projection.t()} | {:error, term()}
  def projection(journal), do: call(journal, :projection)

  @doc "Returns the derived catalog summary for this session."
  @spec summary(GenServer.server()) :: {:ok, map() | nil} | {:error, term()}
  def summary(journal), do: call(journal, :summary)

  @doc "Returns the live journal status (session id, last sequence, health)."
  @spec status(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def status(journal), do: call(journal, :status)

  @doc """
  Persistence-hook entry point: persists a settled message by session id.

  Sessions without a journal — ephemeral delegated agents — are a no-op so the
  same hook module can be installed unconditionally. `parent` is `:none` or
  `{:tree, parent_id}`; see `append_message/4`.
  """
  @spec persist_message(String.t(), Message.t(), term()) :: :ok | {:error, term()}
  def persist_message(session_id, %Message{} = message, parent \\ :none) do
    with_journal(session_id, &append_message(&1, message, parent))
  end

  @doc "Persistence-hook entry point: persists a tool intent by session id."
  @spec persist_tool_started(String.t(), map()) :: :ok | {:error, term()}
  def persist_tool_started(session_id, call) do
    with_journal(session_id, &tool_started(&1, call))
  end

  @doc "Persistence-hook entry point: persists a compaction replacement by session id."
  @spec persist_compaction(String.t(), map()) :: :ok | {:error, term()}
  def persist_compaction(session_id, data) do
    with_journal(session_id, &context_compacted(&1, data))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    session_id = Keyword.fetch!(opts, :session_id)

    with {:ok, _watchdog} <- Watchdog.start(self(), session_id, opts),
         {:ok, path} <- Storage.journal_path(session_id, opts),
         {:ok, state} <- open_or_defer(session_id, path, opts) do
      Watchdog.ready(self())
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # A new durable session is materialized on its first prompt, not when a scope
  # starts. The owner process exists immediately so the runtime can fail closed
  # and address the journal, but no directory, ownership lock, log file, or
  # catalog entry is created until there is real work to persist. An existing
  # journal is opened and validated eagerly so resume never fabricates history:
  # its lock is taken without creating a directory, and a journal moved away
  # (archived or trashed) before the lock was held is reported as not found.
  defp open_or_defer(session_id, path, opts) do
    if Storage.journal_exists?(session_id, opts) do
      open_existing(session_id, opts)
    else
      {:ok, deferred_state(session_id, path, opts)}
    end
  end

  defp open_existing(session_id, opts) do
    repair? = Keyword.get(opts, :repair, false)

    Watchdog.stage(self(), :acquire_lock)

    with {:ok, lock} <- Storage.acquire_existing_lock(session_id, opts) do
      Watchdog.lock(self(), lock)
      Watchdog.stage(self(), :open_replay)

      case open_writable(session_id, Keyword.put(opts, :repair, repair?)) do
        {:ok, opened} ->
          build_state(session_id, lock, opened, opts)

        {:error, reason} ->
          Storage.release_lock(lock)
          Watchdog.lock(self(), nil)
          {:error, {:journal_open_failed, session_id, reason}}
      end
    end
  end

  # Runs under the writer lock: an idle journal stored compressed is restored
  # to a plain journal before the owner opens it.
  defp open_writable(session_id, opts) do
    with {:ok, path} <- Storage.journal_path(session_id, opts),
         :ok <- Compression.restore(path) do
      Reader.open_writable(session_id, opts)
    end
  end

  defp deferred_state(session_id, path, opts) do
    %{
      session_id: session_id,
      path: path,
      name: nil,
      lock: nil,
      next_seq: nil,
      synced_seq: nil,
      projection: nil,
      active_turn: nil,
      recovered: nil,
      materialized?: false,
      open_opts: opts
    }
  end

  defp ensure_materialized(%{materialized?: true} = state), do: {:ok, state}

  defp ensure_materialized(%{materialized?: false} = state) do
    Watchdog.stage(self(), :acquire_lock)

    case Storage.acquire_lock(state.session_id, state.open_opts) do
      {:ok, lock} ->
        Watchdog.lock(self(), lock)
        Watchdog.stage(self(), :open_replay)

        case open_writable(state.session_id, state.open_opts) do
          {:ok, opened} ->
            build_state(state.session_id, lock, opened, state.open_opts)

          {:error, reason} ->
            Storage.release_lock(lock)
            Watchdog.lock(self(), nil)
            {:error, {:journal_open_failed, state.session_id, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def handle_call({:begin_turn, operation, input, turn_id}, _from, state) do
    case ensure_materialized(state) do
      {:error, reason} ->
        fail(state, reason)

      {:ok, %{active_turn: active_turn} = state} when is_map(active_turn) ->
        {:reply, {:error, :turn_in_progress}, state}

      {:ok, state} ->
        event =
          Log.event("turn.started", %{
            "turn_id" => turn_id,
            "operation" => Atom.to_string(operation),
            "input" => input,
            "started_at" => now()
          })

        # Write-behind: the turn becomes durable with the first external tool
        # gate or a later sync. A turn lost to power loss has caused no external
        # effect yet, so it simply did not happen.
        case commit(state, [event], turn_id, false) do
          {:ok, state, _seq} ->
            turn = %{turn_id: turn_id, operation: operation}
            state = %{state | active_turn: turn}
            # No sync happens here, so show the running turn in the catalog now.
            record_catalog(state, state.next_seq - 1)
            {:reply, {:ok, turn_id}, state}

          error ->
            refuse_or_fail(state, error)
        end
    end
  end

  def handle_call({:context_compacted, _data}, _from, %{materialized?: false} = state) do
    {:reply, {:error, :no_journal}, state}
  end

  def handle_call({:context_compacted, data}, _from, state) do
    with {:ok, data} <- compaction_data(state.projection, data),
         event = Log.event("context.compacted", data),
         {:ok, state, _seq} <- commit(state, [event], state_active_turn_id(state)) do
      {:reply, :ok, state}
    else
      error -> refuse_or_fail(state, error)
    end
  end

  def handle_call({:append_message, %Message{} = message, parent, sync?}, _from, state) do
    Watchdog.stage(self(), :encode_message, state.next_seq)

    with {:ok, turn_id} <- active_turn_id(state),
         {:ok, parent} <- journal_parent(state.projection, parent),
         {:ok, event} <- message_event(message, parent),
         {:ok, state, _seq} <- commit(state, [event], turn_id, sync?) do
      {:reply, :ok, state}
    else
      error -> refuse_or_fail(state, error)
    end
  end

  def handle_call({:tool_started, call, sync?}, _from, state) do
    with {:ok, turn_id} <- active_turn_id(state),
         {:ok, event} <- tool_event(call),
         {:ok, state, _seq} <- commit(state, [event], turn_id, sync?) do
      {:reply, :ok, state}
    else
      error -> refuse_or_fail(state, error)
    end
  end

  def handle_call({:settle_turn, _type, _data}, _from, %{materialized?: false} = state) do
    {:reply, {:error, :no_active_turn}, state}
  end

  def handle_call({:tree_navigated, _change}, _from, %{materialized?: false} = state) do
    {:reply, {:error, :no_journal}, state}
  end

  def handle_call({:tree_navigated, %Change{} = change}, _from, state) do
    event =
      Log.event("tree.navigated", %{
        "from_id" => change.from_id,
        "to_id" => change.to_id,
        "selected_id" => change.selected_id,
        "mode" => Atom.to_string(change.mode),
        "revision" => change.revision,
        "navigated_at" => now()
      })

    case commit(state, [event], state_active_turn_id(state)) do
      {:ok, state, _seq} -> {:reply, :ok, state}
      error -> refuse_or_fail(state, error)
    end
  end

  def handle_call(:enable_tree, _from, %{materialized?: false} = state) do
    {:reply, :ok, %{state | open_opts: Keyword.put(state.open_opts, :tree, true)}}
  end

  def handle_call(:enable_tree, _from, %{projection: %Projection{tree_enabled?: true}} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:enable_tree, _from, state) do
    event = Log.event("tree.enabled", %{"enabled_at" => now()})

    case commit(state, [event], nil) do
      {:ok, state, _seq} -> {:reply, :ok, state}
      error -> refuse_or_fail(state, error)
    end
  end

  # Write-behind: the OS writes the settled turn back on its own schedule, so
  # an app crash keeps it; only power loss can lose the last turns.
  def handle_call({:settle_turn, type, data}, _from, state) do
    with {:ok, event, turn_id} <- settle_event(state, type, data),
         {:ok, state, seq} <- commit(state, [event], turn_id, false) do
      state = %{state | active_turn: nil}
      record_catalog(state, seq)
      {:reply, :ok, state}
    else
      error -> refuse_or_fail(state, error)
    end
  end

  # Reconfiguring or retitling an unmaterialized session only updates the
  # metadata that will be written into `session.created`; it must never create
  # a durable session on its own.
  def handle_call(
        {:configuration_changed, %Config{} = config},
        _from,
        %{materialized?: false} = state
      ) do
    {:reply, :ok, %{state | open_opts: update_creation_config(state.open_opts, config)}}
  end

  def handle_call({:configuration_changed, %Config{} = config}, _from, state) do
    # Recorded like `session.created`: the normalized level, never a raw
    # provider-specific option. Journals written before recorded the raw value
    # (`nil` when unset), which `Tackle.Session.Loader` still reads.
    event =
      Log.event("session.configuration_changed", %{
        "model_ref" => config.model_ref,
        "thinking" => Thinking.from_llm_opts(config.llm_opts),
        "changed_at" => now()
      })

    case commit(state, [event], nil) do
      {:ok, state, _seq} -> {:reply, :ok, state}
      error -> refuse_or_fail(state, error)
    end
  end

  def handle_call({:metadata_changed, attrs}, _from, %{materialized?: false} = state) do
    {:reply, :ok, %{state | open_opts: update_creation_metadata(state.open_opts, attrs)}}
  end

  def handle_call({:metadata_changed, attrs}, _from, state) do
    event = Log.event("session.metadata_changed", Map.put_new(attrs, "changed_at", now()))

    case commit(state, [event], nil) do
      {:ok, state, _seq} -> {:reply, :ok, state}
      error -> refuse_or_fail(state, error)
    end
  end

  def handle_call(barrier, _from, %{materialized?: false} = state)
      when barrier in [:flush, :await_durable, :await_idle],
      do: {:reply, :ok, state}

  def handle_call(:await_idle, _from, state), do: {:reply, :ok, state}

  def handle_call(barrier, _from, state) when barrier in [:flush, :await_durable] do
    case sync_appended(state, barrier == :flush) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> fail(state, reason)
    end
  end

  def handle_call(:projection, _from, %{materialized?: false} = state),
    do: {:reply, {:ok, provisional_projection(state)}, state}

  def handle_call(:projection, _from, state) do
    {:reply, {:ok, state.projection}, state}
  end

  def handle_call(:summary, _from, %{materialized?: false} = state),
    do: {:reply, {:ok, nil}, state}

  def handle_call(:summary, _from, state) do
    {:reply, {:ok, build_summary(state)}, state}
  end

  def handle_call(:status, _from, %{materialized?: false} = state) do
    status = %{
      session_id: state.session_id,
      last_seq: 0,
      active_turn: nil,
      recovered: nil,
      materialized?: false
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      session_id: state.session_id,
      last_seq: state.projection.last_seq,
      active_turn: state.active_turn,
      recovered: state.recovered,
      materialized?: true
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{lock: %Lock{port: port}} = state) do
    {:stop, {:journal_failure, {:writer_lock_lost, status}}, state}
  end

  def handle_info({:disk_log, _node, _log, info}, state) do
    case notification_health(info) do
      :ok ->
        {:noreply, state}

      {:fatal, reason} ->
        {:stop, {:journal_failure, reason}, state}
    end
  end

  # A port's exit signal is never fatal here: the lock port's loss arrives as
  # `{port, {:exit_status, status}}` above (and through the watchdog's
  # monitor). A linked process, such as the log backend, exiting is.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{materialized?: false}), do: :ok

  # After the writer lock was lost another process may own the session
  # directory: only the log is closed (its buffered writes cannot be avoided);
  # nothing else is synced, written, or released there.
  def terminate({:journal_failure, {:writer_lock_lost, _status}}, state) do
    Watchdog.cleanup(self())
    cleanup_step(:cleanup_close, fn -> Reader.close(state.name) end)
    Watchdog.lock(self(), nil)
    :ok
  end

  def terminate(_reason, state) do
    Watchdog.cleanup(self())
    cleanup_step(:cleanup_sync, fn -> Reader.sync(state.name) end)
    cleanup_step(:cleanup_close, fn -> Reader.close(state.name) end)
    cleanup_step(:cleanup_summary, fn -> write_summary_sidecar(state) end)
    cleanup_step(:cleanup_lock, fn -> Storage.release_lock(state.lock) end)
    Watchdog.lock(self(), nil)
    :ok
  end

  # Crash reports and `:sys.get_status/1` show the state and the last message.
  # Neither may carry the transcript: the projection is reduced to its
  # position, the creation options to their keys, and the message to its
  # operation.
  @impl true
  def format_status(status), do: StatusRedaction.format_status(status, &redact_state/1)

  defp redact_state(%{} = state) do
    %{
      state
      | projection: redact_projection(state.projection),
        open_opts: StatusRedaction.keys(state.open_opts)
    }
  end

  defp redact_state(state), do: state

  defp redact_projection(%Projection{} = projection) do
    %{
      session_id: projection.session_id,
      last_seq: projection.last_seq,
      status: projection.status,
      message_count: length(projection.messages)
    }
  end

  defp redact_projection(projection), do: projection

  defp build_state(session_id, lock, opened, opts) do
    state = %{
      session_id: session_id,
      path: opened.path,
      name: opened.name,
      lock: lock,
      next_seq: nil,
      synced_seq: nil,
      projection: nil,
      active_turn: nil,
      recovered: nil,
      materialized?: true,
      open_opts: nil
    }

    case initialize(opened, state, opts) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        _ = Reader.close(opened.name)
        _ = Storage.release_lock(lock)
        Watchdog.lock(self(), nil)
        {:error, reason}
    end
  end

  defp update_creation_config(opts, %Config{} = config) do
    opts
    |> Keyword.put(:model_ref, config.model_ref)
    |> Keyword.put(:thinking, Thinking.from_llm_opts(config.llm_opts))
  end

  # An unmaterialized session has no durable history, but callers still need the
  # creation metadata (recorded model, thinking, cwd) so configuration can be
  # resolved the same way before the first prompt. Nothing is written here.
  defp provisional_projection(%{session_id: session_id, open_opts: opts}) do
    %Projection{
      session_id: session_id,
      cwd: Keyword.get(opts, :cwd),
      title: Keyword.get(opts, :title),
      tags: Keyword.get(opts, :tags, []),
      model_ref: Keyword.get(opts, :model_ref),
      thinking: Keyword.get(opts, :thinking),
      tree_enabled?: Keyword.get(opts, :tree, false),
      status: :clean
    }
  end

  defp update_creation_metadata(opts, attrs) do
    opts
    |> put_creation_attr(:title, Map.get(attrs, "title"))
    |> put_creation_attr(:tags, Map.get(attrs, "tags"))
  end

  defp put_creation_attr(opts, _key, nil), do: opts
  defp put_creation_attr(opts, key, value), do: Keyword.put(opts, key, value)

  defp initialize(%{new?: true}, state, opts) do
    header =
      Log.header(
        session_id: state.session_id,
        created_at: now(),
        cwd: Keyword.get(opts, :cwd),
        parent: Keyword.get(opts, :parent)
      )

    created =
      Log.event("session.created", %{
        "cwd" => header["cwd"],
        "model_ref" => Keyword.get(opts, :model_ref),
        "thinking" => Keyword.get(opts, :thinking),
        "title" => Keyword.get(opts, :title),
        "tags" => Keyword.get(opts, :tags, []),
        "tree" => Keyword.get(opts, :tree, false)
      })

    # The synced `session.created` commit also makes the header durable.
    with :ok <- stage(:append_header, 0, fn -> Reader.log(state.name, header) end) do
      state = %{state | projection: Projection.new(header), next_seq: 1, synced_seq: 0}

      case commit(state, [created], nil) do
        {:ok, state, _seq} -> {:ok, state}
        {_rejected_or_error, reason} -> {:error, reason}
      end
    end
  end

  defp initialize(%{projection: %Projection{} = projection, recovered: recovered}, state, _opts) do
    # Everything replayed was read back from the file, so it is the durable base.
    state = %{
      state
      | projection: projection,
        next_seq: projection.last_seq + 1,
        synced_seq: projection.last_seq
    }

    case recovered do
      nil ->
        Catalog.record(build_summary(state))
        {:ok, state}

      info ->
        event = Log.event("session.recovered", info)

        case commit(state, [event], nil) do
          {:ok, state, _seq} -> {:ok, %{state | recovered: info}}
          {_rejected_or_error, reason} -> {:error, reason}
        end
    end
  end

  # Returns `{:rejected, reason}` when the commit is refused before anything is
  # written: it must validate and fold into the projection (pure and cheap)
  # before it is appended, so a commit that replay would reject never reaches
  # the file. `{:error, reason}` means appending or syncing failed.
  defp commit(state, events, turn_id, sync? \\ true) do
    seq = state.next_seq

    commit =
      Log.commit(
        session_id: state.session_id,
        seq: seq,
        commit_id: ID.generate(),
        written_at: now(),
        turn_id: turn_id,
        events: events
      )

    with :ok <- stage(:validate, seq, fn -> commit_validation(commit) end),
         {:ok, projection} <- stage(:projection, seq, fn -> fold(state.projection, commit) end),
         :ok <- stage(:append, seq, fn -> Reader.log(state.name, commit) end) do
      next = %{state | projection: projection, next_seq: seq + 1}

      with {:ok, next} <- maybe_sync(next, sync?), do: {:ok, next, seq}
    end
  end

  defp fold(projection, commit) do
    {:ok, Projection.apply_commit(projection, commit)}
  rescue
    error in ProjectionError -> {:rejected, {:invalid_commit, error.reason}}
  end

  defp maybe_sync(state, true), do: sync_appended(state)
  defp maybe_sync(state, false), do: {:ok, state}

  # One sync covers every commit appended before it. The catalog is a derived
  # projection of durable history, so it is refreshed only when a sync made new
  # commits durable.
  defp sync_appended(state, force? \\ false)

  defp sync_appended(%{synced_seq: synced, next_seq: next} = state, false)
       when synced >= next - 1,
       do: {:ok, state}

  defp sync_appended(state, _force?) do
    last_seq = state.next_seq - 1

    with :ok <- stage(:sync, last_seq, fn -> Reader.sync(state.name) end) do
      newly_durable? = state.synced_seq < last_seq
      state = %{state | synced_seq: last_seq}

      if newly_durable?, do: record_catalog(state, last_seq)
      {:ok, state}
    end
  end

  defp record_catalog(state, seq),
    do: stage(:catalog, seq, fn -> Catalog.record(build_summary(state)) end)

  defp commit_validation(commit) do
    with :ok <- Log.validate_commit(commit, commit["session_id"], commit["seq"]),
         :ok <- Codec.validate(commit) do
      :ok
    else
      {:error, reason} -> {:rejected, {:invalid_commit, reason}}
    end
  end

  # The caller's error, not the journal's: refuse it and stay usable. Anything
  # else failed after bytes may have been written, which is fatal.
  defp refuse_or_fail(state, {:rejected, reason}), do: {:reply, {:error, reason}, state}
  defp refuse_or_fail(state, {:error, reason}), do: fail(state, reason)

  defp active_turn_id(%{active_turn: %{turn_id: turn_id}}), do: {:ok, turn_id}
  defp active_turn_id(_state), do: {:rejected, :no_active_turn}

  defp message_event(%Message{} = message, parent) do
    case Codec.encode_message(message) do
      {:ok, data} ->
        {:ok, Log.event("message.appended", maybe_put_parent(%{"message" => data}, parent))}

      {:error, reason} ->
        {:rejected, reason}
    end
  end

  # A journal without branching keeps its format: a message always attaches
  # to the active entry, so its parent is implied and not written, and a
  # parent elsewhere would be a branch the session may not make.
  defp journal_parent(%Projection{tree_enabled?: true}, parent), do: {:ok, parent}
  defp journal_parent(_projection, :none), do: {:ok, :none}

  defp journal_parent(%Projection{tree: tree}, {:tree, parent_id}) do
    if parent_id == Tree.active_id(tree),
      do: {:ok, :none},
      else: {:rejected, :tree_disabled}
  end

  defp compaction_data(%Projection{tree_enabled?: true}, data), do: {:ok, data}

  defp compaction_data(projection, data) do
    with {:ok, :none} <- journal_parent(projection, {:tree, Map.get(data, "parent_id")}) do
      {:ok, Map.delete(data, "parent_id")}
    end
  end

  # `:none` attaches the message to the active entry; `{:tree, parent_id}`
  # records the entry the message attaches to, including `nil` for a new root,
  # alongside the message payload in the same commit.
  defp maybe_put_parent(data, :none), do: data
  defp maybe_put_parent(data, {:tree, parent_id}), do: Map.put(data, "parent_id", parent_id)

  defp tool_event(call) do
    call = normalize_tool_call(call)

    data = %{
      "tool_call_id" => Map.get(call, "id"),
      "name" => Map.get(call, "name"),
      "arguments" => Map.get(call, "arguments") || %{},
      "started_at" => now()
    }

    case Codec.validate(data) do
      :ok -> {:ok, Log.event("tool.execution_started", data)}
      {:error, reason} -> {:rejected, {:invalid_tool_call, reason}}
    end
  end

  defp normalize_tool_call(%Tackle.Lib.Tool.Call{} = call) do
    call
    |> Map.from_struct()
    |> Map.take([:id, :name, :arguments])
    |> Codec.normalize()
  end

  defp normalize_tool_call(call), do: Codec.normalize(call)

  defp settle_event(state, type, data) do
    with {:ok, turn_id} <- settled_turn_id(state, data["turn_id"]),
         :ok <- terminal_event(type) do
      payload =
        data
        |> Map.put("turn_id", turn_id)
        |> Map.put_new("settled_at", now())

      case Codec.validate(payload) do
        :ok -> {:ok, Log.event(type, payload), turn_id}
        {:error, reason} -> {:rejected, {:invalid_settlement, reason}}
      end
    end
  end

  # Only the active turn can be settled or, in a journal opened with an
  # interrupted turn, that turn. A settlement never names another turn: it
  # would end the wrong one, settle one twice, or invent one.
  defp settled_turn_id(state, requested) do
    case {settleable_turn_id(state), requested} do
      {nil, nil} -> {:rejected, :no_active_turn}
      {turn_id, nil} -> {:ok, turn_id}
      {turn_id, turn_id} -> {:ok, turn_id}
      {_turn_id, _other} -> {:rejected, :turn_mismatch}
    end
  end

  defp settleable_turn_id(%{active_turn: %{turn_id: turn_id}}), do: turn_id

  defp settleable_turn_id(%{projection: %Projection{active_turn: %{turn_id: turn_id}}}),
    do: turn_id

  defp settleable_turn_id(_state), do: nil

  defp terminal_event(type) do
    if Log.terminal_event?(type), do: :ok, else: {:rejected, {:invalid_terminal_event, type}}
  end

  # The live summary carries no search text: building it costs O(session), so
  # the catalog builds it only when a search needs it. `journal_path` lets the
  # catalog find this session's file later.
  defp build_summary(state) do
    state.projection
    |> Map.put(:status, live_status(state))
    |> Projection.metadata()
    |> Map.put(:journal_path, state.path)
  end

  defp live_status(%{active_turn: nil} = state), do: state.projection.status
  defp live_status(%{active_turn: %{}}), do: :active

  defp write_summary_sidecar(state) do
    path = Path.join(Path.dirname(state.path), "summary.etf")

    with {:ok, encoded} <- encode_summary(state) do
      Storage.atomic_write(path, encoded)
    end
  end

  defp encode_summary(state) do
    payload = %{
      "schema_version" => 1,
      "session_id" => state.session_id,
      "last_indexed_seq" => state.projection.last_seq,
      # Written once, when the owner stops, so the next startup can index
      # without replaying the journal.
      "summary" =>
        state
        |> build_summary()
        |> Map.delete(:journal_path)
        |> Map.put(:search_text, Projection.search_text(state.projection))
        |> Catalog.encode_summary()
    }

    {:ok, :erlang.term_to_binary(payload, [:compressed])}
  rescue
    _error -> {:error, :summary_encode_failed}
  end

  defp sync?(opts), do: Keyword.get(opts, :sync, true) != false

  defp state_active_turn_id(%{active_turn: %{turn_id: turn_id}}), do: turn_id
  defp state_active_turn_id(_state), do: nil

  defp notification_health({:error_status, :ok}), do: :ok
  defp notification_health({:error_status, status}), do: {:fatal, {:error_status, status}}
  defp notification_health(:full), do: {:fatal, :disk_full}
  defp notification_health({:truncated, _info}), do: {:fatal, :truncated}
  defp notification_health({:wrap, _info}), do: {:fatal, :unexpected_wrap}
  defp notification_health({:read_only, _info}), do: {:fatal, :read_only}
  defp notification_health(_info), do: :ok

  defp fail(state, reason) do
    {:stop, {:journal_failure, reason}, {:error, {:journal_failure, reason}}, state}
  end

  defp with_journal(session_id, fun) do
    case whereis(session_id) do
      {:ok, journal} ->
        try do
          fun.(journal)
        catch
          :exit, reason -> {:error, {:journal_unavailable, reason}}
        end

      {:error, :not_found} ->
        :ok
    end
  end

  defp cleanup_step(stage, fun) do
    Watchdog.stage(self(), stage)

    case fun.() do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Journal #{stage} failed: #{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("Journal #{stage} raised #{inspect(error.__struct__)}")
  catch
    kind, _reason -> Logger.warning("Journal #{stage} failed (#{kind})")
  end

  defp stage(stage, seq, fun) do
    Watchdog.stage(self(), stage, seq)
    fun.()
  end

  defp durable_call(journal, message) do
    case GenServer.whereis(journal) do
      pid when is_pid(pid) -> Watchdog.request(pid, message)
      nil -> {:error, {:journal_unavailable, :not_found}}
    end
  end

  defp call(journal, message), do: GenServer.call(journal, message, @call_timeout)

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
