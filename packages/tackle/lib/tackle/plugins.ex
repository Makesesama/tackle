defmodule Tackle.Plugins do
  @moduledoc """
  Merges the providers that a host's adapters back, and lists their models.

  Adapter modules are already available in the running BEAM and supplied by
  trusted host code: every function takes them explicitly, usually the
  adapters of the host's `Tackle.Plugins.Catalog`, which validates the host's
  contributions (`Tackle.Plugins.Loader` loads those of enabled plugin
  projects). CLI arguments and user configuration select model references;
  they do not name or load adapter modules directly.

  ## Providers

  An adapter module is an executable type; a provider (`Tackle.Lib.LLM.Provider`)
  is one configured instance of it, and its id is the model-reference prefix
  and credential namespace. The available providers are merged from three
  sources, lowest precedence first:

    1. `:default` — each adapter's default providers
       (`Tackle.Lib.LLM.Provider.defaults/1`).
    2. `:account` — accounts recorded by `tackle auth login ID --as NAME`
       (`Tackle.Auth.accounts/0`), checked as `auth.json` checks them
       (`Tackle.Auth.validate_account/2`).
    3. `:config` — the `"providers"` object of `config.json`, where each entry
       names an adapter type id under `"adapter"` and every other key is an
       opaque setting.

  A `config.json` entry for a default provider id must name the same adapter
  type; its settings are merged over the defaults. Naming a different adapter
  type fails with `{:provider_adapter_conflict, id}`. An entry naming an
  adapter type that no configured module provides is skipped: `config.json`
  is shared by every host on the machine, and a host without that adapter
  cannot use the provider.

  An account starts from the settings of its base provider (the provider it
  was created from, with `config.json` settings already merged), or from no
  settings when it was created from an adapter type id or its base no longer
  exists. The base's `"api_key_env"` setting is not inherited, so an account
  never silently uses the environment key of the provider it was created
  from. A `config.json` entry for the account's own id merges over that, and
  may name the account's own `"api_key_env"`. Like
  `auth.json` itself, accounts are shared by every host, so an account is
  skipped when this host lacks its adapter, when its id is the id of a
  default provider of any of the host's adapters, or when a `config.json`
  entry declares its id for another of the host's adapters.

  Providers keep their first position; new providers follow the defaults,
  accounts before configured providers, each group sorted by id.
  """

  alias Tackle.Config.File, as: ConfigFile
  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Provider

  @typedoc "Where a provider was first declared."
  @type source :: :default | :account | :config

  @typedoc "A merged provider together with where it was first declared."
  @type entry :: %{provider: Provider.t(), source: source()}

  @typedoc """
  A recorded account: the adapter type id under `"adapter"` and, when the
  account was created from a provider id, that base provider id under `"base"`.
  """
  @type account :: %{required(String.t()) => String.t()}

  @typedoc "Recorded accounts keyed by provider id."
  @type accounts :: %{optional(String.t()) => account()}

  @typedoc ~S'Provider declarations shaped like `config.json`: `%{id => %{"adapter" => type, ...settings}}`.'
  @type declarations :: %{optional(String.t()) => map()}

  @doc """
  Returns the providers of `adapters`, merged as described in the module docs.

  `adapters` are the adapter modules the host offers, such as the adapters of
  its `Tackle.Plugins.Catalog` (`Tackle.Plugins.Catalog.adapter_modules/1`);
  an empty list is `{:error, :no_adapters_configured}`. Options:

    * `:accounts` — recorded accounts (`t:accounts/0`); defaults to
      `Tackle.Auth.accounts/0`.
    * `:config_providers` — provider declarations shaped like the
      `config.json` `"providers"` object; defaults to that object of the
      `config.json` found through `:env`.
    * `:env` — environment used to locate `config.json`; defaults to the
      process environment.

  Hosts that already loaded these sources should pass them explicitly.
  """
  @spec available_providers([module()], keyword()) :: {:ok, [Provider.t()]} | {:error, term()}
  def available_providers(adapters, opts \\ []) do
    with {:ok, entries} <- provider_entries(adapters, opts) do
      {:ok, Enum.map(entries, & &1.provider)}
    end
  end

  @doc """
  Like `available_providers/2`, but keeps where each provider was first declared.

  The merged providers must offer at least one model
  (`{:error, :no_models_configured}`), and the first one is selected through
  the checks a session uses.
  """
  @spec provider_entries([module()], keyword()) :: {:ok, [entry()]} | {:error, term()}
  def provider_entries(adapters, opts \\ [])

  def provider_entries(adapters, opts) when is_list(opts) do
    with {:ok, adapters} <- validate_adapters(adapters),
         {:ok, accounts} <- fetch_accounts(opts),
         {:ok, declarations} <- fetch_config_providers(opts),
         {:ok, entries} <- merge_providers(adapters, accounts, declarations),
         :ok <- validate_providers(Enum.map(entries, & &1.provider)) do
      {:ok, entries}
    end
  end

  def provider_entries(_adapters, opts), do: {:error, {:invalid_plugin_options, opts}}

  @doc """
  Merges adapter default providers, configured provider declarations, and
  recorded accounts as described in the module docs.

  This is the pure merge behind `available_providers/2`; it does not check
  that the result offers any model.
  """
  @spec merge_providers([module()], accounts(), declarations()) ::
          {:ok, [entry()]} | {:error, term()}
  def merge_providers(adapters, accounts, declarations)
      when is_list(adapters) and is_map(accounts) and is_map(declarations) do
    with {:ok, types} <- index_adapter_types(adapters),
         {:ok, defaults} <- Provider.expand(adapters),
         {:ok, accounts} <- account_declarations(accounts),
         {:ok, configured} <- config_declarations(declarations, types),
         {:ok, defaults, configured} <- configure_defaults(defaults, configured) do
      {accounts, configured} = add_accounts(accounts, types, defaults, configured)

      {:ok,
       Enum.map(defaults, &%{provider: &1, source: :default}) ++
         Enum.map(accounts, &%{provider: &1, source: :account}) ++
         Enum.map(configured, &%{provider: &1, source: :config})}
    end
  end

  def merge_providers(adapters, accounts, declarations),
    do: {:error, {:invalid_provider_sources, {adapters, accounts, declarations}}}

  @doc """
  Checks provider declarations shaped like the `config.json` `"providers"`
  object, as `Tackle.Config.load/1` does for the file and the merge does for
  `:config_providers`: every id and the adapter type id under its
  `"adapter"` must be valid provider ids (`Tackle.Lib.LLM.Provider.valid_id?/1`),
  or `{:error, {:invalid_provider, id}}`. Whether this host has the adapter
  is not checked.
  """
  @spec validate_declarations(declarations()) :: :ok | {:error, {:invalid_provider, term()}}
  def validate_declarations(declarations) when is_map(declarations) do
    case Enum.find(Enum.sort(declarations), &(not valid_declaration?(&1))) do
      nil -> :ok
      {id, _entry} -> {:error, {:invalid_provider, id}}
    end
  end

  defp valid_declaration?({id, %{"adapter" => adapter_id}}),
    do: Provider.valid_id?(id) and Provider.valid_id?(adapter_id)

  defp valid_declaration?(_declaration), do: false

  @doc """
  Returns canonical `provider_id/model` references of the providers of
  `adapters`; see `available_providers/2`.
  """
  @spec available_model_refs([module()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def available_model_refs(adapters, opts \\ []) do
    with {:ok, providers} <- available_providers(adapters, opts) do
      model_refs(providers)
    end
  end

  @doc """
  Returns the first canonical model reference that `providers` offer, which a
  configuration selects when none is configured, or
  `{:error, :no_models_configured}`. Providers whose models cannot be listed
  are passed over.
  """
  @spec default_model_ref([Provider.t()]) :: {:ok, String.t()} | {:error, :no_models_configured}
  def default_model_ref(providers) when is_list(providers) do
    Enum.find_value(providers, {:error, :no_models_configured}, fn provider ->
      case provider_models(provider) do
        {:ok, [model | _models]} -> {:ok, "#{provider.id}/#{model}"}
        _other -> nil
      end
    end)
  end

  defp validate_adapters([]), do: {:error, :no_adapters_configured}
  defp validate_adapters(adapters) when is_list(adapters), do: {:ok, adapters}
  defp validate_adapters(adapters), do: {:error, {:invalid_adapters_configuration, adapters}}

  defp fetch_accounts(opts) do
    case Keyword.fetch(opts, :accounts) do
      {:ok, %{} = accounts} -> {:ok, accounts}
      {:ok, accounts} -> {:error, {:invalid_option, :accounts, accounts}}
      :error -> Tackle.Auth.accounts()
    end
  end

  defp fetch_config_providers(opts) do
    case Keyword.fetch(opts, :config_providers) do
      {:ok, %{} = declarations} ->
        {:ok, declarations}

      {:ok, declarations} ->
        {:error, {:invalid_option, :config_providers, declarations}}

      :error ->
        with {:ok, path} <- Tackle.Paths.config_file(Keyword.take(opts, [:env])),
             {:ok, file_opts} <- ConfigFile.load(path) do
          {:ok, Keyword.get(file_opts, :providers, %{})}
        end
    end
  end

  # Adapter type ids name the adapter a declaration refers to.
  defp index_adapter_types(adapters) do
    Enum.reduce_while(adapters, {:ok, %{}}, fn adapter, {:ok, index} ->
      case index_adapter_type(index, adapter) do
        {:ok, index} -> {:cont, {:ok, index}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp index_adapter_type(index, adapter) do
    with {:ok, [_ | _]} <- Provider.defaults(adapter),
         {:ok, adapter_id} <- Provider.adapter_id(adapter) do
      put_adapter_type(index, adapter_id, adapter)
    end
  end

  defp put_adapter_type(index, adapter_id, adapter) do
    case Map.fetch(index, adapter_id) do
      {:ok, ^adapter} -> {:ok, index}
      {:ok, _other} -> {:error, {:duplicate_adapter_type, adapter_id}}
      :error -> {:ok, Map.put(index, adapter_id, adapter)}
    end
  end

  # Accounts are checked as `auth.json` checks them.
  defp account_declarations(accounts) do
    accounts
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {id, account}, {:ok, acc} ->
      case Tackle.Auth.validate_account(id, account) do
        {:ok, account} -> {:cont, {:ok, [{id, account["adapter"], account["base"]} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_ok()
  end

  # Declarations of adapter types this host lacks are skipped once their
  # shape is known to be valid.
  defp config_declarations(declarations, types) do
    with :ok <- validate_declarations(declarations) do
      {:ok,
       for {id, %{"adapter" => adapter_id} = entry} <- Enum.sort(declarations),
           Map.has_key?(types, adapter_id) do
         %Provider{id: id, adapter: types[adapter_id], settings: Map.delete(entry, "adapter")}
       end}
    end
  end

  defp reverse_ok({:ok, list}), do: {:ok, Enum.reverse(list)}
  defp reverse_ok(error), do: error

  # Merges declarations for default provider ids into those defaults and
  # returns the remaining, newly declared providers.
  defp configure_defaults(defaults, configured) do
    configured
    |> Enum.reduce_while({:ok, defaults, []}, fn provider, {:ok, defaults, new} ->
      case configure_default(defaults, provider) do
        {:merged, defaults} -> {:cont, {:ok, defaults, new}}
        :new -> {:cont, {:ok, defaults, [provider | new]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, defaults, new} -> {:ok, defaults, Enum.reverse(new)}
      error -> error
    end
  end

  defp configure_default(defaults, %Provider{} = provider) do
    case Enum.find_index(defaults, &(&1.id == provider.id)) do
      nil -> :new
      index -> merge_default(defaults, index, provider)
    end
  end

  defp merge_default(defaults, index, %Provider{adapter: adapter} = provider) do
    case Enum.at(defaults, index) do
      %Provider{adapter: ^adapter} = default ->
        default = %{default | settings: Map.merge(default.settings, provider.settings)}
        {:merged, List.replace_at(defaults, index, default)}

      %Provider{} ->
        {:error, {:provider_adapter_conflict, provider.id}}
    end
  end

  # An account whose id is also declared in `config.json` for the same adapter
  # takes that declaration's settings and moves it to the accounts group.
  defp add_accounts(accounts, types, defaults, configured) do
    bases = defaults ++ configured

    {added, configured} =
      Enum.reduce(accounts, {[], configured}, fn account, {added, configured} ->
        case add_account(account, types, defaults, bases, configured) do
          {:added, provider, configured} -> {[provider | added], configured}
          :skipped -> {added, configured}
        end
      end)

    {Enum.reverse(added), configured}
  end

  # Accounts of adapters this host lacks, or named like a default provider,
  # are skipped.
  defp add_account({id, adapter_id, base}, types, defaults, bases, configured) do
    with {:ok, adapter} <- Map.fetch(types, adapter_id),
         false <- Enum.any?(defaults, &(&1.id == id)) do
      settings = base_settings(bases, base, adapter)
      declare_account(id, adapter, settings, configured)
    else
      _skipped -> :skipped
    end
  end

  # A `config.json` declaration of another adapter wins over the account.
  defp declare_account(id, adapter, settings, configured) do
    case Enum.find(configured, &(&1.id == id)) do
      nil ->
        {:added, %Provider{id: id, adapter: adapter, settings: settings}, configured}

      %Provider{adapter: ^adapter} = declared ->
        provider = %{declared | settings: Map.merge(settings, declared.settings)}
        {:added, provider, List.delete(configured, declared)}

      %Provider{} ->
        :skipped
    end
  end

  # `"api_key_env"` is not inherited: an account holds its own credentials and
  # must not silently use the key its base reads from the environment.
  defp base_settings(providers, base, adapter) do
    case Enum.find(providers, &(&1.id == base)) do
      %Provider{adapter: ^adapter, settings: settings} -> Map.delete(settings, "api_key_env")
      _missing -> %{}
    end
  end

  # Selecting the first offered model validates every provider's adapter
  # through the same contract checks a session uses.
  defp validate_providers(providers) do
    with {:ok, model_ref} <- default_model_ref(providers),
         {:ok, _selection} <- LLM.select(providers, model_ref) do
      :ok
    end
  end

  defp model_refs(providers) do
    providers
    |> Enum.reduce_while({:ok, []}, fn provider, {:ok, refs} ->
      case provider_models(provider) do
        {:ok, models} ->
          {:cont, {:ok, Enum.reverse(Enum.map(models, &"#{provider.id}/#{&1}"), refs)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :no_models_configured}
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Provider structs may name adapters that are not loaded yet; the model
  # callbacks are looked up with `function_exported?/3`.
  defp provider_models(%Provider{adapter: adapter} = provider) do
    Code.ensure_loaded(adapter)
    Provider.models(provider)
  end
end
