defmodule Tackle.Session.Reader do
  @moduledoc """
  Bounded replay, validation, and controlled repair for a session journal.

  A reader folds internal `:disk_log` items in sequence order: validate the
  header and physical format, read items in bounded chunks, decode and validate
  one durable commit at a time, require contiguous sequence numbers, upcast
  older event versions, and apply events to a plain projection.

  Ordinary replay uses `:disk_log.bchunk/3` plus
  `:erlang.binary_to_term/2` with `:safe`, so replaying a journal cannot create
  new atoms or external function references. The `:safe` option protects the VM
  from specific External Term Format hazards; it does not establish that decoded
  data is valid, so durable validation still runs after decoding.

  Repair is never silent. Detecting an uncleanly closed log preserves the
  original file under `recovery/` before invoking internal repair, then records
  the recovered-item and bad-byte counts so the session can be marked recovered.
  """

  alias Tackle.Session.Log
  alias Tackle.Session.Projection
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
  Callers receive a classified projection or an explicit error describing the
  first invalid commit.
  """
  @spec read(String.t(), keyword()) :: {:ok, replay()} | {:error, term()}
  def read(session_id, opts \\ []) do
    with {:ok, path} <- journal_path(session_id, opts),
         :ok <- validate_journal_file(path) do
      case open(session_id, path, :read_only) do
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

  @doc "Reads a journal and returns its last committed sequence number."
  @spec last_seq(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def last_seq(session_id, opts \\ []) do
    with {:ok, replay} <- read(session_id, opts), do: {:ok, replay.last_seq}
  end

  @doc """
  Opens a journal for the single writable owner.

  When the log was not cleanly closed, repair must be explicitly allowed.
  Repair first preserves the original file under `recovery/`, then reports the
  recovered-item and bad-byte counts. A repaired journal is replayed and
  validated before it is returned, so a corrupt history is never resumed.
  """
  @spec open_writable(String.t(), keyword()) :: {:ok, open_result()} | {:error, term()}
  def open_writable(session_id, opts \\ []) do
    with {:ok, path} <- journal_path(session_id, opts) do
      new? = not File.exists?(path)

      case open(session_id, path, :read_write) do
        {:ok, name} ->
          finish_open(name, session_id, path, new?, nil)

        {:error, {:need_repair, file}} ->
          repair_open(session_id, path, file, opts)

        {:error, reason} ->
          {:error, {:journal_open_failed, path, reason}}
      end
    end
  end

  @doc "Closes a writable journal handle."
  @spec close(tuple()) :: :ok
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

  @doc "Returns the number of items currently stored in a live journal handle."
  @spec item_count(tuple()) :: non_neg_integer()
  def item_count(name) do
    case :disk_log.info(name) do
      info when is_list(info) -> Keyword.get(info, :items, 0)
      _other -> 0
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

  defp finish_open(name, session_id, path, new?, recovered) do
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

  defp fold(name, session_id, path) do
    do_fold(name, session_id, path)
  rescue
    error in Tackle.Session.ProjectionError -> {:error, {:invalid_projection, error.reason}}
  end

  defp do_fold(name, session_id, path) do
    with {:ok, items} <- collect(name),
         {:ok, header, raw_commits} <- split_header(items, path),
         :ok <- Log.validate_header(header, session_id),
         {:ok, projection, commits} <-
           fold_commits(raw_commits, Projection.new(header), session_id) do
      projection = Projection.classify(projection)

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
    with :ok <- Log.validate_commit(commit, session_id, expected),
         {:ok, upcasted} <- upcast_commit(commit) do
      {:ok, Projection.apply_commit(projection, upcasted), upcasted}
    end
  end

  defp upcast_commit(commit) do
    commit["events"]
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, acc} ->
      case Log.upcast_event(event) do
        {:ok, upcasted} -> {:cont, {:ok, [upcasted | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, %{commit | "events" => Enum.reverse(events)}}
      {:error, _reason} = error -> error
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

  defp open(session_id, path, mode) do
    options = [
      name: open_name(session_id, mode),
      file: String.to_charlist(path),
      type: :halt,
      format: :internal,
      mode: mode,
      repair: false,
      notify: mode == :read_write,
      size: :infinity
    ]

    :disk_log.open(options)
  end

  # A read-only reader must coexist with the single writable owner, so it never
  # reuses the canonical journal name.
  defp open_name(session_id, :read_only) do
    {:tackle_session_reader, session_id, System.unique_integer([:positive])}
  end

  defp open_name(session_id, :read_write), do: name(session_id)

  defp open_for_repair(session_id, path) do
    options = [
      name: name(session_id),
      file: String.to_charlist(path),
      type: :halt,
      format: :internal,
      mode: :read_write,
      repair: true,
      notify: true,
      size: :infinity
    ]

    case :disk_log.open(options) do
      {:repaired, name, {:recovered, recovered}, {:badbytes, bad_bytes}} ->
        {:repaired, name, recovered, bad_bytes}

      {:ok, name} ->
        {:ok, name}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp name(session_id), do: {:tackle_session, session_id}
end
