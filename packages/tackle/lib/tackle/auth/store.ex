defmodule Tackle.Auth.Store do
  @moduledoc """
  Supervised, file-backed storage for opaque provider credentials and the
  provider accounts created by `tackle auth login --as`.

  The file is plaintext JSON protected by directory mode `0700` and file mode
  `0600`; it is not encrypted. Every write replaces `auth.json` atomically (a
  temporary file renamed over it), so readers never observe partial JSON.

  Several VMs may share the file, such as two CLIs or a CLI and an SDK server,
  so the file, not the store's memory, is the source of truth:

    * Every change re-reads and re-validates the file, applies its one change
      to those contents, and writes the result, keeping what other VMs wrote.
    * Reads are served from the contents last read only while the file keeps
      its device, inode, size, and modification time, and was last modified
      before that read began; otherwise the file is read again. Each atomic
      replacement creates a new inode.

  Two locks, both `Tackle.FileLock`s on files beside `auth.json` in its `0700`
  directory, coordinate the VMs:

    * Every change holds the write lock `.auth.json.lock` from its re-read to
      its rename, so changes from different VMs at the same moment are
      applied one after the other and none is lost. A change waits up to
      `:write_lock_timeout` milliseconds (default and maximum 5000) for it and
      then fails with `{:error, {:auth_file_locked, path}}`.
    * `with_lock/3` (`Tackle.Lib.CredentialStore.with_lock/3`) holds a lock
      for one namespace, `.auth.json.<hash>.lock` named from a SHA-256 of the
      namespace, while the caller runs a function, such as an OAuth refresh
      that spends a rotating refresh token. It waits up to
      `:credential_lock_timeout` milliseconds (default 60000) and then
      returns `{:error, {:credential_lock_failed, {:lock_timeout, lock_path}}}`.
      Different namespaces do not wait for each other, and the function may
      fetch and change credentials through the store.

  On systems with `flock`, both are operating-system locks released when the
  process holding them exits, so they hold across VMs. Elsewhere they fall
  back to owner records, only as strong as the recorded PID: two VMs
  reclaiming a stale record at the same moment can both proceed. Lock files
  are `0600` and are not deleted. Reads take no lock. Power-loss durability
  after the rename and operating-system keyrings are outside this store.

  A file that becomes unreadable or invalid while the store runs makes reads
  and changes return `{:error, reason}`; such a file is never overwritten.

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

  alias Tackle.FileLock
  alias Tackle.Lib.LLM.Provider
  alias Tackle.StatusRedaction

  @version 2
  @readable_versions [1, 2]
  @directory_mode 0o700
  @file_mode 0o600
  @temporary_attempts 3
  @max_write_lock_timeout 5_000
  @default_credential_lock_timeout 60_000
  # Changes may wait for the write lock; their calls wait longer.
  @change_call_timeout @max_write_lock_timeout + 10_000

  @type state :: %{
          path: Path.t(),
          write_lock_timeout: non_neg_integer(),
          credential_lock_timeout: non_neg_integer(),
          providers: %{optional(String.t()) => map()},
          accounts: %{optional(String.t()) => account()},
          stamp: stamp() | nil
        }

  # The file's identity when it was last read, and the second that read
  # began; `nil` after a write, so the next read loads the file again.
  @typep stamp :: {identity(), integer()}
  @typep identity ::
           :missing
           | {:file, non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
              integer()}

  @typedoc ~S'An account record: `%{"adapter" => type_id}`, plus `"base" => provider_id` when set.'
  @type account :: %{required(String.t()) => String.t()}

  @doc false
  # Options: `:path` (required), `:name`, `:write_lock_timeout`, and
  # `:credential_lock_timeout` (see the moduledoc).
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
    do: GenServer.call(reference, {:put, namespace, credentials}, @change_call_timeout)

  @impl Tackle.Lib.CredentialStore
  def delete(reference, namespace),
    do: GenServer.call(reference, {:delete, namespace}, @change_call_timeout)

  # The lock is taken by the caller, not the store process, which stays free
  # to serve `fun`'s fetches and changes; it is released with the caller.
  @impl Tackle.Lib.CredentialStore
  def with_lock(reference, namespace, fun) when is_function(fun, 0) do
    with {:ok, lock_path, timeout} <- GenServer.call(reference, {:lock_path, namespace}),
         {:ok, result} <- FileLock.with_lock(lock_path, [wait: timeout], fun) do
      result
    else
      {:error, reason} -> {:error, {:credential_lock_failed, reason}}
    end
  end

  @doc false
  @spec status(GenServer.server(), String.t()) :: :stored | :missing | {:error, term()}
  def status(reference, namespace), do: GenServer.call(reference, {:status, namespace})

  @doc false
  @spec accounts(GenServer.server()) ::
          {:ok, %{optional(String.t()) => account()}} | {:error, term()}
  def accounts(reference), do: GenServer.call(reference, :accounts)

  @doc false
  @spec put_account(GenServer.server(), String.t(), account()) :: :ok | {:error, term()}
  def put_account(reference, provider_id, account),
    do: GenServer.call(reference, {:put_account, provider_id, account}, @change_call_timeout)

  @doc false
  @spec delete_account(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def delete_account(reference, provider_id),
    do: GenServer.call(reference, {:delete_account, provider_id}, @change_call_timeout)

  @impl true
  def init(opts) do
    with {:ok, path} <- fetch_path(opts),
         path = Path.expand(path),
         {:ok, write_timeout} <-
           fetch_timeout(
             opts,
             :write_lock_timeout,
             @max_write_lock_timeout,
             @max_write_lock_timeout
           ),
         {:ok, credential_timeout} <-
           fetch_timeout(opts, :credential_lock_timeout, @default_credential_lock_timeout, nil),
         {:ok, contents} <- load(path) do
      {:ok,
       Map.merge(contents, %{
         path: path,
         write_lock_timeout: write_timeout,
         credential_lock_timeout: credential_timeout
       })}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:fetch, namespace}, _from, state) do
    read(state, namespace, &Map.fetch(&1.providers, namespace))
  end

  def handle_call({:status, namespace}, _from, state) do
    read(
      state,
      namespace,
      &if(Map.has_key?(&1.providers, namespace), do: :stored, else: :missing)
    )
  end

  def handle_call(:accounts, _from, state), do: read(state, &{:ok, &1.accounts})

  def handle_call({:lock_path, namespace}, _from, state) do
    with :ok <- validate_namespace(namespace),
         :ok <- ensure_private_directory(Path.dirname(state.path)) do
      {:reply, {:ok, namespace_lock_path(state.path, namespace), state.credential_lock_timeout},
       state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put, namespace, credentials}, _from, state) do
    with :ok <- validate_namespace(namespace),
         {:ok, credentials} <- normalize_credentials(credentials) do
      change(state, fn providers, accounts ->
        {Map.put(providers, namespace, credentials), accounts}
      end)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, namespace}, _from, state) do
    case validate_namespace(namespace) do
      :ok ->
        change(state, fn providers, accounts -> {Map.delete(providers, namespace), accounts} end)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:put_account, provider_id, account}, _from, state) do
    case Tackle.Auth.validate_account(provider_id, account) do
      {:ok, account} ->
        change(state, fn providers, accounts ->
          {providers, Map.put(accounts, provider_id, account)}
        end)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_account, provider_id}, _from, state) do
    if Provider.valid_id?(provider_id) do
      change(state, fn providers, accounts -> {providers, Map.delete(accounts, provider_id)} end)
    else
      {:reply, {:error, {:invalid_account, provider_id}}, state}
    end
  end

  # Crash reports and `:sys.get_status/1` show the state and the last message.
  # Neither may carry credentials: the stored credentials are reduced to their
  # namespaces and the message to its operation. Accounts hold no secrets.
  @impl true
  def format_status(status), do: StatusRedaction.format_status(status, &redact_state/1)

  defp redact_state(%{providers: providers} = state) when is_map(providers) do
    %{state | providers: Map.new(providers, fn {namespace, _} -> {namespace, :redacted} end)}
  end

  defp redact_state(state), do: state

  defp read(state, namespace, fun) do
    case validate_namespace(namespace) do
      :ok -> read(state, fun)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp read(state, fun) do
    case current(state) do
      {:ok, state} -> {:reply, fun.(state), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp current(state) do
    if unchanged?(state) do
      {:ok, state}
    else
      with {:ok, contents} <- load(state.path), do: {:ok, Map.merge(state, contents)}
    end
  end

  # A file modified in the second its last read began may have changed after
  # that read without changing its identity (an inode reused within the same
  # second, at the same size), so it is read again.
  defp unchanged?(%{stamp: nil}), do: false

  defp unchanged?(%{path: path, stamp: {identity, read_at}}) do
    case identity(path) do
      {:ok, ^identity} -> modified_before?(identity, read_at)
      _changed -> false
    end
  end

  defp modified_before?(:missing, _read_at), do: true
  defp modified_before?({:file, _, _, _, _, mtime}, read_at), do: mtime < read_at

  defp identity(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, file_identity(stat)}
      {:error, :enoent} -> {:ok, :missing}
      _other -> :error
    end
  end

  defp file_identity(%File.Stat{} = stat),
    do: {:file, stat.major_device, stat.minor_device, stat.inode, stat.size, stat.mtime}

  # Applies one change to the file's current contents, so that what other VMs
  # wrote since the last read is kept. The write lock keeps other VMs from
  # changing the file between that read and the rename. An unchanged result
  # writes nothing.
  defp change(state, fun) do
    with :ok <- ensure_private_directory(Path.dirname(state.path)),
         {:ok, reply} <- with_write_lock(state, fn -> change_locked(state, fun) end) do
      reply
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp change_locked(state, fun) do
    case load(state.path) do
      {:ok, contents} -> apply_change(Map.merge(state, contents), fun)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp with_write_lock(%{path: path} = state, fun) do
    case FileLock.with_lock(write_lock_path(path), [wait: state.write_lock_timeout], fun) do
      {:error, {:lock_timeout, _lock_path}} -> {:error, {:auth_file_locked, path}}
      result -> result
    end
  end

  defp write_lock_path(path), do: Path.join(Path.dirname(path), ".#{Path.basename(path)}.lock")

  # Namespaces are arbitrary strings; the file is named from their hash.
  defp namespace_lock_path(path, namespace) do
    hash =
      :sha256
      |> :crypto.hash(namespace)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 22)

    Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{hash}.lock")
  end

  defp apply_change(%{providers: providers, accounts: accounts} = state, fun) do
    case fun.(providers, accounts) do
      {^providers, ^accounts} ->
        {:reply, :ok, state}

      {changed_providers, changed_accounts} ->
        case persist(state.path, changed_providers, changed_accounts) do
          :ok ->
            {:reply, :ok,
             %{state | providers: changed_providers, accounts: changed_accounts, stamp: nil}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  defp fetch_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :auth_path_required}
    end
  end

  defp fetch_timeout(opts, key, default, max) do
    case Keyword.get(opts, key, default) do
      timeout when is_integer(timeout) and timeout >= 0 and (is_nil(max) or timeout <= max) ->
        {:ok, timeout}

      _invalid ->
        {:error, {:invalid_option, key}}
    end
  end

  # The stamp is taken before the file is read, so any later change shows in
  # its identity or modification time.
  defp load(path) do
    read_at = System.os_time(:second)

    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        with :ok <- secure_existing_file(path),
             {:ok, {providers, accounts}} <- read_envelope(path) do
          {:ok,
           %{providers: providers, accounts: accounts, stamp: {file_identity(stat), read_at}}}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:unsafe_auth_file, path, :symlink}}

      {:ok, %File.Stat{}} ->
        {:error, {:unsafe_auth_file, path, :not_regular}}

      {:error, :enoent} ->
        {:ok, %{providers: %{}, accounts: %{}, stamp: {:missing, read_at}}}

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
      match?({:ok, _account}, Tackle.Auth.validate_account(provider_id, account))
    end)
  end

  defp valid_accounts?(%{"accounts" => _other}), do: false
  defp valid_accounts?(_envelope), do: true

  defp envelope_accounts(%{"version" => 1}), do: %{}

  defp envelope_accounts(envelope) do
    envelope
    |> Map.get("accounts", %{})
    |> Map.new(fn {provider_id, account} ->
      {:ok, account} = Tackle.Auth.validate_account(provider_id, account)
      {provider_id, account}
    end)
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
