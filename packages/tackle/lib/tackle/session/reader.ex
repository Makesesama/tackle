defmodule Tackle.Session.Reader do
  @moduledoc """
  Bounded replay, validation, and controlled repair for a session journal.

  A reader folds internal `:disk_log` items in sequence order: validate the
  header and physical format, read items in bounded chunks, decode one durable
  commit at a time, require contiguous sequence numbers, upcast older event
  versions and then validate the events against the current schema
  (`Tackle.Session.Log.read_commit/4`), and apply them to a plain projection.

  Ordinary replay uses `:disk_log.bchunk/3` plus
  `:erlang.binary_to_term/2` with `:safe`, so replaying a journal cannot create
  new atoms or external function references. The `:safe` option protects the VM
  from specific External Term Format hazards; it does not establish that decoded
  data is valid, so durable validation still runs after decoding.

  Repair is never silent. Detecting an uncleanly closed log preserves the
  original file under `recovery/` before invoking internal repair, then records
  the recovered-item and bad-byte counts so the session can be marked recovered.

  The reader owns every `:disk_log` handle of a journal: it opens them, always
  with the same options (`:internal` format, `:halt` type, no size limit), and
  names them. A session's writable log is `name/1`; read-only readers and new
  files (`write_journal/2`) get names of their own, so they coexist with it.
  """

  alias Tackle.Session.CompressedFile
  alias Tackle.Session.Log
  alias Tackle.Session.Projection
  alias Tackle.Session.ProjectionError
  alias Tackle.Session.Storage

  @chunk_size 100

  @type replay :: %{
          required(:header) => map(),
          required(:projection) => Projection.t(),
          required(:commits) => [map()],
          required(:last_seq) => non_neg_integer(),
          required(:status) => atom()
        }

  @type open_result :: %{
          required(:name) => tuple(),
          required(:path) => String.t(),
          required(:projection) => Projection.t(),
          required(:recovered) => map() | nil,
          required(:new?) => boolean()
        }

  @doc """
  Reads and validates a session journal without creating a writable owner.

  Read-only replay works on an uncleanly closed journal and never repairs it.
  A compressed journal is replayed from a temporary decompressed copy.
  Callers receive a classified projection or an explicit error describing the
  first invalid commit.

  Besides the location options of `Tackle.Session.Storage`, `:path` names the
  journal file directly (a session's known file, or a temporary copy).
  """
  @spec read(String.t(), keyword()) :: {:ok, replay()} | {:error, term()}
  def read(session_id, opts \\ []) do
    with {:ok, path} <- journal_path(session_id, opts) do
      CompressedFile.with_readable(path, &read_file(session_id, &1, path))
    end
  end

  # `readable` may be a decompressed copy; errors name the journal itself.
  defp read_file(session_id, readable, path) do
    with :ok <- validate_journal_file(readable) do
      case open_log(reader_name(session_id), readable, :read_only) do
        {:ok, name} ->
          try do
            fold(name, session_id, path)
          after
            _ = :disk_log.close(name)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Reads a journal and returns only its durable projection."
  @spec projection(String.t(), keyword()) :: {:ok, Projection.t()} | {:error, term()}
  def projection(session_id, opts \\ []) do
    with {:ok, replay} <- read(session_id, opts), do: {:ok, replay.projection}
  end

  @doc """
  Opens a journal for the single writable owner.

  The journal file is made private (`Tackle.Session.Storage.file_mode/0`),
  including one an earlier version created with the default mode.

  When the log was not cleanly closed, repair must be explicitly allowed.
  Repair first preserves the original file under `recovery/`, then reports the
  recovered-item and bad-byte counts. A repaired journal is replayed and
  validated before it is returned, so a corrupt history is never resumed.

  The journal is always the one at the session's location: unlike `read/2`,
  no `:path` selects another file, so the writer opens the journal of the
  directory whose lock it holds.
  """
  @spec open_writable(String.t(), keyword()) :: {:ok, open_result()} | {:error, term()}
  def open_writable(session_id, opts \\ []) do
    with {:ok, path} <- Storage.journal_path(session_id, opts) do
      new? = not File.exists?(path)

      case open_log(name(session_id), path, :read_write, notify: true) do
        {:ok, name} ->
          finish_open(name, session_id, path, new?, nil)

        {:error, {:need_repair, file}} ->
          repair_open(session_id, path, file, opts)

        {:error, reason} ->
          {:error, {:journal_open_failed, path, reason}}
      end
    end
  end

  @doc """
  The name of a session's writable log, which `open_writable/2` opens.

  Only the session's journal owner holds it; it is a tuple holding the
  binary session id, so no atom is created per session.
  """
  @spec name(String.t()) :: tuple()
  def name(session_id), do: {:tackle_session, session_id}

  @doc """
  Writes a new journal file at `path` holding `items` (a header and its
  commits, in order), syncs it, and closes it.

  The file must not be open elsewhere; a fork writes its child this way into
  a directory no one else knows yet. The log is closed whether or not writing
  succeeded, and a write error wins over a close error.
  """
  @spec write_journal(String.t(), [map()]) :: :ok | {:error, term()}
  def write_journal(path, items) when is_list(items) do
    name = {:tackle_session_file, System.unique_integer([:positive])}

    case open_log(name, path, :read_write) do
      {:ok, name} ->
        result =
          with :ok <- log_all(name, items), do: sync(name)

        case {result, close(name)} do
          {:ok, :ok} -> :ok
          {:ok, {:error, reason}} -> {:error, {:journal_close_failed, reason}}
          {{:error, _reason} = error, _closed} -> error
        end

      {:error, reason} ->
        {:error, {:journal_open_failed, path, reason}}
    end
  end

  defp log_all(name, items) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case log(name, item) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "Closes a journal handle."
  @spec close(tuple()) :: :ok | {:error, term()}
  def close(name), do: :disk_log.close(name)

  @doc "Syncs a live journal handle to stable storage."
  @spec sync(tuple()) :: :ok | {:error, term()}
  def sync(name) do
    case :disk_log.sync(name) do
      :ok -> :ok
      {:error, reason} -> {:error, {:journal_sync_failed, reason}}
    end
  end

  @doc "Appends one durable item to a live journal handle."
  @spec log(tuple(), term()) :: :ok | {:error, term()}
  def log(name, item) do
    case :disk_log.log(name, item) do
      :ok -> :ok
      {:error, reason} -> {:error, {:journal_append_failed, reason}}
    end
  end

  defp repair_open(session_id, path, file, opts) do
    if Keyword.get(opts, :repair, false) do
      do_repair(session_id, path, file, opts)
    else
      {:error, {:repair_required, path}}
    end
  end

  defp do_repair(session_id, path, file, opts) do
    with {:ok, _preserved} <- Storage.preserve_for_recovery(session_id, file, opts) do
      case open_for_repair(session_id, path) do
        {:repaired, name, recovered, badbytes} ->
          repaired_result(name, session_id, path, recovered, badbytes)

        {:ok, name} ->
          finish_open(name, session_id, path, false, nil)

        {:error, reason} ->
          {:error, {:journal_open_failed, path, reason}}
      end
    end
  end

  defp repaired_result(name, session_id, path, recovered, badbytes) do
    recovered_info = %{
      "recovered_items" => recovered,
      "bad_bytes" => badbytes,
      "repaired_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    with :ok <- protect(name, path) do
      case fold(name, session_id, path) do
        {:ok, replay} ->
          {:ok,
           %{
             name: name,
             path: path,
             projection: replay.projection,
             recovered: recovered_info,
             new?: false
           }}

        {:error, reason} ->
          _ = :disk_log.close(name)
          {:error, {:repaired_history_invalid, reason}}
      end
    end
  end

  # `:disk_log` creates the file with the default mode.
  defp protect(name, path) do
    case File.chmod(path, Storage.file_mode()) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = :disk_log.close(name)
        {:error, {:journal_open_failed, path, {:chmod_failed, reason}}}
    end
  end

  defp finish_open(name, session_id, path, new?, recovered) do
    with :ok <- protect(name, path) do
      case fold(name, session_id, path) do
        {:ok, replay} ->
          {:ok,
           %{
             name: name,
             path: path,
             projection: replay.projection,
             recovered: recovered,
             new?: new?
           }}

        {:error, {:empty_journal, _path}} ->
          {:ok, %{name: name, path: path, projection: nil, recovered: nil, new?: true}}

        {:error, reason} ->
          _ = :disk_log.close(name)
          {:error, reason}
      end
    end
  end

  # The projection raises `ProjectionError` for a commit it cannot fold. Any
  # other exception is a malformed record it did not anticipate; it is
  # reported by type only, since its message can carry conversation data.
  defp fold(name, session_id, path) do
    do_fold(name, session_id, path)
  rescue
    error in ProjectionError -> {:error, {:invalid_projection, error.reason}}
    error -> {:error, {:invalid_projection, {:exception, error.__struct__}}}
  end

  defp do_fold(name, session_id, path) do
    with {:ok, items} <- collect(name),
         {:ok, header, raw_commits} <- split_header(items, path),
         :ok <- Log.validate_header(header, session_id),
         {:ok, projection, commits} <-
           fold_commits(raw_commits, Projection.new(header), session_id) do
      projection = Projection.refresh(projection)

      {:ok,
       %{
         header: header,
         projection: projection,
         commits: commits,
         last_seq: projection.last_seq,
         status: projection.status
       }}
    end
  end

  defp split_header([], path), do: {:error, {:empty_journal, path}}
  defp split_header([header | commits], _path), do: {:ok, header, commits}

  defp fold_commits(commits, projection, session_id) do
    commits
    |> Enum.reduce_while({:ok, projection, [], 1}, fn commit, {:ok, acc, all, expected} ->
      case apply_commit(commit, acc, session_id, expected) do
        {:ok, next, upcasted} -> {:cont, {:ok, next, [upcasted | all], expected + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, projection, all, _expected} -> {:ok, projection, Enum.reverse(all)}
      {:error, _reason} = error -> error
    end
  end

  defp apply_commit(commit, projection, session_id, expected) do
    with {:ok, upcasted} <- Log.read_commit(commit, session_id, expected) do
      {:ok, Projection.apply_replay_commit(projection, upcasted), upcasted}
    end
  end

  defp collect(name) do
    do_collect(:disk_log.bchunk(name, :start, @chunk_size), name, [], 0)
  end

  defp do_collect({:error, reason}, _name, _acc, position) do
    {:error, {:journal_read_failed, reason, position}}
  end

  defp do_collect(:eof, _name, acc, _position), do: {:ok, Enum.reverse(acc)}

  defp do_collect({_continuation, _items, bad_bytes}, _name, _acc, _position)
       when is_integer(bad_bytes) and bad_bytes > 0 do
    {:error, {:journal_bad_bytes, bad_bytes}}
  end

  defp do_collect({continuation, items, _no_bad_bytes}, name, acc, position) do
    continue_collect(continuation, items, name, acc, position)
  end

  defp do_collect({continuation, items}, name, acc, position) do
    continue_collect(continuation, items, name, acc, position)
  end

  defp continue_collect(continuation, items, name, acc, position) do
    case decode_items(items, position) do
      {:ok, decoded} ->
        do_collect(
          :disk_log.bchunk(name, continuation, @chunk_size),
          name,
          Enum.reverse(decoded) ++ acc,
          position + length(decoded)
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_items(items, position) do
    items
    |> Enum.with_index(position)
    |> Enum.reduce_while({:ok, []}, fn {binary, index}, {:ok, acc} ->
      case decode_item(binary, index) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_item(binary, index) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> {:error, {:undecodable_item, index}}
  end

  defp validate_journal_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:invalid_journal_file, path, type}}
      {:error, _reason} -> :ok
    end
  end

  defp journal_path(session_id, opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) -> {:ok, path}
      {:ok, other} -> {:error, {:invalid_journal_path, other}}
      :error -> Storage.journal_path(session_id, opts)
    end
  end

  # Every journal handle is opened here. `:repair` (default false) lets
  # `:disk_log` repair a log that was not closed cleanly, and `:notify`
  # (default false) sends the opening process its notifications.
  defp open_log(name, path, mode, opts \\ []) do
    :disk_log.open(
      name: name,
      file: String.to_charlist(path),
      type: :halt,
      format: :internal,
      mode: mode,
      repair: Keyword.get(opts, :repair, false),
      notify: Keyword.get(opts, :notify, false),
      size: :infinity
    )
  end

  # A read-only reader must coexist with the single writable owner, so it never
  # reuses the canonical journal name.
  defp reader_name(session_id) do
    {:tackle_session_reader, session_id, System.unique_integer([:positive])}
  end

  defp open_for_repair(session_id, path) do
    case open_log(name(session_id), path, :read_write, repair: true, notify: true) do
      {:repaired, name, {:recovered, recovered}, {:badbytes, bad_bytes}} ->
        {:repaired, name, recovered, bad_bytes}

      {:ok, name} ->
        {:ok, name}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
