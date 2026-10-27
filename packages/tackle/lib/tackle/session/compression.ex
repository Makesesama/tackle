defmodule Tackle.Session.Compression do
  @moduledoc """
  Background compression of idle session journals.

  A journal that has not been written for a while (seven days by default) is
  replaced by a zstd-compressed copy of its exact bytes, `session.dlog.zst`
  (`Tackle.Session.CompressedFile`, which also describes how copies are
  verified). Agent sessions are mostly text and tool output, which compress
  about three to four times; encrypted provider reasoning compresses little.

  Compression is transparent to readers and writers:

    * read-only replay (`Tackle.Session.Reader`) decompresses into a private
      temporary file beside the journal and replays that;
    * a writable owner (`Tackle.Session.Journal`) restores the plain journal
      under the writer lock before opening it, so the session continues as an
      ordinary journal.

  A compressed journal never changes, so its summary sidecar is rewritten
  from a full replay before compression and the catalog can index it without
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
  alias Tackle.Session.CompressedFile
  alias Tackle.Session.Journal
  alias Tackle.Session.Reader
  alias Tackle.Session.Storage
  alias Tackle.Session.Storage.Lock

  @min_age :timer.hours(24 * 7)
  @min_interval :timer.hours(6)
  @stale_temp_age :timer.hours(1)
  @marker "compression.marker"

  @type report :: %{
          compressed: non_neg_integer(),
          bytes_before: non_neg_integer(),
          bytes_after: non_neg_integer(),
          skipped: non_neg_integer()
        }

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
      not CompressedFile.available?() ->
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
         :ok <- Journal.ensure_not_live(session_id),
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
         {:ok, compressed, plain_size} <- CompressedFile.compress(path),
         {:ok, replay} <- Reader.read(session_id, Keyword.put(location, :path, path)) do
      {:ok,
       %{
         path: path,
         stat: {stat.size, stat.mtime},
         plain_size: plain_size,
         compressed: compressed,
         sidecar:
           Catalog.sidecar(replay.projection, %{"size" => stat.size, "mtime" => stat.mtime})
       }}
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
    %{path: path, compressed: compressed, plain_size: plain_size} = prepared

    with :ok <- ensure_unchanged(path, prepared.stat),
         {:ok, summary} <- Storage.summary_path(session_id, location),
         :ok <- Storage.atomic_write(summary, prepared.sidecar, create_dir: false),
         :ok <- CompressedFile.replace(path, compressed, plain_size) do
      {:compressed, plain_size, byte_size(compressed)}
    else
      {:error, reason} -> {:skipped, session_id, reason}
    end
  end

  defp ensure_unchanged(path, {size, mtime}) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: ^size, mtime: ^mtime}} -> :ok
      {:ok, _changed} -> {:error, :journal_changed}
      {:error, reason} -> {:error, {:journal_missing, reason}}
    end
  end

  defp idle?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} -> mtime <= cutoff
      _missing -> false
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
    case CompressedFile.compress_file(path) do
      {:ok, before, compressed} -> {:compressed, before, compressed}
      {:error, reason} -> {:skipped, session_id, reason}
    end
  end

  # -- temporary files -----------------------------------------------------------

  # Read copies and interrupted atomic writes from a process that died.
  defp sweep_temporary_files(session_id, location) do
    with {:ok, dir} <- Storage.session_dir(session_id, location),
         {:ok, files} <- File.ls(dir) do
      cutoff = System.os_time(:second) - div(@stale_temp_age, 1000)

      files
      |> Enum.filter(&(CompressedFile.read_copy?(&1) or String.contains?(&1, ".tmp-")))
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&idle?(&1, cutoff))
      |> Enum.each(&File.rm/1)
    end

    :ok
  end

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
