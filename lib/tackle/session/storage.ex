defmodule Tackle.Session.Storage do
  @moduledoc """
  Local storage layout for durable sessions and the one-writer ownership lock.

  The initial layout is rooted under `TACKLE_HOME`:

      $TACKLE_HOME/
      └── sessions/
          ├── catalog/       derived global data
          ├── trash/         recoverable deletions
          └── <session-id>/
              ├── session.dlog
              ├── summary.etf
              ├── checkpoint.etf
              └── recovery/

  The journal is the only required durable file. Summaries, checkpoints, and
  catalog data are disposable projections that can always be removed and
  rebuilt. Directories are private to the current user and files are created
  with restrictive permissions because internal repair and ordinary chunk
  decoding can decode ETF terms.
  """

  alias Tackle.Session.Storage.Lock

  @journal_file "session.dlog"
  @summary_file "summary.etf"
  @checkpoint_file "checkpoint.etf"
  @recovery_dir "recovery"
  @sessions_dir "sessions"
  @trash_dir "trash"
  @catalog_dir "catalog"

  @dir_mode 0o700
  @file_mode 0o600
  @session_id ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/

  @type root_opts :: [{:home, String.t()} | {:env, map()}]

  @doc "Returns the sessions root under `TACKLE_HOME`."
  @spec sessions_root(keyword()) :: {:ok, String.t()} | {:error, term()}
  def sessions_root(opts \\ []) do
    with {:ok, home} <- home(opts) do
      {:ok, Path.join([home, @sessions_dir])}
    end
  end

  @doc "Returns `$TACKLE_HOME/sessions/trash`."
  @spec trash_root(keyword()) :: {:ok, String.t()} | {:error, term()}
  def trash_root(opts \\ []) do
    with {:ok, root} <- sessions_root(opts), do: {:ok, Path.join(root, @trash_dir)}
  end

  @doc "Returns `$TACKLE_HOME/sessions/catalog`."
  @spec catalog_root(keyword()) :: {:ok, String.t()} | {:error, term()}
  def catalog_root(opts \\ []) do
    with {:ok, root} <- sessions_root(opts), do: {:ok, Path.join(root, @catalog_dir)}
  end

  @doc "Returns the private directory for one session."
  @spec session_dir(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def session_dir(session_id, opts \\ []) do
    with :ok <- validate_session_id(session_id),
         {:ok, root} <- sessions_root(opts) do
      {:ok, Path.join(root, session_id)}
    end
  end

  @doc "Returns the canonical journal path for one session."
  @spec journal_path(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def journal_path(session_id, opts \\ []) do
    with {:ok, dir} <- session_dir(session_id, opts), do: {:ok, Path.join(dir, @journal_file)}
  end

  @doc "Returns the derived summary sidecar path for one session."
  @spec summary_path(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def summary_path(session_id, opts \\ []) do
    with {:ok, dir} <- session_dir(session_id, opts), do: {:ok, Path.join(dir, @summary_file)}
  end

  @doc "Returns the optional replay checkpoint path for one session."
  @spec checkpoint_path(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def checkpoint_path(session_id, opts \\ []) do
    with {:ok, dir} <- session_dir(session_id, opts),
         do: {:ok, Path.join(dir, @checkpoint_file)}
  end

  @doc "Returns the recovery-artifact directory for one session."
  @spec recovery_dir(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def recovery_dir(session_id, opts \\ []) do
    with {:ok, dir} <- session_dir(session_id, opts), do: {:ok, Path.join(dir, @recovery_dir)}
  end

  @doc """
  Validates a session id used as an opaque path component.

  Only conservative identifier characters are accepted so a session id can
  never traverse outside the storage root.
  """
  @spec validate_session_id(term()) :: :ok | {:error, term()}
  def validate_session_id(session_id) when is_binary(session_id) do
    if Regex.match?(@session_id, session_id) and session_id not in [".", ".."] do
      :ok
    else
      {:error, {:invalid_session_id, session_id}}
    end
  end

  def validate_session_id(session_id), do: {:error, {:invalid_session_id, session_id}}

  @doc "Creates the private session directory if needed."
  @spec ensure_session_dir(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure_session_dir(session_id, opts \\ []) do
    with {:ok, dir} <- session_dir(session_id, opts) do
      case ensure_private_dir(dir) do
        :ok -> {:ok, dir}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Creates a private directory (and parents) with restrictive permissions."
  @spec ensure_private_dir(String.t()) :: :ok | {:error, term()}
  def ensure_private_dir(path) do
    with :ok <- mkdir_p(path) do
      chmod(path, @dir_mode)
    end
  end

  @doc """
  Acquires the exclusive writable ownership of one session directory.

  The lock is a small file recording the owning operating-system process. A
  live owner is rejected with `{:error, :session_in_use}`; a stale lock left by
  a dead process is reclaimed. Cross-BEAM distributed leases are not promised.
  """
  @spec acquire_lock(String.t(), keyword()) :: {:ok, Lock.t()} | {:error, term()}
  def acquire_lock(session_id, opts \\ []) do
    with {:ok, dir} <- ensure_session_dir(session_id, opts) do
      Lock.acquire(dir, opts)
    end
  end

  @doc "Releases a previously acquired ownership lock."
  @spec release_lock(Lock.t()) :: :ok
  def release_lock(%Lock{} = lock), do: Lock.release(lock)

  @doc "Lists session ids present in the storage root."
  @spec list_session_ids(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_session_ids(opts \\ []) do
    with {:ok, root} <- sessions_root(opts) do
      list_session_ids_in(root)
    end
  end

  defp list_session_ids_in(root) do
    case File.ls(root) do
      {:ok, entries} ->
        ids =
          entries
          |> Enum.reject(&(&1 in [@trash_dir, @catalog_dir]))
          |> Enum.filter(&(validate_session_id(&1) == :ok and File.dir?(Path.join(root, &1))))
          |> Enum.sort()

        {:ok, ids}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:storage_unavailable, root, reason}}
    end
  end

  @doc """
  Moves a complete session directory into `sessions/trash/`.

  Renaming first prevents a partial multi-file deletion from leaving a session
  that still appears live. The operation is refused for an active session.
  """
  @spec trash_session(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def trash_session(session_id, opts \\ []) do
    with {:ok, dir} <- session_dir(session_id, opts),
         {:ok, trash} <- trash_root(opts),
         :ok <- ensure_private_dir(trash) do
      destination = Path.join(trash, "#{session_id}-#{System.system_time(:millisecond)}")

      case File.rename(dir, destination) do
        :ok -> {:ok, destination}
        {:error, reason} -> {:error, {:trash_failed, session_id, reason}}
      end
    end
  end

  @doc """
  Atomically publishes a temporary session directory under its final name.

  The temporary directory must be a sibling on the same filesystem so the
  rename is atomic.
  """
  @spec publish_directory(String.t(), String.t()) :: :ok | {:error, term()}
  def publish_directory(temp_dir, final_dir) do
    case File.rename(temp_dir, final_dir) do
      :ok ->
        :ok

      {:error, :eexist} ->
        {:error, {:session_exists, final_dir}}

      {:error, reason} ->
        {:error, {:publish_failed, temp_dir, final_dir, reason}}
    end
  end

  @doc """
  Writes a file atomically with restrictive permissions.

  The content is written to a temporary sibling, synced, and renamed into
  place. Derived sidecars use this so readers only ever observe a complete file.
  """
  @spec atomic_write(String.t(), iodata()) :: :ok | {:error, term()}
  def atomic_write(path, content) do
    temp = path <> ".tmp-#{System.unique_integer([:positive])}"
    dir = Path.dirname(path)

    with :ok <- ensure_private_dir(dir),
         :ok <- write_file(temp, content),
         :ok <- sync_file(temp),
         :ok <- rename(temp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temp)
        {:error, reason}
    end
  end

  @doc "Creates a unique temporary session directory for portable publication."
  @spec temporary_session_dir(keyword()) :: {:ok, String.t()} | {:error, term()}
  def temporary_session_dir(opts \\ []) do
    with {:ok, root} <- sessions_root(opts),
         :ok <- ensure_private_dir(root) do
      suffix = ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
      path = Path.join(root, suffix)

      case ensure_private_dir(path) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Copies a file into a session's recovery directory for later diagnosis."
  @spec preserve_for_recovery(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def preserve_for_recovery(session_id, source_path, opts \\ []) do
    with {:ok, dir} <- recovery_dir(session_id, opts),
         :ok <- ensure_private_dir(dir) do
      stamp = System.system_time(:microsecond)
      destination = Path.join(dir, "#{Path.basename(source_path)}.#{stamp}.bak")

      case File.cp(source_path, destination) do
        :ok ->
          _ = File.chmod(destination, @file_mode)
          {:ok, destination}

        {:error, reason} ->
          {:error, {:recovery_copy_failed, source_path, reason}}
      end
    end
  end

  @doc "Returns the journal file mode used for newly created journals."
  @spec file_mode() :: non_neg_integer()
  def file_mode, do: @file_mode

  defp home(opts) do
    case Keyword.fetch(opts, :home) do
      {:ok, home} when is_binary(home) -> {:ok, Path.expand(home)}
      {:ok, other} -> {:error, {:invalid_home, other}}
      :error -> Tackle.Paths.home(Keyword.take(opts, [:env, :user_home]))
    end
  end

  defp mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, path, reason}}
    end
  end

  defp chmod(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, reason} -> {:error, {:chmod_failed, path, reason}}
    end
  end

  defp write_file(path, content) do
    case File.write(path, content, [:raw]) do
      :ok -> chmod(path, @file_mode)
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  defp sync_file(path) do
    case :file.open(path, [:read, :write, :raw]) do
      {:ok, device} ->
        result = :file.sync(device)
        _ = :file.close(device)
        result

      {:error, reason} ->
        {:error, {:sync_open_failed, path, reason}}
    end
  end

  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rename_failed, from, to, reason}}
    end
  end
end
