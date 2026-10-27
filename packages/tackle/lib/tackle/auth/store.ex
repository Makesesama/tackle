defmodule Tackle.Auth.Store do
  @moduledoc """
  Supervised, file-backed storage for opaque provider credentials and the
  provider accounts created by `tackle auth login --as`.

  The file is plaintext JSON protected by directory mode `0700` and file mode
  `0600`; it is not encrypted. Mutations are serialized within one Tackle
  application and persisted by replacing `auth.json` atomically, so readers do
  not observe partial JSON. Power-loss durability after the rename, cross-VM
  locking, and operating-system keyrings are intentionally outside this store.

  The file is a version 2 envelope. Credentials live under `"providers"`, keyed
  by provider id; accounts live under `"accounts"`, mapping a provider id to
  the adapter type that backs it and, when the account was created from a
  provider id, that base provider:

      {"version": 2,
       "providers": {"codex-work": {...credentials...}},
       "accounts": {"codex-work": {"adapter": "openai-codex"},
                    "cloud2": {"adapter": "ollama", "base": "ollama-cloud"}}}

  A version 1 file (credentials only) loads with no accounts and is rewritten
  as version 2 on the next change.
  """

  use GenServer

  @behaviour Tackle.Lib.CredentialStore

  alias Tackle.Lib.LLM.Provider
  alias Tackle.StatusRedaction

  @version 2
  @readable_versions [1, 2]
  @directory_mode 0o700
  @file_mode 0o600
  @temporary_attempts 3

  @type state :: %{
          path: Path.t(),
          providers: %{optional(String.t()) => map()},
          accounts: %{optional(String.t()) => account()}
        }

  @typedoc ~S'An account record: `%{"adapter" => type_id}`, plus `"base" => provider_id` when set.'
  @type account :: %{required(String.t()) => String.t()}

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

  @doc false
  @spec accounts(GenServer.server()) :: %{optional(String.t()) => account()}
  def accounts(reference), do: GenServer.call(reference, :accounts)

  @doc false
  @spec put_account(GenServer.server(), String.t(), account()) :: :ok | {:error, term()}
  def put_account(reference, provider_id, account),
    do: GenServer.call(reference, {:put_account, provider_id, account})

  @doc false
  @spec delete_account(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def delete_account(reference, provider_id),
    do: GenServer.call(reference, {:delete_account, provider_id})

  @impl true
  def init(opts) do
    with {:ok, path} <- fetch_path(opts),
         {:ok, {providers, accounts}} <- load(path) do
      {:ok, %{path: Path.expand(path), providers: providers, accounts: accounts}}
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

  def handle_call(:accounts, _from, state), do: {:reply, state.accounts, state}

  def handle_call({:put_account, provider_id, account}, _from, state) do
    with {:ok, account} <- normalize_account(provider_id, account),
         accounts = Map.put(state.accounts, provider_id, account),
         :ok <- persist(state.path, state.providers, accounts) do
      {:reply, :ok, %{state | accounts: accounts}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_account, provider_id}, _from, state) do
    cond do
      not Provider.valid_id?(provider_id) ->
        {:reply, {:error, {:invalid_account, provider_id}}, state}

      Map.has_key?(state.accounts, provider_id) ->
        accounts = Map.delete(state.accounts, provider_id)

        case persist(state.path, state.providers, accounts) do
          :ok -> {:reply, :ok, %{state | accounts: accounts}}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      true ->
        {:reply, :ok, state}
    end
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
         :ok <- persist(state.path, providers, state.accounts) do
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

  # Crash reports and `:sys.get_status/1` show the state and the last message.
  # Neither may carry credentials: the stored credentials are reduced to their
  # namespaces and the message to its operation. Accounts hold no secrets.
  @impl true
  def format_status(status), do: StatusRedaction.format_status(status, &redact_state/1)

  defp redact_state(%{providers: providers} = state) when is_map(providers),
    do: %{
      state
      | providers: Map.new(providers, fn {namespace, _credentials} -> {namespace, :redacted} end)
    }

  defp redact_state(state), do: state

  defp delete_namespace(namespace, state) do
    if Map.has_key?(state.providers, namespace) do
      providers = Map.delete(state.providers, namespace)
      delete_reply(persist(state.path, providers, state.accounts), providers, state)
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
        {:ok, {%{}, %{}}}

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
      {:ok, {envelope["providers"], envelope_accounts(envelope)}}
    else
      {:error, reason} when reason in [:eacces, :eperm] ->
        {:error, {:auth_file_unreadable, path, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_envelope(path, contents) do
    case JSON.decode(contents) do
      {:ok, %{"version" => version, "providers" => providers} = envelope}
      when version in @readable_versions and is_map(providers) ->
        validate_envelope(path, envelope)

      {:ok, %{"version" => version}} when version not in @readable_versions ->
        {:error, {:unsupported_auth_version, path, version}}

      {:ok, _decoded} ->
        {:error, {:invalid_auth_file, path, :invalid_envelope}}

      {:error, _reason} ->
        {:error, {:malformed_auth_file, path}}
    end
  end

  defp validate_envelope(path, envelope) do
    cond do
      not valid_providers?(envelope["providers"]) ->
        {:error, {:invalid_auth_file, path, :invalid_providers}}

      not valid_accounts?(envelope) ->
        {:error, {:invalid_auth_file, path, :invalid_accounts}}

      true ->
        {:ok, envelope}
    end
  end

  # Version 1 predates accounts; a version 2 file may omit them.
  defp valid_accounts?(%{"version" => 1}), do: true

  defp valid_accounts?(%{"accounts" => %{} = accounts}) do
    Enum.all?(accounts, fn {provider_id, account} ->
      match?({:ok, _account}, normalize_account(provider_id, account))
    end)
  end

  defp valid_accounts?(%{"accounts" => _other}), do: false
  defp valid_accounts?(_envelope), do: true

  defp envelope_accounts(%{"version" => 1}), do: %{}

  defp envelope_accounts(envelope) do
    envelope
    |> Map.get("accounts", %{})
    |> Map.new(fn {provider_id, account} ->
      {:ok, account} = normalize_account(provider_id, account)
      {provider_id, account}
    end)
  end

  # Keeps only the known keys; `"base"` is optional.
  defp normalize_account(provider_id, %{"adapter" => adapter_id} = account) do
    base = Map.get(account, "base")

    if Provider.valid_id?(provider_id) and Provider.valid_id?(adapter_id) and
         (is_nil(base) or Provider.valid_id?(base)) do
      {:ok, Map.take(account, ["adapter", "base"])}
    else
      {:error, {:invalid_account, provider_id}}
    end
  end

  defp normalize_account(provider_id, _account), do: {:error, {:invalid_account, provider_id}}

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

  defp persist(path, providers, accounts) do
    envelope = %{
      "version" => @version,
      "providers" => providers,
      "accounts" => accounts
    }

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

  # The name must be unique across VMs sharing the directory, and must not
  # repeat the name of a file a killed VM left behind; a collision is retried.
  defp open_temporary(path, attempts \\ @temporary_attempts) do
    temporary_path = Path.join(Path.dirname(path), temporary_name(path))

    case File.open(temporary_path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        {:ok, temporary_path, io}

      {:error, :eexist} when attempts > 1 ->
        open_temporary(path, attempts - 1)

      {:error, reason} ->
        {:error, {:auth_temporary_file_failed, path, reason}}
    end
  end

  defp temporary_name(path) do
    random = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    ".#{Path.basename(path)}.tmp-#{System.pid()}-#{random}"
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
