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
  without syncing. The derived catalog is updated when an existing journal is
  opened, at sync points that made new commits durable, when a turn starts or
  settles (whose commits are then appended but not yet synced), and when the
  owner stops; it lists the session as `:active` while the owner runs a turn
  and otherwise with the projection's status.

  ## Deadlines

  Every durable request passes through an independent deadline process
  (`journal_timeout`, 15 seconds by default), which runs one request at a time
  and queues at most 64 more (24 MiB of request data); beyond that a request
  is refused with `{:error, :journal_busy}`. A request that misses the
  deadline while it waits for the disk (appending or syncing; `:disk_log`
  can block an append behind its own cache write) only marks storage delayed
  (the session, which `Tackle.Session.Durable` subscribes, receives
  `{:tackle_storage, session_id, :delayed | :ready}`), logs a payload-free
  warning, and stays in flight; it is never retried. Any other stage that
  misses it, including opening and the owner's cleanup, stops the owner and
  its durable scope rather than abandoning a request while execution
  continues. The commit outcome may then be unknown: replay is required
  before any retry. When it stops the owner for a missed deadline, or the
  owner exits unexpectedly, the deadline process logs a payload-free
  diagnostic (operation or failure category, stage, sequence, and for a
  stall its stack frames) and saves it as `journal-failure.json` beside the
  journal.

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
  materializing a new session, is fatal to further durable execution: the
  owner stops, which terminates its durable scope rather than continuing with
  memory-only state. The request that failed receives
  `{:error, {:journal_failure, reason}}`; requests queued behind it, and any
  made afterwards, fail too, for example with
  `{:error, {:journal_unavailable, reason}}`, or with
  `{:error, {:journal_stalled, diagnostic}}` after a missed deadline. An
  existing journal that cannot be opened (for example
  `{:journal_open_failed, session_id, {:repair_required, path}}` when it was
  not closed cleanly and the session's spec does not allow repair) stops the
  owner while it starts, so the scope does not start.
  """

  use GenServer, restart: :permanent
  require Logger

  alias Tackle.Config
  alias Tackle.FileLock
  alias Tackle.Lib.Message
  alias Tackle.Lib.Thinking
  alias Tackle.Lib.Tree
  alias Tackle.Lib.Tree.Change
  alias Tackle.Runtime.ID
  alias Tackle.Session.Catalog
  alias Tackle.Session.Catalog.Entry
  alias Tackle.Session.Codec
  alias Tackle.Session.CompressedFile
  alias Tackle.Session.Journal.Deadline
  alias Tackle.Session.Log
  alias Tackle.Session.Projection
  alias Tackle.Session.ProjectionError
  alias Tackle.Session.Reader
  alias Tackle.Session.Storage
  alias Tackle.StatusRedaction

  @registry Tackle.Session.JournalRegistry
  @call_timeout 60_000
  # Lets the deadline process's cleanup deadline expire before the supervisor
  # kills the owner, so a stalled cleanup still leaves its diagnostic.
  @shutdown_margin 1_000

  @type state :: %{
          session_id: String.t(),
          path: String.t(),
          name: tuple() | nil,
          lock: Tackle.Session.Storage.Lock.t() | nil,
          next_seq: pos_integer() | nil,
          synced_seq: non_neg_integer() | nil,
          projection: Projection.t() | nil,
          live_turn?: boolean(),
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
  # take up to the journal timeout, which the deadline process enforces.
  defp shutdown(opts) do
    case Deadline.timeout(opts) do
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

  @doc """
  Resolves the live journal owner for a session id: the one check of
  whether a session is live in this node.

  An owner that has exited is not live, even while the registry still lists
  it.
  """
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(session_id) do
    case Registry.lookup(@registry, {:session_journal, session_id}) do
      [{pid, _value}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_found}

      _other ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns `:ok` when no journal owner is live for the session in this node,
  and `{:error, :session_active}` otherwise. Operations that move or replace
  a session's files check it first.
  """
  @spec ensure_not_live(String.t()) :: :ok | {:error, :session_active}
  def ensure_not_live(session_id) do
    case whereis(session_id) do
      {:ok, _journal} -> {:error, :session_active}
      {:error, :not_found} -> :ok
    end
  end

  @doc """
  Returns a session's current projection: its live owner's, which includes
  commits not yet synced, or else the one replayed from its file
  (`Tackle.Session.Reader.projection/2` with `reader_opts`).

  An owner that stops while it is asked is `{:error, {:journal_unavailable,
  reason}}`.
  """
  @spec current_projection(String.t(), keyword()) :: {:ok, Projection.t()} | {:error, term()}
  def current_projection(session_id, reader_opts) do
    case whereis(session_id) do
      {:ok, journal} -> projection(journal)
      {:error, :not_found} -> Reader.projection(session_id, reader_opts)
    end
  catch
    :exit, reason -> {:error, {:journal_unavailable, reason}}
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
  may branch. An already-enabled session is a no-op, and an unmaterialized
  one writes nothing: its `session.created` will record `"tree" => true`.
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

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    session_id = Keyword.fetch!(opts, :session_id)

    with {:ok, _deadline} <- Deadline.start(self(), session_id, opts),
         {:ok, path} <- Storage.journal_path(session_id, opts),
         {:ok, state} <- open_or_defer(session_id, path, opts) do
      Deadline.ready(self())
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
      materialize(session_id, opts, &Storage.acquire_existing_lock/2)
    else
      {:ok, deferred_state(session_id, path, opts)}
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
      live_turn?: false,
      materialized?: false,
      open_opts: opts
    }
  end

  defp ensure_materialized(%{materialized?: true} = state), do: {:ok, state}

  defp ensure_materialized(%{materialized?: false} = state),
    do: materialize(state.session_id, state.open_opts, &Storage.acquire_lock/2)

  # Takes the writer lock, opens the journal under it, and writes or replays
  # what opening requires. Anything that fails after the lock is held closes
  # the log, if it was opened, and releases the lock.
  defp materialize(session_id, opts, acquire_lock) do
    Deadline.stage(self(), :acquire_lock)

    with {:ok, lock} <- acquire_lock.(session_id, opts) do
      Deadline.lock(self(), lock)
      Deadline.stage(self(), :open_replay)

      case open_locked(session_id, lock, opts) do
        {:ok, state} ->
          {:ok, state}

        {:error, reason} ->
          _ = Storage.release_lock(lock)
          Deadline.lock(self(), nil)
          {:error, reason}
      end
    end
  end

  defp open_locked(session_id, lock, opts) do
    case open_writable(session_id, opts) do
      {:ok, opened} ->
        with {:error, reason} <- initialize(opened, opened_state(session_id, lock, opened), opts) do
          _ = Reader.close(opened.name)
          {:error, reason}
        end

      {:error, reason} ->
        {:error, {:journal_open_failed, session_id, reason}}
    end
  end

  # An idle journal stored compressed is restored to a plain journal before
  # the owner opens it.
  defp open_writable(session_id, opts) do
    with {:ok, path} <- Storage.journal_path(session_id, opts),
         :ok <- CompressedFile.restore(path) do
      Reader.open_writable(session_id, opts)
    end
  end

  defp opened_state(session_id, lock, opened) do
    %{
      session_id: session_id,
      path: opened.path,
      name: opened.name,
      lock: lock,
      next_seq: nil,
      synced_seq: nil,
      projection: nil,
      live_turn?: false,
      materialized?: true,
      open_opts: nil
    }
  end

  @impl true
  def handle_call({:begin_turn, operation, input, turn_id}, _from, state) do
    case ensure_materialized(state) do
      {:error, reason} ->
        fail(state, reason)

      {:ok, %{live_turn?: true} = state} ->
        {:reply, {:error, :turn_in_progress}, state}

      {:ok, state} ->
        event = Log.turn_started(turn_id, operation, input, now())

        # Write-behind: the turn becomes durable with the first external tool
        # gate or a later sync. A turn lost to power loss has caused no external
        # effect yet, so it simply did not happen.
        case commit(state, [event], turn_id, false) do
          {:ok, state, _seq} ->
            state = %{state | live_turn?: true}
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
         {:ok, state, _seq} <-
           commit(state, [Log.context_compacted(data)], live_turn_id(state)) do
      {:reply, :ok, state}
    else
      error -> refuse_or_fail(state, error)
    end
  end

  def handle_call({:append_message, %Message{} = message, parent, sync?}, _from, state) do
    Deadline.stage(self(), :encode_message, state.next_seq)

    with {:ok, turn_id} <- active_turn_id(state),
         {:ok, parent} <- journal_parent(state.projection, parent),
         event = Log.message_appended(message, parent),
         {:ok, state, _seq} <- commit(state, [event], turn_id, sync?) do
      {:reply, :ok, state}
    else
      error -> refuse_or_fail(state, error)
    end
  end

  def handle_call({:tool_started, call, sync?}, _from, state) do
    with {:ok, turn_id} <- active_turn_id(state),
         event = Log.tool_started(call, now()),
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
    case commit(state, [Log.tree_navigated(change, now())], live_turn_id(state)) do
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
    case commit(state, [Log.tree_enabled(now())], nil) do
      {:ok, state, _seq} -> {:reply, :ok, state}
      error -> refuse_or_fail(state, error)
    end
  end

  # Write-behind: the OS writes the settled turn back on its own schedule, so
  # an app crash keeps it; only power loss can lose the last turns.
  def handle_call({:settle_turn, type, data}, _from, state) do
    with {:ok, event, turn_id} <- settle_event(state, type, data),
         {:ok, state, seq} <- commit(state, [event], turn_id, false) do
      state = %{state | live_turn?: false}
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
      Log.configuration_changed(config.model_ref, Thinking.from_llm_opts(config.llm_opts), now())

    case commit(state, [event], nil) do
      {:ok, state, _seq} -> {:reply, :ok, state}
      error -> refuse_or_fail(state, error)
    end
  end

  def handle_call({:metadata_changed, attrs}, _from, %{materialized?: false} = state) do
    {:reply, :ok, %{state | open_opts: update_creation_metadata(state.open_opts, attrs)}}
  end

  def handle_call({:metadata_changed, attrs}, _from, state) do
    case commit(state, [Log.metadata_changed(attrs, now())], nil) do
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

  @impl true
  def handle_info({port, {:exit_status, status}}, %{lock: %FileLock{port: port}} = state) do
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
  # `{port, {:exit_status, status}}` above (and through the deadline process's
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
    Deadline.cleanup(self())
    cleanup_step(:cleanup_close, fn -> Reader.close(state.name) end)
    record_final_summary(state)
    Deadline.lock(self(), nil)
    :ok
  end

  def terminate(_reason, state) do
    Deadline.cleanup(self())
    cleanup_step(:cleanup_sync, fn -> Reader.sync(state.name) end)
    cleanup_step(:cleanup_close, fn -> Reader.close(state.name) end)
    cleanup_step(:cleanup_summary, fn -> write_summary_sidecar(state) end)
    record_final_summary(state)
    cleanup_step(:cleanup_lock, fn -> Storage.release_lock(state.lock) end)
    Deadline.lock(self(), nil)
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

    created = Log.session_created(header, opts)

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
        Catalog.record(catalog_entry(state))
        {:ok, state}

      info ->
        case commit(state, [Log.session_recovered(info)], nil) do
          {:ok, state, _seq} -> {:ok, state}
          {_rejected_or_error, reason} -> {:error, reason}
        end
    end
  end

  # Returns `{:rejected, reason}` when the commit is refused before anything is
  # written: its event data must be durable plain data, checked once here, and
  # it must fold into the projection (pure and cheap) before it is appended,
  # so a commit that replay would reject never reaches the file. The envelope
  # and the event versions are this build's (`Log.commit/1`, `Log.event/3`).
  # `{:error, reason}` means appending or syncing failed.
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

    with :ok <- stage(:validate, seq, fn -> validate_data(events) end),
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
    do: stage(:catalog, seq, fn -> Catalog.record(catalog_entry(state)) end)

  defp validate_data(events) do
    Enum.reduce_while(events, :ok, fn %{"type" => type, "data" => data}, :ok ->
      case Codec.validate(data) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:rejected, refusal(type, reason)}}
      end
    end)
  end

  # What the caller gave that is not durable plain data.
  defp refusal("message.appended", reason), do: {:invalid_message, reason}
  defp refusal("tool.execution_started", reason), do: {:invalid_tool_call, reason}

  defp refusal(type, reason) do
    if Log.terminal_event?(type),
      do: {:invalid_settlement, reason},
      else: {:invalid_commit, {:invalid_event_data, type, reason}}
  end

  # The caller's error, not the journal's: refuse it and stay usable. Anything
  # else failed after bytes may have been written, which is fatal.
  defp refuse_or_fail(state, {:rejected, reason}), do: {:reply, {:error, reason}, state}
  defp refuse_or_fail(state, {:error, reason}), do: fail(state, reason)

  defp active_turn_id(state) do
    case live_turn_id(state) do
      nil -> {:rejected, :no_active_turn}
      turn_id -> {:ok, turn_id}
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

  defp settle_event(state, type, data) do
    with {:ok, turn_id} <- settled_turn_id(state, data["turn_id"]),
         :ok <- terminal_event(type) do
      {:ok, Log.turn_settled(type, turn_id, data, now()), turn_id}
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

  defp settleable_turn_id(%{projection: %Projection{active_turn: %{turn_id: turn_id}}}),
    do: turn_id

  defp settleable_turn_id(_state), do: nil

  defp terminal_event(type) do
    if Log.terminal_event?(type), do: :ok, else: {:rejected, {:invalid_terminal_event, type}}
  end

  # The live entry carries no search text: building it costs O(session), so
  # the catalog builds it only when a search needs it. `journal_path` lets the
  # catalog find this session's file later. While this owner runs a turn the
  # session is listed as `:active`; otherwise, and once the owner stops, with
  # the projection's status, which is what replay reports.
  defp catalog_entry(state, status \\ nil) do
    Entry.from_projection(state.projection,
      status: status || live_status(state),
      journal_path: state.path
    )
  end

  defp live_status(%{live_turn?: true}), do: :active
  defp live_status(state), do: state.projection.status

  # The owner is stopping: a turn it still runs is interrupted from now on.
  defp record_final_summary(state) do
    Catalog.record(catalog_entry(state, state.projection.status))
  end

  # Written once, when the owner stops and its log is closed, so the next
  # startup can index without replaying the journal as long as the file keeps
  # the size and modification time recorded here.
  defp write_summary_sidecar(state) do
    path = Path.join(Path.dirname(state.path), "summary.etf")

    Storage.atomic_write(
      path,
      Catalog.sidecar(state.projection, Catalog.journal_stat(state.path))
    )
  end

  defp sync?(opts), do: Keyword.get(opts, :sync, true) != false

  # The turn this owner began and has not settled. The projection's active turn
  # is that turn or, in a journal opened with an interrupted turn, that one,
  # which accepts only its settlement.
  defp live_turn_id(%{live_turn?: true, projection: %Projection{active_turn: %{turn_id: id}}}),
    do: id

  defp live_turn_id(_state), do: nil

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

  defp cleanup_step(stage, fun) do
    Deadline.stage(self(), stage)

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
    Deadline.stage(self(), stage, seq)
    fun.()
  end

  defp durable_call(journal, message) do
    case GenServer.whereis(journal) do
      pid when is_pid(pid) -> Deadline.request(pid, message)
      nil -> {:error, {:journal_unavailable, :not_found}}
    end
  end

  defp call(journal, message), do: GenServer.call(journal, message, @call_timeout)

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
