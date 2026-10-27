defmodule Tackle.FileLock do
  @moduledoc """
  An exclusive lock on a file, shared by every operating-system process that
  locks the same path.

  On systems with `flock(1)` and `sh`, the lock is an operating-system advisory
  lock (`flock(2)`), reliable across processes and PID namespaces. It is held
  by a port running `flock`, linked to the Erlang process that acquired it, so
  it is released when that process exits, however it exits. Each acquisition
  starts its own `flock` process, so two Erlang processes in one VM exclude
  each other exactly as two OS processes do. The lock file is never deleted:
  deleting a file others may be locking would let two holders lock different
  files under the same name.

  Other systems fall back to an owner record created exclusively at the path
  and removed on release. A record is stale when its OS process is gone (or
  the PID now belongs to another process, where the system reports process
  identities), or when the file holds no record and is more than five seconds
  old (its holder died between creating and writing it); unless
  `reclaim: false`, a stale record is replaced. Release removes the record
  only while it is still the holder's own. The
  fallback is only as strong as that record: two processes reclaiming the same
  stale record at once can both believe they hold the lock.

  Either way the file holds the owner as JSON (OS pid, node, start time, and
  the process identity where the system reports one), which a conflict
  returns as `{:error, {:locked, owner}}`. Lock files are `0600`.

  The lock is not re-entrant: acquiring a path the calling process already
  holds waits for itself.
  """

  @enforce_keys [:path, :owner]
  defstruct [:path, :owner, :port]

  @typedoc "The owner record: OS pid, node, start time, and process identity."
  @type owner :: %{
          required(String.t()) => String.t() | integer()
        }

  @typedoc "A held lock; `port` is the `flock` port, `nil` for the fallback."
  @type t :: %__MODULE__{path: String.t(), owner: owner(), port: port() | nil}

  @type wait :: :nonblock | non_neg_integer()

  @process_identity_key "process_identity"
  @holder_key "holder"
  @lock_ready "TACKLE_WRITER_LOCK_READY"
  @lock_conflict_exit 75
  # How long `flock` may take to start and report, beyond the requested wait.
  @lock_start_margin 5_000
  @fallback_poll_interval 50
  @abandoned_record_grace_seconds 5
  @file_mode 0o600

  @doc """
  Acquires the exclusive lock on `path`, creating the file if needed.

  Options:

    * `:wait` - `:nonblock` (the default) fails at once with
      `{:error, {:locked, owner | nil}}` when another holder has the lock; a
      timeout in milliseconds waits up to that long and then fails with
      `{:error, {:lock_timeout, path}}`.
    * `:reclaim` - fallback only (default `true`). With `false`, a stale
      record is reported as locked instead of reclaimed: two processes
      reclaiming the same stale record at once can both believe they hold it,
      which callers that must never share the lock cannot risk.
    * `:process_bound` - fallback only (default `true`). The record names the
      acquiring Erlang process, and a record from this VM whose process has
      exited is stale, so the fallback is also released by the holder's exit.
      With `false` the record stays until `release/1` or until the OS process
      exits, for callers that release on behalf of a holder that died.
    * `:advisory` - default `true`; `false` uses the fallback even where
      `flock` exists.

  Other failures are `{:lock_create_failed, path, reason}`,
  `{:lock_write_failed, path, reason}`, `{:lock_start_failed, path, ...}`, and
  `{:lock_start_timeout, path}` when `flock` does not report in time.
  """
  @spec acquire(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def acquire(path, opts \\ []) when is_binary(path) do
    wait = Keyword.get(opts, :wait, :nonblock)

    case advisory_lock_executables(Keyword.get(opts, :advisory, true)) do
      {:ok, flock, shell} ->
        acquire_advisory(path, flock, shell, wait)

      :error ->
        acquire_fallback(path, wait, Keyword.get(opts, :reclaim, true), opts)
    end
  end

  @doc "Releases a lock previously returned by `acquire/2`."
  @spec release(t()) :: :ok
  def release(%__MODULE__{port: port}) when is_port(port) do
    _ = release_advisory(port)
    :ok
  end

  # A record that is no longer this lock's (it was judged stale and
  # reclaimed) belongs to its new holder and stays.
  def release(%__MODULE__{path: path, owner: owner}) do
    if read_owner(path) == owner, do: _ = File.rm(path)
    :ok
  end

  @doc """
  Runs `fun` in the caller while holding the lock on `path`.

  Takes the options of `acquire/2`. Returns `{:ok, result}` with what `fun`
  returned, or the `{:error, reason}` of `acquire/2`. The lock is released
  when `fun` returns, raises, throws, or exits, and when the caller dies.
  """
  @spec with_lock(String.t(), keyword(), (-> result)) :: {:ok, result} | {:error, term()}
        when result: term()
  def with_lock(path, opts, fun) when is_function(fun, 0) do
    with {:ok, lock} <- acquire(path, opts) do
      try do
        {:ok, fun.()}
      after
        release(lock)
      end
    end
  end

  @doc "Returns the owner record of the calling OS process."
  @spec current_owner() :: owner()
  def current_owner do
    owner = %{
      "pid" => System.pid(),
      "node" => to_string(node()),
      "started_at" => System.system_time(:second)
    }

    case process_identity(System.pid()) do
      {:ok, identity} -> Map.put(owner, @process_identity_key, identity)
      :error -> owner
    end
  end

  defp advisory_lock_executables(false), do: :error

  defp advisory_lock_executables(true) do
    with flock when is_binary(flock) <- System.find_executable("flock"),
         shell when is_binary(shell) <- System.find_executable("sh") do
      {:ok, flock, shell}
    else
      _missing -> :error
    end
  end

  ## flock

  defp acquire_advisory(path, flock, shell, wait) do
    with :ok <- create_private(path) do
      start_advisory(path, flock, shell, wait)
    end
  end

  # `flock` would create the file with the umask's mode; created here first,
  # it is private before anything is written to it.
  defp create_private(path) do
    with {:ok, device} <- :file.open(path, [:append, :raw]),
         :ok <- :file.close(device),
         :ok <- File.chmod(path, @file_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:lock_create_failed, path, reason}}
    end
  end

  defp start_advisory(path, flock, shell, wait) do
    port =
      Port.open(
        {:spawn_executable, flock},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args:
            ["--exclusive"] ++
              wait_args(wait) ++
              [
                "--conflict-exit-code",
                Integer.to_string(@lock_conflict_exit),
                path,
                shell,
                "-c",
                "printf '#{@lock_ready}\\n'; IFS= read -r _"
              ]
        ]
      )

    await_advisory_lock(port, path, wait, "")
  rescue
    error -> {:error, {:lock_start_failed, path, Exception.message(error)}}
  end

  defp wait_args(:nonblock), do: ["--nonblock"]

  defp wait_args(timeout) when is_integer(timeout) and timeout >= 0,
    do: ["--timeout", :erlang.float_to_binary(timeout / 1_000, decimals: 3)]

  defp await_advisory_lock(port, path, wait, output) do
    receive do
      {^port, {:data, data}} ->
        output = output <> data

        if String.contains?(output, @lock_ready) do
          write_advisory_owner(port, path)
        else
          await_advisory_lock(port, path, wait, output)
        end

      {^port, {:exit_status, @lock_conflict_exit}} ->
        forget_port(port)
        conflict(path, wait)

      {^port, {:exit_status, status}} ->
        forget_port(port)
        {:error, {:lock_start_failed, path, status, String.trim(output)}}
    after
      start_timeout(wait) ->
        close_port(port)
        {:error, {:lock_start_timeout, path}}
    end
  end

  defp start_timeout(:nonblock), do: @lock_start_margin
  defp start_timeout(timeout), do: timeout + @lock_start_margin

  defp conflict(path, :nonblock), do: {:error, {:locked, read_owner(path)}}
  defp conflict(path, _timeout), do: {:error, {:lock_timeout, path}}

  defp write_advisory_owner(port, path) do
    owner = current_owner()

    case File.write(path, JSON.encode!(owner), [:raw]) do
      :ok ->
        _ = File.chmod(path, @file_mode)
        {:ok, %__MODULE__{path: path, owner: owner, port: port}}

      {:error, reason} ->
        close_port(port)
        {:error, {:lock_write_failed, path, reason}}
    end
  end

  defp release_advisory(port) do
    if Port.info(port) do
      _ = Port.command(port, "\n")

      receive do
        {^port, {:exit_status, _status}} -> forget_port(port)
      after
        1_000 -> close_port(port)
      end
    else
      forget_port(port)
    end
  rescue
    _error -> close_port(port)
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    forget_port(port)
  rescue
    _error -> forget_port(port)
  end

  # The port stays linked while it holds the lock, so the lock dies with its
  # owner. Once it ended, its exit signal must not reach a caller that traps
  # exits (the session journal does): drop the link and any exit already
  # delivered.
  defp forget_port(port) do
    Process.unlink(port)

    receive do
      {:EXIT, ^port, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  ## Fallback without flock

  defp acquire_fallback(path, wait, reclaim?, opts) do
    owner =
      if Keyword.get(opts, :process_bound, true),
        do: Map.put(current_owner(), @holder_key, holder_id(self())),
        else: current_owner()

    deadline =
      if wait == :nonblock, do: nil, else: System.monotonic_time(:millisecond) + wait

    poll_fallback(path, owner, reclaim?, deadline)
  end

  defp poll_fallback(path, owner, reclaim?, deadline) do
    case try_fallback(path, owner, reclaim?) do
      {:error, {:locked, _owner}} = locked when is_nil(deadline) ->
        locked

      {:error, {:locked, _owner}} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Process.sleep(min(remaining, @fallback_poll_interval))
          poll_fallback(path, owner, reclaim?, deadline)
        else
          {:error, {:lock_timeout, path}}
        end

      result ->
        result
    end
  end

  defp try_fallback(path, owner, reclaim?) do
    case read_owner(path) do
      nil ->
        create_or_reclaim_abandoned(path, owner, reclaim?)

      existing ->
        cond do
          live_owner?(existing) -> {:error, {:locked, existing}}
          reclaim? -> reclaim(path, owner)
          true -> {:error, {:locked, existing}}
        end
    end
  end

  defp create(path, owner) do
    case :file.open(path, [:write, :exclusive, :raw]) do
      {:ok, device} ->
        result = :file.write(device, JSON.encode!(owner))
        _ = :file.sync(device)
        _ = :file.close(device)
        _ = File.chmod(path, @file_mode)

        case result do
          :ok -> {:ok, %__MODULE__{path: path, owner: owner}}
          {:error, reason} -> lock_write_failed(path, reason)
        end

      {:error, :eexist} ->
        {:error, {:locked, read_owner(path)}}

      {:error, reason} ->
        {:error, {:lock_create_failed, path, reason}}
    end
  end

  # A file that exists but holds no owner record is being written by a new
  # holder (`create/2` writes right after the exclusive open), or was left by
  # one that died in between; past a grace period it counts as stale.
  defp create_or_reclaim_abandoned(path, owner, reclaim?) do
    case create(path, owner) do
      {:error, {:locked, nil}} = locked ->
        if reclaim? and abandoned?(path), do: reclaim(path, owner), else: locked

      result ->
        result
    end
  end

  defp abandoned?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        is_nil(read_owner(path)) and
          System.os_time(:second) - mtime > @abandoned_record_grace_seconds

      {:error, _reason} ->
        false
    end
  end

  defp reclaim(path, owner) do
    _ = File.rm(path)
    create(path, owner)
  end

  defp lock_write_failed(path, reason) do
    _ = File.rm(path)
    {:error, {:lock_write_failed, path, reason}}
  end

  defp read_owner(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{} = owner} <- JSON.decode(contents),
         true <- is_binary(owner["pid"]) do
      owner
    else
      _other -> nil
    end
  end

  defp live_owner?(%{"pid" => pid} = owner),
    do: process_matches_owner?(pid, owner) and holder_alive?(owner)

  defp process_matches_owner?(pid, owner) do
    if process_alive?(pid) do
      case owner[@process_identity_key] do
        identity when is_binary(identity) -> identity_matches?(pid, identity)
        _legacy_owner -> legacy_owner_alive?(pid, owner)
      end
    else
      false
    end
  end

  # The OS process is alive and is the one that wrote the record. When that is
  # this VM, a process-bound record also needs its Erlang process.
  defp holder_alive?(%{@holder_key => holder} = owner) when is_binary(holder) do
    if owner["pid"] == System.pid() and owner["node"] == to_string(node()) do
      holder_process_alive?(holder)
    else
      true
    end
  end

  defp holder_alive?(_owner), do: true

  defp holder_id(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  defp holder_process_alive?(holder) do
    holder |> String.to_charlist() |> :erlang.list_to_pid() |> Process.alive?()
  rescue
    ArgumentError -> false
  end

  defp identity_matches?(pid, expected) do
    case process_identity(pid) do
      {:ok, actual} -> actual == expected
      :error -> true
    end
  end

  # Records written without a process identity can still be reclaimed when a
  # fresh PID namespace reuses the BEAM's numeric PID. A lock acquired before
  # this VM started cannot belong to this VM.
  defp legacy_owner_alive?(pid, %{"started_at" => started_at}) when is_integer(started_at) do
    if pid == System.pid(), do: started_at >= beam_started_at(), else: true
  end

  defp legacy_owner_alive?(_pid, _owner), do: true

  defp beam_started_at do
    {uptime_ms, _since_last_call} = :erlang.statistics(:wall_clock)
    System.system_time(:second) - div(uptime_ms, 1_000)
  end

  defp process_identity(pid) do
    with {:ok, boot_id} <- File.read("/proc/sys/kernel/random/boot_id"),
         {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         {:ok, start_ticks} <- process_start_ticks(stat) do
      {:ok, "#{String.trim(boot_id)}:#{start_ticks}"}
    else
      _error -> :error
    end
  end

  defp process_start_ticks(stat) do
    case Regex.run(~r/^\d+ \(.*\) (.*)$/s, stat, capture: :all_but_first) do
      [fields] ->
        case fields |> String.split() |> Enum.at(19) do
          nil -> :error
          start_ticks -> {:ok, start_ticks}
        end

      _other ->
        :error
    end
  end

  defp process_alive?(pid) do
    if File.dir?("/proc") do
      File.dir?("/proc/#{pid}")
    else
      kill_zero(pid)
    end
  end

  defp kill_zero(pid) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      _other -> false
    end
  rescue
    _error -> true
  end
end
