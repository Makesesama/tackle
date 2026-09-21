defmodule Tackle.Session.Storage.Lock do
  @moduledoc """
  Best-effort exclusive writable ownership for one session directory.

  `:disk_log` serializes callers that use the same open log on one node, but it
  does not prevent the same file from being opened under another name, in
  another BEAM, or on another node. On systems with `flock`, this lock holds an
  operating-system advisory lock on `writer.lock`, including across PID
  namespaces. Other systems fall back to a process-identity record.

  Stale fallback locks left behind by dead processes are reclaimed. Distributed
  leases and cross-node fencing are not promised; when ownership is uncertain
  Tackle fails rather than opening with automatic repair.
  """

  @lock_file "writer.lock"

  @enforce_keys [:path, :owner]
  defstruct [:path, :owner, :port]

  @type owner :: %{
          required(String.t()) => String.t() | integer()
        }

  @type t :: %__MODULE__{path: String.t(), owner: owner(), port: port() | nil}

  @process_identity_key "process_identity"
  @lock_ready "TACKLE_WRITER_LOCK_READY"
  @lock_conflict_exit 75
  @lock_start_timeout 5_000

  @doc """
  Acquires the writable ownership lock beneath a session directory.

  Returns `{:error, {:session_in_use, owner}}` when another live process owns
  the session. Use `force: true` only when the caller has independently
  established exclusive ownership.
  """
  @spec acquire(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def acquire(dir, opts \\ []) do
    path = Path.join(dir, @lock_file)

    case advisory_lock_executables() do
      {:ok, flock, shell} -> acquire_advisory(path, flock, shell)
      :error -> acquire_pid_lock(path, Keyword.get(opts, :force, false))
    end
  end

  @doc "Releases a lock previously returned by `acquire/2`."
  @spec release(t()) :: :ok
  def release(%__MODULE__{port: port}) when is_port(port) do
    _ = release_advisory(port)
    :ok
  end

  def release(%__MODULE__{path: path}) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @doc "Returns the lock file path inside a session directory."
  @spec path(String.t()) :: String.t()
  def path(dir), do: Path.join(dir, @lock_file)

  @doc "Returns the current process ownership description."
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

  defp acquire_advisory(path, flock, shell) do
    port =
      Port.open(
        {:spawn_executable, flock},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: [
            "--exclusive",
            "--nonblock",
            "--conflict-exit-code",
            Integer.to_string(@lock_conflict_exit),
            path,
            shell,
            "-c",
            "printf '#{@lock_ready}\\n'; IFS= read -r _"
          ]
        ]
      )

    await_advisory_lock(port, path, "")
  rescue
    error -> {:error, {:lock_start_failed, path, Exception.message(error)}}
  end

  defp await_advisory_lock(port, path, output) do
    receive do
      {^port, {:data, data}} ->
        output = output <> data

        if String.contains?(output, @lock_ready) do
          write_advisory_owner(port, path)
        else
          await_advisory_lock(port, path, output)
        end

      {^port, {:exit_status, @lock_conflict_exit}} ->
        session_in_use(path)

      {^port, {:exit_status, status}} ->
        {:error, {:lock_start_failed, path, status, String.trim(output)}}
    after
      @lock_start_timeout ->
        close_port(port)
        {:error, {:lock_start_timeout, path}}
    end
  end

  defp write_advisory_owner(port, path) do
    owner = current_owner()

    case File.write(path, JSON.encode!(owner), [:raw]) do
      :ok ->
        _ = File.chmod(path, 0o600)
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
        {^port, {:exit_status, _status}} -> :ok
      after
        1_000 -> close_port(port)
      end
    end
  rescue
    _error -> close_port(port)
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _error -> :ok
  end

  defp session_in_use(path) do
    case read_owner(path) do
      {:ok, owner} -> {:error, {:session_in_use, owner}}
      :error -> {:error, :session_in_use}
    end
  end

  defp advisory_lock_executables do
    with flock when is_binary(flock) <- System.find_executable("flock"),
         shell when is_binary(shell) <- System.find_executable("sh") do
      {:ok, flock, shell}
    else
      _missing -> :error
    end
  end

  defp acquire_pid_lock(path, force?) do
    case read_owner(path) do
      {:ok, owner} ->
        cond do
          force? -> reclaim(path)
          live_owner?(owner) -> {:error, {:session_in_use, owner}}
          true -> reclaim(path)
        end

      :error ->
        create(path)
    end
  end

  defp create(path) do
    owner = current_owner()

    case :file.open(path, [:write, :exclusive, :raw]) do
      {:ok, device} ->
        result = :file.write(device, JSON.encode!(owner))
        _ = :file.sync(device)
        _ = :file.close(device)
        _ = File.chmod(path, 0o600)

        case result do
          :ok -> {:ok, %__MODULE__{path: path, owner: owner}}
          {:error, reason} -> lock_write_failed(path, reason)
        end

      {:error, :eexist} ->
        case read_owner(path) do
          {:ok, owner} -> {:error, {:session_in_use, owner}}
          :error -> {:error, :session_in_use}
        end

      {:error, reason} ->
        {:error, {:lock_create_failed, path, reason}}
    end
  end

  defp reclaim(path) do
    _ = File.rm(path)
    create(path)
  end

  defp lock_write_failed(path, reason) do
    _ = File.rm(path)
    {:error, {:lock_write_failed, path, reason}}
  end

  defp read_owner(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{} = owner} <- JSON.decode(contents),
         true <- is_binary(owner["pid"]) do
      {:ok, owner}
    else
      _other -> :error
    end
  end

  defp live_owner?(owner) do
    case owner["pid"] do
      pid when is_binary(pid) -> process_matches_owner?(pid, owner)
      _pid -> false
    end
  end

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

  defp identity_matches?(pid, expected) do
    case process_identity(pid) do
      {:ok, actual} -> actual == expected
      :error -> true
    end
  end

  # Locks written before process identities were added can still be reclaimed
  # when a fresh PID namespace reuses the BEAM's numeric PID. A lock acquired
  # before this VM started cannot belong to this VM.
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
