defmodule Tackle.Session.Storage.Lock do
  @moduledoc """
  Best-effort exclusive writable ownership for one session directory.

  `:disk_log` serializes callers that use the same open log on one node, but it
  does not prevent the same file from being opened under another name, in
  another BEAM, or on another node. This lock is a `Tackle.FileLock` on
  `writer.lock`, taken without waiting: on systems with `flock`, an
  operating-system advisory lock held by a port linked to the process that
  acquired it, so it is released when that process dies, including across PID
  namespaces; other systems fall back to a process-identity record.

  Either way `writer.lock` records its owner (OS pid, node, start time, and
  the process identity where the system reports one) as JSON, which a
  conflict returns as `{:error, {:session_in_use, owner}}`; lock files
  written by earlier versions without a process identity are still read.
  Stale fallback locks left behind by dead OS processes are reclaimed. A
  fallback lock outlives the journal process that took it, so that its
  deadline process can close the log before releasing it. Distributed
  leases and cross-node fencing are not promised; when ownership is uncertain
  Tackle fails rather than opening with automatic repair.
  """

  alias Tackle.FileLock

  @lock_file "writer.lock"

  @type owner :: FileLock.owner()
  @type t :: FileLock.t()

  @doc """
  Acquires the writable ownership lock beneath a session directory.

  Returns `{:error, {:session_in_use, owner}}` when another live process owns
  the session (`{:error, :session_in_use}` when its record is unreadable).
  With `reclaim: false`, a stale fallback lock is reported as in use instead
  of reclaimed: two processes reclaiming the same stale lock at once can both
  believe they own it, which background work must not risk.
  """
  @spec acquire(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def acquire(dir, opts \\ []) do
    lock_opts = [
      wait: :nonblock,
      reclaim: Keyword.get(opts, :reclaim, true),
      process_bound: false
    ]

    case FileLock.acquire(path(dir), lock_opts) do
      {:error, {:locked, nil}} -> {:error, :session_in_use}
      {:error, {:locked, owner}} -> {:error, {:session_in_use, owner}}
      result -> result
    end
  end

  @doc "Releases a lock previously returned by `acquire/2`."
  @spec release(t()) :: :ok
  def release(%FileLock{} = lock), do: FileLock.release(lock)

  @doc "Returns the lock file path inside a session directory."
  @spec path(String.t()) :: String.t()
  def path(dir), do: Path.join(dir, @lock_file)

  @doc "Returns the current process ownership description."
  @spec current_owner() :: owner()
  defdelegate current_owner, to: FileLock
end
