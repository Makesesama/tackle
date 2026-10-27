defmodule Tackle.Session.Storage do
  @moduledoc """
  Local storage layout for durable sessions and the one-writer ownership lock.

  The layout is rooted under `TACKLE_HOME`:

      $TACKLE_HOME/
      └── sessions/
          ├── catalog/            compression.marker: the last compression pass
          ├── trash/              deleted session directories, <session-id>-<ms>
          ├── archive/            archived sessions, mirroring the layout below
          ├── <session-id>/       legacy sessions without a project
          └── --home-user-project--/
              └── <session-id>/
                  ├── session.dlog           the journal (session.dlog.zst once idle)
                  ├── session.dlog.read-*    temporary decompressed copies
                  ├── summary.etf            derived summary sidecar
                  ├── writer.lock            the one-writer lock
                  ├── journal-failure.json   report of a failed journal owner
                  └── recovery/              copies kept before repair (*.bak[.zst])

  The journal is the only required durable file. The summary sidecar and the
  catalog, an in-memory index rebuilt at startup, are disposable projections
  that can always be removed and rebuilt. Replay checkpoints are planned, not
  written.

  A journal idle for a while is stored compressed as `session.dlog.zst` (see
  `Tackle.Session.Compression`); a reader replays it from a temporary
  decompressed copy beside it, and a writer restores the plain journal first
  (`Tackle.Session.CompressedFile`). When both forms exist, the plain journal
  is authoritative.

  Archiving moves a complete session directory under `archive/`, keeping its
  project directory, so the session leaves the active listing but stays
  readable. Pass `archived: true` to any path function to address the archived
  copy instead of the active one.

  The directories under `sessions/` (including `sessions/` itself and the
  project directories) are private to the current user (`0700`), and the
  journal, sidecars, lock, and failure files are created `0600`, because the
  journal holds whole conversations and internal repair and ordinary chunk
  decoding can decode ETF terms. Directories and journals created by earlier
  versions are made private when a session is next opened for writing.
  """

  alias Tackle.FileLock
  alias Tackle.Session.Storage.Lock

  @journal_file "session.dlog"
  @compressed_suffix ".zst"
  @summary_file "summary.etf"
  @recovery_dir "recovery"
  @sessions_dir "sessions"
  @trash_dir "trash"
  @archive_dir "archive"
  @catalog_dir "catalog"

  @dir_mode 0o700
  @file_mode 0o600
  @session_id ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/

  @type root_opts :: [{:home, String.t()} | {:env, map()}]

  @typedoc """
  Location options shared by the path functions: `:home`/`:env` select
  `TACKLE_HOME`, `:cwd` or `:project_key` select the project directory, and
  `archived: true` selects the archive instead of the active sessions.
  """
  @type location_opts :: keyword()

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

  @doc "Returns `$TACKLE_HOME/sessions/archive`."
  @spec archive_root(keyword()) :: {:ok, String.t()} | {:error, term()}
  def archive_root(opts \\ []) do
    with {:ok, root} <- sessions_root(opts), do: {:ok, Path.join(root, @archive_dir)}
  end

  @doc "Returns `$TACKLE_HOME/sessions/catalog`."
  @spec catalog_root(keyword()) :: {:ok, String.t()} | {:error, term()}
  def catalog_root(opts \\ []) do
    with {:ok, root} <- sessions_root(opts), do: {:ok, Path.join(root, @catalog_dir)}
  end

  @doc "Returns the private directory for one session. `:cwd` selects its project."
  @spec session_dir(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def session_dir(session_id, opts \\ []) do
    with :ok <- validate_session_id(session_id),
         {:ok, root} <- project_root(opts) do
      {:ok, Path.join(root, session_id)}
    end
  end

  @doc "Returns the canonical journal path for one session."
  @spec journal_path(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def journal_path(session_id, opts \\ []) do
    with {:ok, dir} <- session_dir(session_id, opts), do: {:ok, Path.join(dir, @journal_file)}
  end

  @doc "Returns the compressed form of a journal path: `session.dlog.zst`."
  @spec compressed_path(String.t()) :: String.t()
  def compressed_path(journal_path), do: journal_path <> @compressed_suffix

  @doc """
  Whether a session has a journal, plain or compressed, at the selected
  location.
  """
  @spec journal_exists?(String.t(), keyword()) :: boolean()
  def journal_exists?(session_id, opts \\ []) do
    case journal_path(session_id, opts) do
      {:ok, path} -> File.regular?(path) or File.regular?(compressed_path(path))
      {:error, _reason} -> false
    end
  end

  @doc "Returns the derived summary sidecar path for one session."
  @spec summary_path(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def summary_path(session_id, opts \\ []) do
    with {:ok, dir} <- session_dir(session_id, opts), do: {:ok, Path.join(dir, @summary_file)}
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

  @doc """
  Creates the private session directory if needed.

  Every directory from `sessions/` down to the session's, existing or not, is
  made private.
  """
  @spec ensure_session_dir(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure_session_dir(session_id, opts \\ []) do
    with {:ok, dir} <- session_dir(session_id, opts),
         {:ok, root} <- sessions_root(opts),
         :ok <- ensure_private_path(root, dir) do
      {:ok, dir}
    end
  end

  # `dir` lies below `root`; `root` and each directory between them are made
  # private, so a project directory or `sessions/` created by an earlier
  # version is tightened too.
  defp ensure_private_path(root, dir) do
    dir
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.scan(root, &Path.join(&2, &1))
    |> then(&[root | &1])
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case ensure_private_dir(path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Creates a private directory with restrictive permissions.

  The directory and every parent this call creates are `0700`; parents that
  already existed are left as they are.
  """
  @spec ensure_private_dir(String.t()) :: :ok | {:error, term()}
  def ensure_private_dir(path) do
    path = Path.expand(path)
    created = missing_dirs(path, [])

    with :ok <- mkdir_p(path), do: make_private(Enum.uniq([path | created]))
  end

  defp make_private(dirs) do
    Enum.reduce_while(dirs, :ok, fn dir, :ok ->
      case chmod(dir, @dir_mode) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # The directories `mkdir_p` is about to create, outermost first.
  defp missing_dirs(path, acc) do
    if File.exists?(path) or Path.dirname(path) == path,
      do: acc,
      else: missing_dirs(Path.dirname(path), [path | acc])
  end

  @doc """
  Acquires the exclusive writable ownership of one session directory.

  On systems with `flock`, the lock is held by the owning operating-system
  process and remains reliable across PID namespaces. Other systems use the
  recorded process identity as a best-effort fallback. A live owner is rejected
  with `{:error, :session_in_use}`; stale fallback locks are reclaimed.
  Cross-node distributed leases are not promised.
  """
  @spec acquire_lock(String.t(), keyword()) :: {:ok, Lock.t()} | {:error, term()}
  def acquire_lock(session_id, opts \\ []) do
    with {:ok, dir} <- ensure_session_dir(session_id, opts) do
      acquire_waiting(dir)
    end
  end

  # Background maintenance in this OS process (compressing an idle journal)
  # holds a session's lock only for a moment, so a conflict with our own OS
  # process is waited out briefly; other owners are reported at once.
  @lock_wait_attempts 20
  @lock_wait_interval 100

  defp acquire_waiting(dir, attempt \\ 1) do
    case Lock.acquire(dir) do
      {:error, {:session_in_use, %{"pid" => pid}}} = busy ->
        if pid == System.pid() and attempt < @lock_wait_attempts do
          Process.sleep(@lock_wait_interval)
          acquire_waiting(dir, attempt + 1)
        else
          busy
        end

      result ->
        result
    end
  end

  @doc """
  Acquires the writer lock of a session whose journal must already exist.

  Unlike `acquire_lock/2`, it never creates the session directory, and it
  checks again under the lock that the journal, plain or compressed, exists.
  A session moved to the archive or the trash (which happens under its lock)
  before the lock was taken is therefore reported as
  `{:error, {:session_not_found, session_id}}` rather than recreated empty.
  """
  @spec acquire_existing_lock(String.t(), keyword()) :: {:ok, Lock.t()} | {:error, term()}
  def acquire_existing_lock(session_id, opts \\ []) do
    with {:ok, dir} <- session_dir(session_id, opts),
         {:ok, root} <- sessions_root(opts),
         :ok <- ensure_journal(session_id, dir),
         {:ok, lock} <- acquire_in_existing(session_id, dir) do
      # Under the lock the directory can no longer move, so tightening it
      # cannot recreate it.
      with :ok <- ensure_journal(session_id, dir),
           :ok <- ensure_private_path(root, dir) do
        {:ok, lock}
      else
        {:error, _reason} = error ->
          release_lock(lock)
          error
      end
    end
  end

  # The directory can vanish while the lock is awaited; the lock file then
  # cannot be opened.
  defp acquire_in_existing(session_id, dir) do
    case acquire_waiting(dir) do
      {:ok, lock} ->
        {:ok, lock}

      {:error, _reason} = error ->
        if File.dir?(dir), do: error, else: {:error, {:session_not_found, session_id}}
    end
  end

  @doc "Releases a previously acquired ownership lock."
  @spec release_lock(Lock.t()) :: :ok
  def release_lock(%FileLock{} = lock), do: Lock.release(lock)

  @doc "Lists session ids in the selected project (or legacy root without `:cwd`)."
  @spec list_session_ids(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_session_ids(opts \\ []) do
    with {:ok, root} <- project_root(opts) do
      list_session_ids_in(root)
    end
  end

  @doc """
  Lists legacy and project session locations for catalog rebuilds.

  Active sessions come first, then archived ones; an archived location carries
  `archived: true`, so passing it back to a path function addresses the
  archived copy.
  """
  @spec list_session_locations(keyword()) :: {:ok, [{String.t(), keyword()}]} | {:error, term()}
  def list_session_locations(opts \\ []) do
    location_opts = Keyword.drop(opts, [:cwd, :project_key, :archived])

    with {:ok, root} <- sessions_root(opts),
         {:ok, archive} <- archive_root(opts),
         {:ok, active} <- list_locations_in(root, location_opts),
         {:ok, archived} <-
           list_locations_in(archive, Keyword.put(location_opts, :archived, true)) do
      {:ok, active ++ archived}
    end
  end

  defp list_locations_in(root, location_opts) do
    with {:ok, legacy} <- list_session_ids_in(root),
         {:ok, entries} <- list_entries(root) do
      Enum.reduce_while(entries, {:ok, Enum.map(legacy, &{&1, location_opts})}, fn entry,
                                                                                   {:ok, acc} ->
        append_project_sessions(root, entry, location_opts, acc)
      end)
    end
  end

  defp append_project_sessions(root, entry, location_opts, acc) do
    if String.starts_with?(entry, "--") and String.ends_with?(entry, "--") and
         File.dir?(Path.join(root, entry)) do
      location = Keyword.put(location_opts, :project_key, entry)

      case list_session_ids(location) do
        {:ok, ids} -> {:cont, {:ok, acc ++ Enum.map(ids, &{&1, location})}}
        error -> {:halt, error}
      end
    else
      {:cont, {:ok, acc}}
    end
  end

  defp list_entries(root) do
    case File.ls(root) do
      {:ok, entries} -> {:ok, entries}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, {:storage_unavailable, root, reason}}
    end
  end

  defp list_session_ids_in(root) do
    case list_entries(root) do
      {:ok, entries} ->
        ids =
          entries
          |> Enum.reject(&(&1 in [@trash_dir, @catalog_dir, @archive_dir]))
          |> Enum.filter(&(validate_session_id(&1) == :ok and File.dir?(Path.join(root, &1))))
          |> Enum.sort()

        {:ok, ids}

      error ->
        error
    end
  end

  @doc """
  Moves a complete session directory into `sessions/trash/`.

  Renaming first prevents a partial multi-file deletion from leaving a session
  that still appears live. The move takes the session's writer lock, so a
  session owned by a live process, or being compressed, is not moved from
  under it.
  """
  @spec trash_session(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def trash_session(session_id, opts \\ []) do
    with {:ok, dir} <- session_dir(session_id, opts),
         :ok <- ensure_dir(session_id, dir),
         {:ok, trash} <- trash_root(opts),
         :ok <- ensure_private_dir(trash),
         {:ok, lock} <- acquire_waiting(dir) do
      destination = Path.join(trash, "#{session_id}-#{System.system_time(:millisecond)}")

      case File.rename(dir, destination) do
        :ok ->
          release_lock(%{lock | path: Lock.path(destination)})
          {:ok, destination}

        {:error, reason} ->
          release_lock(lock)
          {:error, {:trash_failed, session_id, reason}}
      end
    end
  end

  defp ensure_dir(session_id, dir) do
    if File.dir?(dir), do: :ok, else: {:error, {:trash_failed, session_id, :enoent}}
  end

  @doc """
  Moves an inactive session between two locations, such as into the archive.

  `from` and `to` are location options (see `t:location_opts/0`). The session
  must have a journal at `from` and nothing at `to`. The move takes the
  session's writer lock first, so a session owned by any live process,
  including another Tackle instance, is refused with
  `{:error, {:session_in_use, owner}}`. Returns the new session directory.
  """
  @spec move_session(String.t(), location_opts(), location_opts()) ::
          {:ok, String.t()} | {:error, term()}
  def move_session(session_id, from, to) do
    with {:ok, source} <- session_dir(session_id, from),
         {:ok, destination} <- session_dir(session_id, to),
         :ok <- ensure_journal(session_id, source),
         :ok <- ensure_private_dir(Path.dirname(destination)),
         {:ok, lock} <- acquire_waiting(source) do
      # Checked under the lock, so a concurrent move of this session cannot
      # pass the check before this one renames.
      with :ok <- ensure_absent(session_id, destination),
           :ok <- rename_session(session_id, source, destination) do
        # The lock file moved with the directory; release it there.
        release_lock(%{lock | path: Lock.path(destination)})
        {:ok, destination}
      else
        {:error, reason} ->
          release_lock(lock)
          {:error, reason}
      end
    end
  end

  defp rename_session(session_id, source, destination) do
    case File.rename(source, destination) do
      :ok -> :ok
      {:error, reason} -> {:error, {:move_failed, session_id, reason}}
    end
  end

  defp ensure_journal(session_id, dir) do
    path = Path.join(dir, @journal_file)

    if File.regular?(path) or File.regular?(compressed_path(path)),
      do: :ok,
      else: {:error, {:session_not_found, session_id}}
  end

  # A rename over an empty directory succeeds on POSIX, so check explicitly.
  defp ensure_absent(session_id, dir) do
    if File.exists?(dir), do: {:error, {:session_exists, session_id}}, else: :ok
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
  The directory is not synced (the BEAM cannot open one); journaling
  filesystems persist the rename before later metadata changes.

  Missing parent directories are created unless `create_dir: false` is given;
  background work passes it so a write never recreates a session directory
  that was moved or deleted meanwhile.
  """
  @spec atomic_write(String.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def atomic_write(path, content, opts \\ []) do
    temp = path <> ".tmp-#{System.unique_integer([:positive])}"
    dir = Path.dirname(path)

    with :ok <- if(Keyword.get(opts, :create_dir, true), do: ensure_private_dir(dir), else: :ok),
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
    with {:ok, root} <- project_root(opts),
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

  @doc "Returns the mode of journals and the other files in a session directory."
  @spec file_mode() :: non_neg_integer()
  def file_mode, do: @file_mode

  # The enclosing dashes distinguish project directories from legacy session ids.
  defp project_root(opts) do
    with {:ok, root} <- location_root(opts) do
      project_root(root, Keyword.get(opts, :cwd), Keyword.get(opts, :project_key))
    end
  end

  defp location_root(opts) do
    case Keyword.get(opts, :archived, false) do
      true -> archive_root(opts)
      false -> sessions_root(opts)
      other -> {:error, {:invalid_archived, other}}
    end
  end

  defp project_root(root, cwd, _key) when is_binary(cwd),
    do: {:ok, Path.join(root, Tackle.Paths.project_key(cwd))}

  defp project_root(root, nil, key) when is_binary(key) do
    if String.starts_with?(key, "--") and String.ends_with?(key, "--") and
         not String.contains?(key, "/") and key not in [".", ".."],
       do: {:ok, Path.join(root, key)},
       else: {:error, {:invalid_project_key, key}}
  end

  defp project_root(root, nil, nil), do: {:ok, root}
  defp project_root(_root, invalid, _key), do: {:error, {:invalid_cwd, invalid}}

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
