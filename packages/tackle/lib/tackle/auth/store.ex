defmodule Tackle.Auth.Store do
  @moduledoc """
  Supervised, file-backed storage for opaque provider credentials.

  The file is plaintext JSON protected by directory mode `0700` and file mode
  `0600`; it is not encrypted. Mutations are serialized within one Tackle
  application and persisted by replacing `auth.json` atomically, so readers do
  not observe partial JSON. Power-loss durability after the rename, cross-VM
  locking, and operating-system keyrings are intentionally outside this store.
  """

  use GenServer

  @behaviour Tackle.Lib.CredentialStore

  @version 1
  @directory_mode 0o700
  @file_mode 0o600

  @type state :: %{path: Path.t(), providers: %{optional(String.t()) => map()}}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    genserver_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  @impl Tackle.Lib.CredentialStore
  def fetch(reference, namespace), do: GenServer.call(reference, {:fetch, namespace})

  @impl Tackle.Lib.CredentialStore
  def put(reference, namespace, credentials),
    do: GenServer.call(reference, {:put, namespace, credentials})

  @impl Tackle.Lib.CredentialStore
  def delete(reference, namespace), do: GenServer.call(reference, {:delete, namespace})

  @doc false
  @spec status(GenServer.server(), String.t()) :: :stored | :missing | {:error, term()}
  def status(reference, namespace), do: GenServer.call(reference, {:status, namespace})

  @impl true
  def init(opts) do
    with {:ok, path} <- fetch_path(opts),
         {:ok, providers} <- load(path) do
      {:ok, %{path: Path.expand(path), providers: providers}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:fetch, namespace}, _from, state) do
    reply =
      with :ok <- validate_namespace(namespace) do
        Map.fetch(state.providers, namespace)
      end

    {:reply, reply, state}
  end

  def handle_call({:status, namespace}, _from, state) do
    reply =
      with :ok <- validate_namespace(namespace) do
        if Map.has_key?(state.providers, namespace), do: :stored, else: :missing
      end

    {:reply, reply, state}
  end

  def handle_call({:put, namespace, credentials}, _from, state) do
    with :ok <- validate_namespace(namespace),
         {:ok, credentials} <- normalize_credentials(credentials),
         providers = Map.put(state.providers, namespace, credentials),
         :ok <- persist(state.path, providers) do
      {:reply, :ok, %{state | providers: providers}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, namespace}, _from, state) do
    case validate_namespace(namespace) do
      :ok -> delete_namespace(namespace, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp delete_namespace(namespace, state) do
    if Map.has_key?(state.providers, namespace) do
      providers = Map.delete(state.providers, namespace)
      delete_reply(persist(state.path, providers), providers, state)
    else
      {:reply, :ok, state}
    end
  end

  defp delete_reply(:ok, providers, state),
    do: {:reply, :ok, %{state | providers: providers}}

  defp delete_reply({:error, reason}, _providers, state),
    do: {:reply, {:error, reason}, state}

  defp fetch_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :auth_path_required}
    end
  end

  defp load(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        with :ok <- secure_existing_file(path), do: read_envelope(path)

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:unsafe_auth_file, path, :symlink}}

      {:ok, %File.Stat{}} ->
        {:error, {:unsafe_auth_file, path, :not_regular}}

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:auth_file_unreadable, path, reason}}
    end
  end

  defp secure_existing_file(path) do
    with :ok <- ensure_private_directory(Path.dirname(path)),
         :ok <- safe_auth_target(path),
         :ok <- File.chmod(path, @file_mode) do
      :ok
    else
      {:error, reason} when is_atom(reason) ->
        {:error, {:auth_file_permissions_failed, path, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_envelope(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, envelope} <- decode_envelope(path, contents) do
      {:ok, envelope["providers"]}
    else
      {:error, reason} when reason in [:eacces, :eperm] ->
        {:error, {:auth_file_unreadable, path, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_envelope(path, contents) do
    case JSON.decode(contents) do
      {:ok, %{"version" => @version, "providers" => providers} = envelope}
      when is_map(providers) ->
        if valid_providers?(providers) do
          {:ok, envelope}
        else
          {:error, {:invalid_auth_file, path, :invalid_providers}}
        end

      {:ok, %{"version" => version}} when version != @version ->
        {:error, {:unsupported_auth_version, path, @version}}

      {:ok, _decoded} ->
        {:error, {:invalid_auth_file, path, :invalid_envelope}}

      {:error, _reason} ->
        {:error, {:malformed_auth_file, path}}
    end
  end

  defp valid_providers?(providers) do
    Enum.all?(providers, fn
      {namespace, credentials}
      when is_binary(namespace) and namespace != "" and is_map(credentials) ->
        true

      _ ->
        false
    end)
  end

  defp validate_namespace(namespace) when is_binary(namespace) and namespace != "", do: :ok
  defp validate_namespace(_namespace), do: {:error, :invalid_credential_namespace}

  defp normalize_credentials(credentials) when is_map(credentials) do
    encoded = JSON.encode!(credentials)

    case JSON.decode(encoded) do
      {:ok, %{} = normalized} -> {:ok, normalized}
      _ -> {:error, :invalid_credentials}
    end
  rescue
    _error -> {:error, :invalid_credentials}
  end

  defp normalize_credentials(_credentials), do: {:error, :invalid_credentials}

  defp persist(path, providers) do
    envelope = %{"version" => @version, "providers" => providers}

    with {:ok, encoded} <- encode_envelope(envelope),
         :ok <- ensure_private_directory(Path.dirname(path)),
         :ok <- safe_auth_target(path),
         {:ok, temporary_path, io} <- open_temporary(path) do
      write_replace(io, temporary_path, path, encoded)
    end
  end

  defp encode_envelope(envelope) do
    {:ok, JSON.encode!(envelope)}
  rescue
    _error -> {:error, :invalid_credentials}
  end

  defp ensure_private_directory(directory) do
    with :ok <- create_directory(directory),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(directory),
         :ok <- File.chmod(directory, @directory_mode) do
      :ok
    else
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:unsafe_auth_directory, directory, :symlink}}

      {:ok, %File.Stat{}} ->
        {:error, {:unsafe_auth_directory, directory, :not_directory}}

      {:error, reason} ->
        {:error, {:auth_directory_unavailable, directory, reason}}
    end
  end

  defp create_directory(directory) do
    case File.lstat(directory) do
      {:ok, _stat} -> :ok
      {:error, :enoent} -> File.mkdir_p(directory)
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_auth_target(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:unsafe_auth_file, path, :symlink}}
      {:ok, %File.Stat{}} -> {:error, {:unsafe_auth_file, path, :not_regular}}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:auth_file_unreadable, path, reason}}
    end
  end

  defp open_temporary(path) do
    temporary_path =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive, :monotonic])}"
      )

    case File.open(temporary_path, [:write, :binary, :exclusive]) do
      {:ok, io} -> {:ok, temporary_path, io}
      {:error, reason} -> {:error, {:auth_temporary_file_failed, path, reason}}
    end
  end

  defp write_replace(io, temporary_path, path, encoded) do
    write_result = write_sync_close(io, temporary_path, encoded)

    result =
      with :ok <- write_result,
           :ok <- safe_auth_target(path),
           :ok <- File.rename(temporary_path, path) do
        :ok
      else
        {:error, reason} when is_atom(reason) ->
          {:error, {:auth_file_write_failed, path, reason}}

        {:error, reason} ->
          {:error, reason}
      end

    if result != :ok, do: File.rm(temporary_path)
    result
  end

  defp write_sync_close(io, temporary_path, encoded) do
    write_result =
      try do
        with :ok <- File.chmod(temporary_path, @file_mode),
             :ok <- IO.binwrite(io, encoded) do
          :file.sync(io)
        end
      rescue
        _error -> {:error, :write_failed}
      catch
        _kind, _reason -> {:error, :write_failed}
      end

    close_result = File.close(io)

    case {write_result, close_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _close_result} -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, reason}
    end
  end
end
