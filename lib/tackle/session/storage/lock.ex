defmodule Tackle.Session.Storage.Lock do
  @moduledoc """
  Best-effort exclusive writable ownership for one session directory.

  `:disk_log` serializes callers that use the same open log on one node, but it
  does not prevent the same file from being opened under another name, in
  another BEAM, or on another node. This lock is the initial storage ownership
  guard: it records the owning operating-system process in `writer.lock` and
  rejects a live owner with `:session_in_use`.

  A stale lock left behind by a dead process is reclaimed. Distributed leases
  and cross-node fencing are not promised; when ownership is uncertain Tackle
  fails rather than opening with automatic repair.
  """

  @lock_file "writer.lock"

  @enforce_keys [:path, :owner]
  defstruct [:path, :owner]

  @type owner :: %{
          required(String.t()) => String.t() | integer()
        }

  @type t :: %__MODULE__{path: String.t(), owner: owner()}

  @doc """
  Acquires the writable ownership lock beneath a session directory.

  Returns `{:error, {:session_in_use, owner}}` when another live process owns
  the session. Use `force: true` only when the caller has independently
  established exclusive ownership.
  """
  @spec acquire(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def acquire(dir, opts \\ []) do
    path = Path.join(dir, @lock_file)
    force? = Keyword.get(opts, :force, false)

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

  @doc "Releases a lock previously returned by `acquire/2`."
  @spec release(t()) :: :ok
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
    %{
      "pid" => System.pid(),
      "node" => to_string(node()),
      "started_at" => System.system_time(:second)
    }
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
      pid when is_binary(pid) -> process_alive?(pid)
      _pid -> false
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
