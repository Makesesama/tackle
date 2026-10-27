defmodule Tackle.Auth.Provider do
  @moduledoc """
  Adapter-driven provider account flows for login, logout, status, and usage.

  Frontends and the harness resolve a provider by its id among the available
  providers (`Tackle.Plugins.available_providers/1`) and delegate to its
  `Tackle.Lib.LLM` adapter. No provider-specific knowledge lives here: adapters
  implement the optional `login/1`, `logout/1`, `status/1`, and `usage/1`
  callbacks and own their complete flow. Each callback receives the provider's
  `:provider_id` and `:provider_settings` (`Tackle.Lib.LLM.Provider.opts/1`),
  so one adapter can keep a separate login per provider.

  Credential storage stays host-owned, and `Tackle.Auth` is its only store.
  `login/2` persists the map returned by the adapter under the provider id
  through `Tackle.Auth`; `logout/2` and `status/2` fall back to that store when
  the adapter does not implement the callback. Adapters always receive
  `Tackle.Auth.credential_store/0` as `:credential_store`, so those that manage
  their own credentials read and refresh the same store; a caller's
  `:credential_store` option is replaced.

  ## Named accounts

  `login(id, as: name)` creates provider `name` on the adapter that `id`
  names (a provider id or an adapter type id), runs that adapter's login with
  `provider_id: name`, and, once the credentials are stored under `name`,
  records the account in `auth.json` (`Tackle.Auth.put_account/2`). When `id`
  is a provider id, the account inherits that provider's settings (its
  `"base"`); an account takes no settings of its own, but a `config.json`
  provider with the same id merges its settings over it. Logging out of an
  account also deletes its record.

  ## Options

  `:adapters`, `:accounts`, `:config_providers`, and `:env` select where
  providers come from (see `Tackle.Plugins.available_providers/1`) and are not
  passed to adapters. Every other option, such as `:interaction`, is passed to
  the adapter callback, except `:credential_store` (see above).
  """

  alias Tackle.Auth
  alias Tackle.Lib.LLM.Provider
  alias Tackle.Plugins

  @plugin_keys [:adapters, :accounts, :config_providers, :env]

  @typedoc "A provider made available by the configured adapters, accounts, and config."
  @type provider :: %{
          required(:id) => String.t(),
          required(:adapter) => String.t(),
          required(:module) => module(),
          required(:models) => [String.t()],
          required(:capabilities) => capabilities(),
          required(:source) => Plugins.source()
        }

  @type capabilities :: %{
          login: boolean(),
          logout: boolean(),
          status: boolean(),
          usage: boolean()
        }

  @doc """
  Lists the available providers.

  `:adapter` is the adapter type id, and `:source` is where the provider was
  first declared: `:default`, `:account`, or `:config`.
  """
  @spec list(keyword()) :: {:ok, [provider()]} | {:error, term()}
  def list(opts \\ []) when is_list(opts) do
    with {:ok, entries} <- Plugins.provider_entries(plugin_opts(opts)) do
      {:ok, Enum.map(entries, &describe/1)}
    end
  end

  @doc """
  Runs one provider's interactive login and stores the returned credentials.

  The adapter must implement `login/1`. Pass `:interaction` for user prompts and
  any adapter-specific options (HTTP seams, timeouts).

  With `as: name`, `provider_id` may also be an adapter type id: the login
  creates the account `name` on that adapter (or on the named provider's
  adapter, inheriting its settings), and its credentials are stored under
  `name`. The account is recorded only after the login succeeded and its
  credentials were stored. `name` must be a valid provider id and must not
  name a provider or a recorded account of another adapter (including an
  account for an adapter this host lacks); otherwise the login fails with
  `{:provider_adapter_conflict, name}` before the adapter is called.
  """
  @spec login(String.t(), keyword()) :: :ok | {:error, term()}
  def login(provider_id, opts \\ []) when is_list(opts) do
    case Keyword.pop(opts, :as) do
      {nil, opts} -> login_provider(provider_id, opts)
      {name, opts} -> login_as(provider_id, name, opts)
    end
  end

  @doc """
  Logs out of one provider.

  When the adapter implements `logout/1` it fully owns credential cleanup;
  otherwise the host deletes the credentials stored under the provider id.
  Logging out of an account created with `login(id, as: name)` also deletes
  the account record.
  """
  @spec logout(String.t(), keyword()) :: :ok | {:error, term()}
  def logout(provider_id, opts \\ []) when is_list(opts) do
    with {:ok, provider} <- resolve(provider_id, opts),
         :ok <- remove_credentials(provider, opts) do
      forget_account(provider)
    end
  end

  @doc """
  Reports one provider's credential status.

  Adapters that implement `status/1` define the reported value; otherwise the
  host reads the credential store and returns `{:ok, :stored} | {:ok, :missing}`.
  """
  @spec status(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def status(provider_id, opts \\ []) when is_list(opts) do
    with {:ok, provider} <- resolve(provider_id, opts) do
      if function_exported?(provider.adapter, :status, 1) do
        call(provider.adapter, :status, [adapter_opts(provider, opts)])
      else
        stored_status(provider.id)
      end
    end
  end

  @doc """
  Returns one provider's account usage report.

  Requires the adapter to implement `usage/1`; otherwise the result is
  `{:error, {:unsupported_provider_flow, provider_id, :usage}}`.
  """
  @spec usage(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def usage(provider_id, opts \\ []) when is_list(opts) do
    with {:ok, provider} <- resolve(provider_id, opts),
         :ok <- require_callback(provider, :usage, 1) do
      call(provider.adapter, :usage, [adapter_opts(provider, opts)])
    end
  end

  @doc "Resolves a provider id among the available providers."
  @spec resolve(String.t(), keyword()) :: {:ok, Provider.t()} | {:error, term()}
  def resolve(provider_id, opts \\ []) when is_list(opts) do
    with {:ok, entries} <- Plugins.provider_entries(plugin_opts(opts)) do
      find_provider(provider_id, providers(entries))
    end
  end

  defp login_provider(provider_id, opts) do
    with {:ok, provider} <- resolve(provider_id, opts) do
      run_login(provider, opts)
    end
  end

  # Everything that could reject the account is checked before the adapter's
  # interactive login runs; the account is recorded only after its
  # credentials are stored.
  defp login_as(id, name, opts) do
    with :ok <- validate_name(name),
         {:ok, accounts} <- current_accounts(opts),
         {:ok, entries} <- Plugins.provider_entries(plugin_opts(opts)),
         {:ok, adapter, base} <- login_source(id, entries, accounts),
         {:ok, adapter_id} <- Provider.adapter_id(adapter),
         :ok <- check_recorded(accounts, name, adapter_id),
         recorded? = Map.has_key?(accounts, name),
         account = account(adapter_id, base),
         accounts = Map.put(accounts, name, account),
         {:ok, entries} <- Plugins.provider_entries(plugin_opts(opts, accounts)),
         {:ok, provider} <- find_account(name, adapter, providers(entries)),
         :ok <- run_login(provider, opts) do
      record_account(name, account, recorded?)
    end
  end

  defp run_login(%Provider{} = provider, opts) do
    with :ok <- require_callback(provider, :login, 1),
         {:ok, credentials} <- call(provider.adapter, :login, [adapter_opts(provider, opts)]) do
      store(provider.id, credentials)
    end
  end

  defp validate_name(name) do
    if Provider.valid_id?(name), do: :ok, else: {:error, {:invalid_provider_id, name}}
  end

  defp current_accounts(opts) do
    case Keyword.fetch(opts, :accounts) do
      {:ok, %{} = accounts} -> {:ok, accounts}
      {:ok, accounts} -> {:error, {:invalid_plugin_option, :accounts, accounts}}
      :error -> stored_accounts()
    end
  end

  defp stored_accounts do
    case Auth.accounts() do
      {:ok, accounts} -> {:ok, accounts}
      {:error, reason} -> {:error, {:accounts_unavailable, reason}}
    end
  catch
    :exit, reason -> {:error, {:accounts_unavailable, reason}}
  end

  # A provider id names its adapter and becomes the account's base (an
  # account's own base, so bases never chain); otherwise `id` may be an
  # adapter type id, and the account has no base.
  defp login_source(id, entries, accounts) do
    case Enum.find(entries, &(&1.provider.id == id)) do
      %{provider: %Provider{adapter: adapter}, source: :account} ->
        {:ok, adapter, get_in(accounts, [id, "base"])}

      %{provider: %Provider{adapter: adapter}} ->
        {:ok, adapter, id}

      nil ->
        providers = providers(entries)
        adapters = providers |> Enum.map(& &1.adapter) |> Enum.uniq()

        case Enum.find(adapters, &(Provider.adapter_id(&1) == {:ok, id})) do
          nil -> {:error, unsupported(id, providers, adapters)}
          adapter -> {:ok, adapter, nil}
        end
    end
  end

  # Recorded accounts are checked directly: the merge skips accounts whose
  # adapter this host lacks, and those must not be overwritten either.
  defp check_recorded(accounts, name, adapter_id) do
    case accounts do
      %{^name => %{"adapter" => ^adapter_id}} -> :ok
      %{^name => _other} -> {:error, {:provider_adapter_conflict, name}}
      %{} -> :ok
    end
  end

  defp account(adapter_id, nil), do: %{"adapter" => adapter_id}
  defp account(adapter_id, base), do: %{"adapter" => adapter_id, "base" => base}

  # The merge skips an account whose id names a provider of another adapter,
  # so the name then resolves to that provider.
  defp find_account(name, adapter, providers) do
    case find_provider(name, providers) do
      {:ok, %Provider{adapter: ^adapter} = provider} -> {:ok, provider}
      {:ok, %Provider{}} -> {:error, {:provider_adapter_conflict, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  # An account must only exist together with its credentials: when a new
  # account cannot be recorded, the credentials just stored for it are
  # deleted. A re-login keeps them, since its previous record still stands.
  defp record_account(name, account, recorded?) do
    case stored_accounts() do
      {:ok, %{^name => ^account}} ->
        :ok

      _other ->
        put_account(name, account, recorded?)
    end
  end

  defp put_account(name, account, recorded?) do
    case Auth.put_account(name, account) do
      :ok ->
        :ok

      {:error, reason} ->
        unless recorded?, do: Auth.delete(name)
        {:error, reason}
    end
  end

  # Only an account of this provider's adapter is deleted; a record of the
  # same name for another adapter belongs to another host's provider.
  defp forget_account(%Provider{id: id, adapter: adapter}) do
    with {:ok, adapter_id} <- Provider.adapter_id(adapter),
         {:ok, accounts} <- stored_accounts() do
      case accounts do
        %{^id => %{"adapter" => ^adapter_id}} -> Auth.delete_account(id)
        %{} -> :ok
      end
    end
  end

  defp remove_credentials(%Provider{} = provider, opts) do
    if function_exported?(provider.adapter, :logout, 1),
      do: call(provider.adapter, :logout, [adapter_opts(provider, opts)]),
      else: Auth.delete(provider.id)
  end

  defp find_provider(provider_id, providers) when is_binary(provider_id) and provider_id != "" do
    case Enum.find(providers, &(&1.id == provider_id)) do
      nil -> {:error, unsupported(provider_id, providers, [])}
      provider -> {:ok, provider}
    end
  end

  defp find_provider(provider_id, providers) do
    {:error, {:invalid_auth_provider, provider_id, {:supported, Enum.map(providers, & &1.id)}}}
  end

  # Login with `:as` also accepts adapter type ids, so they are listed too.
  defp unsupported(id, providers, adapters) do
    types = for adapter <- adapters, {:ok, type} <- [Provider.adapter_id(adapter)], do: type
    supported = Enum.uniq(Enum.map(providers, & &1.id) ++ types)
    {:unsupported_auth_provider, id, {:supported, supported}}
  end

  defp providers(entries), do: Enum.map(entries, & &1.provider)

  defp describe(%{provider: %Provider{adapter: adapter} = provider, source: source}) do
    %{
      id: provider.id,
      adapter: adapter_id(adapter),
      module: adapter,
      models: models(provider),
      capabilities: %{
        login: function_exported?(adapter, :login, 1),
        logout: function_exported?(adapter, :logout, 1),
        status: function_exported?(adapter, :status, 1),
        usage: function_exported?(adapter, :usage, 1)
      },
      source: source
    }
  end

  defp models(provider) do
    case Provider.models(provider) do
      {:ok, models} -> models
      {:error, _reason} -> []
    end
  end

  defp adapter_id(adapter) do
    case Provider.adapter_id(adapter) do
      {:ok, adapter_id} -> adapter_id
      {:error, _reason} -> nil
    end
  end

  defp require_callback(%Provider{} = provider, callback, arity) do
    if function_exported?(provider.adapter, callback, arity) do
      :ok
    else
      {:error, {:unsupported_provider_flow, provider.id, callback}}
    end
  end

  defp store(provider_id, credentials) when is_map(credentials) do
    Auth.put(provider_id, credentials)
  end

  defp store(_provider_id, other), do: {:error, {:invalid_credentials, other}}

  defp stored_status(provider_id) do
    case Auth.status(provider_id) do
      :stored -> {:ok, :stored}
      :missing -> {:ok, :missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp plugin_opts(opts), do: Keyword.take(opts, @plugin_keys)
  defp plugin_opts(opts, accounts), do: opts |> plugin_opts() |> Keyword.put(:accounts, accounts)

  defp adapter_opts(%Provider{} = provider, opts) do
    opts
    |> Keyword.drop(@plugin_keys)
    |> Keyword.merge(Provider.opts(provider))
    |> Keyword.put(:credential_store, Auth.credential_store())
  end

  defp call(adapter, callback, args) do
    apply(adapter, callback, args)
  rescue
    exception ->
      {:error, {:adapter_callback_failed, adapter, callback, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:adapter_callback_failed, adapter, callback, {kind, reason}}}
  end
end
