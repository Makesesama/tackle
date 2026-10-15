defmodule Tackle.Session.Compression do
  @moduledoc """
  Compressed storage for idle session journals.

  A journal that has not been written for a while (seven days by default) is
  replaced by a zstd-compressed copy of its exact bytes, `session.dlog.zst`.
  Agent sessions are mostly text and tool output, which compress about three
  to four times; encrypted provider reasoning compresses little.

  Compression is transparent to readers and writers:

    * read-only replay (`Tackle.Session.Reader`) decompresses into a private
      temporary file beside the journal and replays that;
    * a writable owner (`Tackle.Session.Journal`) restores the plain journal
      under the writer lock before opening it, so the session continues as an
      ordinary journal.

  The plain journal is authoritative. Compression writes and verifies the
  compressed copy before deleting the plain file, and restoring writes the
  plain file before deleting the compressed one, so an interruption leaves at
  most a redundant copy. Every decompression is checked against the original
  size recorded in the zstd frame (zstd itself returns a truncated frame's
  partial output without an error) and against the frame checksum. A
  compressed journal never changes, so its summary sidecar is rewritten from a
  full replay before compression and the catalog can index it without
  decompressing.

  The expensive work (replay, compression, verification) happens before the
  session's writer lock is taken; the lock covers only the final check that
  the journal is unchanged, the writes, and the unlink, so a frontend resuming
  the same session waits at most briefly.

  `compress_idle/1` also compresses idle recovery copies under `recovery/`,
  which are kept only for diagnosis, and removes stale temporary files.
  """

  require Logger

  alias Tackle.Session.Catalog
  alias Tackle.Session.Journal
  alias Tackle.Session.Reader
  alias Tackle.Session.Storage
  alias Tackle.Session.Storage.Lock

  @min_age :timer.hours(24 * 7)
  @min_interval :timer.hours(6)
  @stale_temp_age :timer.hours(1)
  @level 3
  @marker "compression.marker"
  @read_prefix "session.dlog.read-"

  @type report :: %{
          compressed: non_neg_integer(),
          bytes_before: non_neg_integer(),
          bytes_after: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @doc "Whether zstd compression is available in this runtime (OTP 28 or later)."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(:zstd)

  @doc """
  Compresses every idle journal and recovery copy, active and archived.

  Options, besides the storage location options (`:home`, `:env`):

    * `:min_age` — milliseconds since a file's last modification before it is
      compressed (default seven days);
    * `:min_interval` — milliseconds between passes (default six hours). A
      marker under `sessions/catalog/` records the last pass, so concurrent or
      frequent callers return `{:ok, :recently_run}`. Pass `0` to force a pass.

  A session that is live in this node or locked by another process is skipped
  and retried on a later pass, as is a journal that cannot be read. Returns a
  report of what was compressed.
  """
  @spec compress_idle(keyword()) :: {:ok, report() | :recently_run} | {:error, term()}
  def compress_idle(opts \\ []) do
    storage_opts = Keyword.drop(opts, [:min_age, :min_interval])

    cond do
      not available?() ->
        {:error, :zstd_unavailable}

      not due?(storage_opts, Keyword.get(opts, :min_interval, @min_interval)) ->
        {:ok, :recently_run}

      true ->
        run_pass(storage_opts, Keyword.get(opts, :min_age, @min_age))
    end
  end

  defp run_pass(storage_opts, min_age) do
    with :ok <- touch_marker(storage_opts),
         {:ok, locations} <- Storage.list_session_locations(storage_opts) do
      cutoff = System.os_time(:second) - div(min_age, 1000)
      empty = %{compressed: 0, bytes_before: 0, bytes_after: 0, skipped: 0}

      {:ok, Enum.reduce(locations, empty, &compress_location(&1, &2, cutoff))}
    end
  end

  # -- one session -------------------------------------------------------------

  defp compress_location({session_id, location}, report, cutoff) do
    report = report |> add(compress_session(session_id, location, cutoff))
    report = add_recovery(report, session_id, location, cutoff)
    sweep_temporary_files(session_id, location)
    report
  end

  # One session's failure, even an unexpected exception, never ends the pass.
  defp compress_session(session_id, location, cutoff) do
    with {:ok, path} <- Storage.journal_path(session_id, location),
         true <- idle?(path, cutoff) || :fresh,
         :ok <- ensure_not_live(session_id),
         {:ok, prepared} <- prepare(session_id, location, path) do
      swap(session_id, location, prepared)
    else
      :fresh -> :ignored
      {:error, reason} -> {:skipped, session_id, reason}
    end
  rescue
    error -> {:skipped, session_id, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:skipped, session_id, {kind, reason}}
  end

  # Without the lock: a writer appending meanwhile changes the file's size or
  # modification time, which `swap/3` detects before anything is replaced.
  defp prepare(session_id, location, path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, plain} <- read(path),
         {:ok, replay} <- Reader.read(session_id, Keyword.put(location, :path, path)),
         {:ok, compressed} <- compress(plain),
         {:ok, ^plain} <- decompress(compressed, path) do
      {:ok,
       %{
         path: path,
         stat: {stat.size, stat.mtime},
         plain_size: byte_size(plain),
         compressed: compressed,
         sidecar: Catalog.sidecar(replay.projection)
       }}
    else
      {:ok, _different} -> {:error, {:verify_failed, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp swap(session_id, location, prepared) do
    with {:ok, dir} <- Storage.session_dir(session_id, location),
         {:ok, lock} <- Lock.acquire(dir, reclaim: false) do
      try do
        swap_locked(session_id, location, prepared)
      after
        Storage.release_lock(lock)
      end
    else
      {:error, reason} -> {:skipped, session_id, reason}
    end
  end

  defp swap_locked(session_id, location, prepared) do
    %{path: path, compressed: compressed} = prepared
    destination = Storage.compressed_path(path)

    with :ok <- ensure_unchanged(path, prepared.stat),
         {:ok, summary} <- Storage.summary_path(session_id, location),
         :ok <- Storage.atomic_write(summary, prepared.sidecar, create_dir: false),
         :ok <- Storage.atomic_write(destination, compressed, create_dir: false),
         :ok <- verify_file(destination, path, prepared.plain_size),
         :ok <- remove(path) do
      {:compressed, prepared.plain_size, byte_size(compressed)}
    else
      {:error, reason} ->
        if File.regular?(path), do: _ = File.rm(destination)
        {:skipped, session_id, reason}
    end
  end

  defp ensure_unchanged(path, {size, mtime}) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: ^size, mtime: ^mtime}} -> :ok
      {:ok, _changed} -> {:error, :journal_changed}
      {:error, reason} -> {:error, {:journal_missing, reason}}
    end
  end

  # The written file is checked for the full original size, which also catches
  # a short write; its content was already verified in memory.
  defp verify_file(compressed_path, path, plain_size) do
    with {:ok, binary} <- read(compressed_path),
         {:ok, plain} <- decompress(binary, path) do
      if byte_size(plain) == plain_size,
        do: :ok,
        else: {:error, {:verify_failed, compressed_path}}
    end
  end

  defp idle?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} -> mtime <= cutoff
      _missing -> false
    end
  end

  defp ensure_not_live(session_id) do
    case Journal.whereis(session_id) do
      {:ok, _journal} -> {:error, :session_active}
      {:error, :not_found} -> :ok
    end
  end

  # -- recovery copies -----------------------------------------------------------

  defp add_recovery(report, session_id, location, cutoff) do
    with {:ok, dir} <- Storage.recovery_dir(session_id, location),
         {:ok, files} <- File.ls(dir) do
      files
      |> Enum.reject(&(String.ends_with?(&1, ".zst") or String.contains?(&1, ".tmp-")))
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&idle?(&1, cutoff))
      |> Enum.reduce(report, &add(&2, compress_recovery_copy(&1, session_id)))
    else
      _no_recovery -> report
    end
  end

  defp compress_recovery_copy(path, session_id) do
    case compress_file(path) do
      {:ok, before, compressed} -> {:compressed, before, compressed}
      {:error, reason} -> {:skipped, session_id, reason}
    end
  end

  # -- files ---------------------------------------------------------------------

  @doc """
  Replaces `path` with a verified zstd copy at `path <> ".zst"`.

  Returns the plain and compressed sizes. The plain file is deleted only after
  the compressed copy is written and decompresses to the same bytes. The
  directory is never created, so a file whose directory was moved meanwhile
  is left alone. Used for recovery copies, which no writer appends to.
  """
  @spec compress_file(String.t()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, term()}
  def compress_file(path) do
    destination = Storage.compressed_path(path)

    with {:ok, plain} <- read(path),
         {:ok, compressed} <- compress(plain),
         :ok <- Storage.atomic_write(destination, compressed, create_dir: false),
         :ok <- verify(destination, plain),
         :ok <- remove(path) do
      {:ok, byte_size(plain), byte_size(compressed)}
    else
      {:error, reason} ->
        # The plain file is intact; drop a copy that failed verification.
        if File.regular?(path), do: _ = File.rm(destination)
        {:error, reason}
    end
  end

  @doc """
  Restores the plain journal at `path` from its compressed copy.

  Call it while holding the session's writer lock. A missing compressed copy,
  or a plain journal that already exists, is left alone: the plain journal is
  authoritative, and a leftover compressed copy is removed.
  """
  @spec restore(String.t()) :: :ok | {:error, term()}
  def restore(path) do
    compressed_path = Storage.compressed_path(path)

    cond do
      not File.regular?(compressed_path) ->
        :ok

      File.regular?(path) ->
        remove(compressed_path)

      true ->
        with {:ok, plain} <- decompress_file(compressed_path),
             :ok <- Storage.atomic_write(path, plain) do
          remove(compressed_path)
        end
    end
  end

  @doc """
  Runs `fun` with a readable plain journal for `path`.

  A plain journal is passed through. Otherwise a compressed journal is
  decompressed into a private temporary file beside it for the duration of
  `fun`. A plain journal that is compressed between the check and the read is
  retried from its compressed copy.
  """
  @spec with_readable(String.t(), (String.t() -> result)) :: result | {:error, term()}
        when result: term()
  def with_readable(path, fun) do
    compressed_path = Storage.compressed_path(path)

    cond do
      File.regular?(path) ->
        path |> fun.() |> retry_compressed(path, compressed_path, fun)

      File.regular?(compressed_path) ->
        read_compressed(path, compressed_path, fun)

      true ->
        fun.(path)
    end
  end

  # The plain journal was compressed between the check and the read.
  defp retry_compressed({:error, _reason} = error, path, compressed_path, fun) do
    if not File.exists?(path) and File.regular?(compressed_path),
      do: read_compressed(path, compressed_path, fun),
      else: error
  end

  defp retry_compressed(result, _path, _compressed_path, _fun), do: result

  defp read_compressed(path, compressed_path, fun) do
    temp = Path.join(Path.dirname(path), @read_prefix <> unique())

    with {:ok, plain} <- decompress_file(compressed_path),
         :ok <- write_private(temp, plain) do
      try do
        fun.(temp)
      after
        _ = File.rm(temp)
      end
    else
      # A writable owner restored the plain journal meanwhile.
      {:error, {:read_failed, ^compressed_path, :enoent}} = error ->
        if File.regular?(path), do: fun.(path), else: error

      {:error, _reason} = error ->
        error
    end
  end

  defp decompress_file(path) do
    with {:ok, compressed} <- read(path), do: decompress(compressed, path)
  end

  # zstd returns a truncated frame's partial output without an error, so the
  # result must match the content size the frame header declares.
  defp decompress(compressed, path) do
    if available?() do
      with {:ok, %{frameContentSize: size}} when is_integer(size) <-
             :zstd.get_frame_header(compressed),
           plain = compressed |> :zstd.decompress() |> IO.iodata_to_binary(),
           ^size <- byte_size(plain) do
        {:ok, plain}
      else
        other -> {:error, {:decompress_failed, path, decompress_reason(other)}}
      end
    else
      {:error, {:zstd_unavailable, path}}
    end
  rescue
    error -> {:error, {:decompress_failed, path, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:decompress_failed, path, {kind, reason}}}
  end

  defp decompress_reason(size) when is_integer(size), do: {:truncated, size}
  defp decompress_reason({:ok, _header}), do: :unknown_content_size
  defp decompress_reason(other), do: other

  defp compress(plain) do
    options = %{compressionLevel: @level, checksumFlag: true}
    {:ok, plain |> :zstd.compress(options) |> IO.iodata_to_binary()}
  rescue
    error -> {:error, {:compress_failed, Exception.message(error)}}
  end

  defp verify(compressed_path, plain) do
    case decompress_file(compressed_path) do
      {:ok, ^plain} -> :ok
      {:ok, _other} -> {:error, {:verify_failed, compressed_path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:remove_failed, path, reason}}
    end
  end

  defp write_private(path, content) do
    with :ok <- File.write(path, content, [:raw, :exclusive]),
         :ok <- File.chmod(path, Storage.file_mode()) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(path)
        {:error, {:write_failed, path, reason}}
    end
  end

  # Read copies and interrupted atomic writes from a process that died.
  defp sweep_temporary_files(session_id, location) do
    with {:ok, dir} <- Storage.session_dir(session_id, location),
         {:ok, files} <- File.ls(dir) do
      cutoff = System.os_time(:second) - div(@stale_temp_age, 1000)

      files
      |> Enum.filter(&(String.starts_with?(&1, @read_prefix) or String.contains?(&1, ".tmp-")))
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&idle?(&1, cutoff))
      |> Enum.each(&File.rm/1)
    end

    :ok
  end

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  # -- pass bookkeeping ---------------------------------------------------------

  defp due?(_opts, 0), do: true

  defp due?(opts, interval) do
    with {:ok, root} <- Storage.catalog_root(opts),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(Path.join(root, @marker), time: :posix) do
      System.os_time(:second) - mtime >= div(interval, 1000)
    else
      _no_marker -> true
    end
  end

  defp touch_marker(opts) do
    with {:ok, root} <- Storage.catalog_root(opts),
         :ok <- Storage.ensure_private_dir(root) do
      Storage.atomic_write(Path.join(root, @marker), DateTime.to_iso8601(DateTime.utc_now()))
    end
  end

  defp add(report, {:compressed, before, compressed}) do
    %{
      report
      | compressed: report.compressed + 1,
        bytes_before: report.bytes_before + before,
        bytes_after: report.bytes_after + compressed
    }
  end

  defp add(report, {:skipped, session_id, reason}) do
    Logger.debug("session compression skipped #{session_id}: #{inspect(reason)}")
    %{report | skipped: report.skipped + 1}
  end

  defp add(report, :ignored), do: report
end
