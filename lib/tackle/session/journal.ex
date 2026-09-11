defmodule Tackle.Session.Journal do
  @moduledoc """
  Supervised owner of one append-only session journal.

  Exactly one `Journal` process owns one `:disk_log` in `:internal`, `:halt`
  mode. It assigns the monotonic session sequence, validates each commit,
  applies the durability barrier, owns the log lifecycle, and exposes one narrow
  API to the session and its internal persistence hook. Callers never open or
  write the journal file directly.

  A journal failure is fatal to further durable execution: append, sync, and
  validation failures stop the owner, which terminates its durable scope rather
  than continuing with memory-only state.
  """

  use GenServer, restart: :permanent

  alias Tackle.Config
  alias Tackle.Lib.Message
  alias Tackle.Lib.Tree.Change
  alias Tackle.Runtime.ID
  alias Tackle.Session.Catalog
  alias Tackle.Session.Codec
  alias Tackle.Session.Log
  alias Tackle.Session.Projection
  alias Tackle.Session.Reader
  alias Tackle.Session.Storage
  alias Tackle.Session.Storage.Lock
  alias Tackle.Thinking

  @registry Tackle.Session.JournalRegistry
  @call_timeout 60_000

  @type turn :: %{turn_id: String.t(), operation: atom()}

  @type state :: %{
          session_id: String.t(),
          path: String.t(),
          name: tuple() | nil,
          lock: Tackle.Session.Storage.Lock.t() | nil,
          next_seq: pos_integer() | nil,
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
      type: :worker
    }
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

  @spec begin_turn(GenServer.server(), :run | :continue, String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def begin_turn(journal, operation, input)
      when operation in [:run, :continue] do
    begin_turn(journal, operation, input, ID.generate())
  end

  @doc """
  Appends and syncs `turn.started` before the turn task may begin.

  The caller mints the turn id so library events, terminal outcomes, and
  durable commits all correlate on one identifier. Returns the turn id after
  the commit is durable.
  """
  @spec begin_turn(GenServer.server(), :run | :continue, String.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def begin_turn(journal, operation, input, turn_id)
      when operation in [:run, :continue] and is_binary(turn_id) do
    call(journal, {:begin_turn, operation, input, turn_id})
  end

  @doc "Persists a settled message on the current turn."
  @spec append_message(GenServer.server(), Message.t(), term()) :: :ok | {:error, term()}
  def append_message(journal, %Message{} = message, parent \\ :none),
    do: call(journal, {:append_message, message, parent})

  @doc "Persists tool execution intent before the tool is invoked."
  @spec tool_started(GenServer.server(), map()) :: :ok | {:error, term()}
  def tool_started(journal, call), do: call(journal, {:tool_started, call})

  @doc """
  Persists one durable compaction replacement.

  The event data replaces the model-surface prefix with `summary_message` while
  the canonical transcript is untouched. The commit is appended to the active
  turn when one exists and synced before the caller installs the in-memory
  replacement.
  """
  @spec context_compacted(GenServer.server(), map()) :: :ok | {:error, term()}
  def context_compacted(journal, data), do: call(journal, {:context_compacted, data})

  @doc "Settles the active turn with a terminal event."
  @spec settle_turn(GenServer.server(), atom(), map()) :: :ok | {:error, term()}
  def settle_turn(journal, type, data \\ %{}), do: call(journal, {:settle_turn, type, data})

  @doc """
  Persists one committed navigation before the library installs it.

  Navigation is durable on its own, so a session that is resumed after the
  user exits without sending another prompt restores the selected position,
  including the position before the first message.
  """
  @spec tree_navigated(GenServer.server(), Change.t()) :: :ok | {:error, term()}
  def tree_navigated(journal, %Change{} = change), do: call(journal, {:tree_navigated, change})

  @doc """
  Records the explicit `tree.enabled` transition for a legacy linear session.

  The durable file is not rewritten; the event only records that later writes
  may branch. An already-enabled or unmaterialized session is a no-op.
  """
  @spec enable_tree(GenServer.server()) :: :ok | {:error, term()}
  def enable_tree(journal), do: call(journal, :enable_tree)

  @doc "Persists an accepted idle configuration change."
  @spec configuration_changed(GenServer.server(), Config.t()) :: :ok | {:error, term()}
  def configuration_changed(journal, %Config{} = config),
    do: call(journal, {:configuration_changed, config})

  @doc "Persists session metadata such as title and tags."
  @spec metadata_changed(GenServer.server(), map()) :: :ok | {:error, term()}
  def metadata_changed(journal, attrs), do: call(journal, {:metadata_changed, attrs})

  @doc "Appends and syncs `session.closed` before releasing ownership."
  @spec close_journal(GenServer.server()) :: :ok | {:error, term()}
  def close_journal(journal), do: call(journal, :close_journal)

  @doc "Runs an explicit durability barrier over already-appended commits."
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(journal), do: call(journal, :flush)

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
  same hook module can be installed unconditionally. `parent` is `:none` for a
  linear session, or `{:tree, parent_id}` (which may be `nil`) for a branching
  one, so the parent link is committed with the message payload.
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

    with {:ok, path} <- Storage.journal_path(session_id, opts),
         {:ok, state} <- open_or_defer(session_id, path, opts) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # A new durable session is materialized on its first prompt, not when a scope
  # starts. The owner process exists immediately so the runtime can fail closed
  # and address the journal, but no directory, ownership lock, log file, or
  # catalog entry is created until there is real work to persist. An existing
  # journal is opened and validated eagerly so resume never fabricates history.
  defp open_or_defer(session_id, path, opts) do
    if File.exists?(path) do
      open_existing(session_id, opts)
    else
      {:ok, deferred_state(session_id, path, opts)}
    end
  end

  defp open_existing(session_id, opts) do
    repair? = Keyword.get(opts, :repair, false)

    with {:ok, lock} <- Storage.acquire_lock(session_id, opts) do
      case Reader.open_writable(session_id, Keyword.put(opts, :repair, repair?)) do
        {:ok, opened} ->
          build_state(session_id, lock, opened, opts)

        {:error, reason} ->
          Storage.release_lock(lock)
          {:error, {:journal_open_failed, session_id, reason}}
      end
    end
  end

  defp deferred_state(session_id, path, opts) do
    %{
      session_id: session_id,
      path: path,
      name: nil,
      lock: nil,
      next_seq: nil,
      projection: nil,
      active_turn: nil,
      recovered: nil,
      materialized?: false,
      open_opts: opts
    }
  end

  defp ensure_materialized(%{materialized?: true} = state), do: {:ok, state}

  defp ensure_materialized(%{materialized?: false} = state) do
    case Storage.acquire_lock(state.session_id, state.open_opts) do
      {:ok, lock} ->
        case Reader.open_writable(state.session_id, state.open_opts) do
          {:ok, opened} ->
            build_state(state.session_id, lock, opened, state.open_opts)

          {:error, reason} ->
            Storage.release_lock(lock)
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

        case commit(state, [event], turn_id) do
          {:ok, state, _seq} ->
            turn = %{turn_id: turn_id, operation: operation}
            {:reply, {:ok, turn_id}, %{state | active_turn: turn}}

          {:error, reason} ->
            fail(state, reason)
        end
    end
  end

  def handle_call({:context_compacted, _data}, _from, %{materialized?: false} = state) do
    {:reply, {:error, :no_journal}, state}
  end

  def handle_call({:context_compacted, data}, _from, state) do
    event = Log.event("context.compacted", data)

    case commit(state, [event], state_active_turn_id(state)) do
      {:ok, state, _seq} -> {:reply, :ok, state}
      {:error, reason} -> fail(state, reason)
    end
  end

  def handle_call({:append_message, %Message{} = message, parent}, _from, state) do
    with %{turn_id: turn_id} <- state.active_turn,
         {:ok, event} <- message_event(message, parent),
         {:ok, state, _seq} <- commit(state, [event], turn_id) do
      {:reply, :ok, state}
    else
      nil ->
        {:reply, {:error, :no_active_turn}, state}

      {:error, reason} ->
        fail(state, reason)
    end
  end

  def handle_call({:tool_started, call}, _from, state) do
    with %{turn_id: turn_id} <- state.active_turn,
         {:ok, event} <- tool_event(call),
         {:ok, state, _seq} <- commit(state, [event], turn_id) do
      {:reply, :ok, state}
    else
      nil ->
        {:reply, {:error, :no_active_turn}, state}

      {:error, reason} ->
        fail(state, reason)
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
      {:error, reason} -> fail(state, reason)
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
      {:error, reason} -> fail(state, reason)
    end
  end

  def handle_call({:settle_turn, type, data}, _from, state) do
    case settle_event(state, type, data) do
      {:ok, event, turn_id} ->
        case commit(state, [event], turn_id) do
          {:ok, state, _seq} -> {:reply, :ok, %{state | active_turn: nil}}
          {:error, reason} -> fail(state, reason)
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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
    event =
      Log.event("session.configuration_changed", %{
        "model_ref" => config.model_ref,
        "thinking" => config.llm_opts[:reasoning_effort],
        "changed_at" => now()
      })

    case commit(state, [event], nil) do
      {:ok, state, _seq} -> {:reply, :ok, state}
      {:error, reason} -> fail(state, reason)
    end
  end

  def handle_call({:metadata_changed, attrs}, _from, %{materialized?: false} = state) do
    {:reply, :ok, %{state | open_opts: update_creation_metadata(state.open_opts, attrs)}}
  end

  def handle_call({:metadata_changed, attrs}, _from, state) do
    event = Log.event("session.metadata_changed", Map.put_new(attrs, "changed_at", now()))

    case commit(state, [event], nil) do
      {:ok, state, _seq} -> {:reply, :ok, state}
      {:error, reason} -> fail(state, reason)
    end
  end

  def handle_call(:close_journal, _from, %{materialized?: false} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:close_journal, _from, state) do
    event = Log.event("session.closed", %{"closed_at" => now()})

    case commit(state, [event], state_active_turn_id(state)) do
      {:ok, state, _seq} -> {:reply, :ok, %{state | active_turn: nil}}
      {:error, reason} -> fail(state, reason)
    end
  end

  def handle_call(:flush, _from, %{materialized?: false} = state), do: {:reply, :ok, state}

  def handle_call(:flush, _from, state) do
    case Reader.sync(state.name) do
      :ok -> {:reply, :ok, state}
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

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{materialized?: false}), do: :ok

  def terminate(_reason, state) do
    _ = Reader.sync(state.name)
    _ = Reader.close(state.name)
    _ = write_summary_sidecar(state)
    _ = Storage.release_lock(state.lock)
    :ok
  end

  defp build_state(session_id, lock, opened, opts) do
    state = %{
      session_id: session_id,
      path: opened.path,
      name: opened.name,
      lock: lock,
      next_seq: nil,
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

    with :ok <- Reader.log(state.name, header),
         :ok <- Reader.sync(state.name) do
      state = %{state | projection: Projection.new(header), next_seq: 1}

      case commit(state, [created], nil) do
        {:ok, state, _seq} -> {:ok, state}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp initialize(%{projection: %Projection{} = projection, recovered: recovered}, state, _opts) do
    state = %{state | projection: projection, next_seq: projection.last_seq + 1}

    case recovered do
      nil ->
        Catalog.record(build_summary(state))
        {:ok, state}

      info ->
        event = Log.event("session.recovered", info)

        case commit(state, [event], nil) do
          {:ok, state, _seq} -> {:ok, %{state | recovered: info}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp commit(state, events, turn_id) do
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

    with :ok <- commit_validation(commit),
         :ok <- Reader.log(state.name, commit),
         :ok <- Reader.sync(state.name) do
      projection = Projection.apply_commit(state.projection, commit)
      next = %{state | projection: projection, next_seq: seq + 1}
      Catalog.record(build_summary(next))
      {:ok, next, seq}
    end
  end

  defp commit_validation(commit) do
    with :ok <- Log.validate_commit(commit, commit["session_id"], commit["seq"]) do
      case Codec.validate(commit) do
        :ok -> :ok
        {:error, reason} -> {:error, {:invalid_commit, reason}}
      end
    end
  end

  defp message_event(%Message{} = message, parent) do
    case Codec.encode_message(message) do
      {:ok, data} ->
        {:ok, Log.event("message.appended", maybe_put_parent(%{"message" => data}, parent))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `:none` keeps a linear journal unchanged; `{:tree, parent_id}` records the
  # entry the message attaches to, including `nil` for a new root, alongside the
  # message payload in the same commit.
  defp maybe_put_parent(data, :none), do: data
  defp maybe_put_parent(data, {:tree, parent_id}), do: Map.put(data, "parent_id", parent_id)

  defp tool_event(call) do
    data = %{
      "tool_call_id" => Map.get(call, :id) || Map.get(call, "id"),
      "name" => Map.get(call, :name) || Map.get(call, "name"),
      "arguments" =>
        Codec.normalize(Map.get(call, :arguments) || Map.get(call, "arguments") || %{}),
      "started_at" => now()
    }

    case Codec.validate(data) do
      :ok -> {:ok, Log.event("tool.execution_started", data)}
      {:error, reason} -> {:error, {:invalid_tool_call, reason}}
    end
  end

  defp settle_event(state, type, data) do
    turn_id = state_active_turn_id(state) || data["turn_id"]

    cond do
      not is_binary(turn_id) ->
        {:error, :no_active_turn}

      not Log.terminal_event?(type) ->
        {:error, {:invalid_terminal_event, type}}

      true ->
        payload =
          data
          |> Map.put("turn_id", turn_id)
          |> Map.put_new("settled_at", now())

        case Codec.validate(payload) do
          :ok -> {:ok, Log.event(type, payload), turn_id}
          {:error, reason} -> {:error, {:invalid_settlement, reason}}
        end
    end
  end

  defp build_summary(state) do
    projection = state.projection

    metadata =
      projection
      |> Map.put(:status, live_status(state))
      |> Projection.metadata()

    Map.put(metadata, :search_text, Projection.search_text(projection))
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
      "summary" => Catalog.encode_summary(build_summary(state))
    }

    {:ok, :erlang.term_to_binary(payload, [:compressed])}
  rescue
    _error -> {:error, :summary_encode_failed}
  end

  defp state_active_turn_id(%{active_turn: %{turn_id: turn_id}}), do: turn_id
  defp state_active_turn_id(_state), do: nil

  defp notification_health({:error_status, status}), do: {:fatal, {:error_status, status}}
  defp notification_health({:full, _info}), do: {:fatal, :disk_full}
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

  defp call(journal, message), do: GenServer.call(journal, message, @call_timeout)

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
