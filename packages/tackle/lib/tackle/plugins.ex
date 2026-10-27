defmodule Tackle.Plugins do
  @moduledoc """
  Resolves harness-owned plugin contributions made available to frontends.

  This initial slice supports adapter modules that are already available in the
  running BEAM and configured by trusted application code. CLI arguments and
  user configuration select model references; they do not name or load adapter
  modules directly.

  ## Providers

  An adapter module is an executable type; a provider (`Tackle.Lib.LLM.Provider`)
  is one configured instance of it, and its id is the model-reference prefix
  and credential namespace. The available providers are merged from three
  sources:

    1. `:default` — each adapter's default providers
       (`Tackle.Lib.LLM.Provider.defaults/1`).
    2. `:config` — the `"providers"` object of `config.json`, where each entry
       names an adapter type id under `"adapter"` and every other key is an
       opaque setting.
    3. `:account` — accounts recorded by `tackle auth login ID --as NAME`
       (`Tackle.Auth.accounts/0`).

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
  skipped when this host lacks its adapter, when its id names a default
  provider of any adapter, or when its id names a `config.json` provider of
  another adapter.

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
  Returns the configured adapter modules after checking that their default
  providers expand.

  Reads `:adapters`, defaulting to the `:tackle, :adapters` application
  environment. Whether the providers offer a model is checked only once all
  providers are merged (`provider_entries/1`): adapters whose models come only
  from `config.json` offer none by default.
  """
  @spec available_adapters(keyword()) :: {:ok, [module()]} | {:error, term()}
  def available_adapters(opts \\ [])

  def available_adapters(opts) when is_list(opts) do
    with {:ok, adapters} <- fetch_adapters(opts),
         {:ok, _providers} <- Provider.expand(adapters) do
      {:ok, adapters}
    end
  end

  def available_adapters(opts), do: {:error, {:invalid_plugin_options, opts}}

  @doc """
  Returns the available providers, merged as described in the module docs.

  Options:

    * `:adapters` — adapter modules; defaults to the `:tackle, :adapters`
      application environment.
    * `:accounts` — recorded accounts (`t:accounts/0`); defaults to
      `Tackle.Auth.accounts/0`.
    * `:config_providers` — provider declarations shaped like the
      `config.json` `"providers"` object; defaults to that object of the
      `config.json` found through `:env`.
    * `:env` — environment used to locate `config.json`; defaults to the
      process environment.

  Hosts that already loaded these sources should pass them explicitly.
  """
  @spec available_providers(keyword()) :: {:ok, [Provider.t()]} | {:error, term()}
  def available_providers(opts \\ []) do
    with {:ok, entries} <- provider_entries(opts) do
      {:ok, Enum.map(entries, & &1.provider)}
    end
  end

  @doc """
  Like `available_providers/1`, but keeps where each provider was first declared.

  The merged providers must offer at least one model
  (`{:error, :no_models_configured}`), and the first one is selected through
  the checks a session uses.
  """
  @spec provider_entries(keyword()) :: {:ok, [entry()]} | {:error, term()}
  def provider_entries(opts \\ [])

  def provider_entries(opts) when is_list(opts) do
    with {:ok, adapters} <- fetch_adapters(opts),
         {:ok, accounts} <- fetch_accounts(opts),
         {:ok, declarations} <- fetch_config_providers(opts),
         {:ok, entries} <- merge_providers(adapters, accounts, declarations),
         :ok <- validate_providers(Enum.map(entries, & &1.provider)) do
      {:ok, entries}
    end
  end

  def provider_entries(opts), do: {:error, {:invalid_plugin_options, opts}}

  @doc """
  Merges adapter default providers, configured provider declarations, and
  recorded accounts as described in the module docs.

  This is the pure merge behind `available_providers/1`; it does not check
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

  @doc "Returns canonical `provider_id/model` references of the available providers."
  @spec available_model_refs(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def available_model_refs(opts \\ []) do
    with {:ok, providers} <- available_providers(opts) do
      model_refs(providers)
    end
  end

  @doc """
  Returns the first canonical model reference offered by `providers`.

  Accepts providers and adapter modules, which stand for their default providers.
  """
  @spec default_model_ref([Provider.source()]) :: {:ok, String.t()} | {:error, term()}
  def default_model_ref(providers) when is_list(providers) and providers != [] do
    with {:ok, providers} <- Provider.expand(providers),
         {:ok, refs} <- model_refs(providers) do
      {:ok, hd(refs)}
    end
  end

  def default_model_ref([]), do: {:error, :no_providers_configured}
  def default_model_ref(providers), do: {:error, {:invalid_providers_configuration, providers}}

  defp fetch_adapters(opts) do
    case Keyword.get_lazy(opts, :adapters, fn -> Application.get_env(:tackle, :adapters, []) end) do
      [] -> {:error, :no_adapters_configured}
      adapters when is_list(adapters) -> {:ok, adapters}
      adapters -> {:error, {:invalid_adapters_configuration, adapters}}
    end
  end

  defp fetch_accounts(opts) do
    case Keyword.fetch(opts, :accounts) do
      {:ok, %{} = accounts} -> {:ok, accounts}
      {:ok, accounts} -> {:error, {:invalid_plugin_option, :accounts, accounts}}
      :error -> stored_accounts()
    end
  end

  defp stored_accounts do
    case Tackle.Auth.accounts() do
      {:ok, accounts} -> {:ok, accounts}
      {:error, reason} -> {:error, {:accounts_unavailable, reason}}
    end
  catch
    :exit, reason -> {:error, {:accounts_unavailable, reason}}
  end

  defp fetch_config_providers(opts) do
    case Keyword.fetch(opts, :config_providers) do
      {:ok, %{} = declarations} ->
        {:ok, declarations}

      {:ok, declarations} ->
        {:error, {:invalid_plugin_option, :config_providers, declarations}}

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

  defp account_declarations(accounts) do
    accounts
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {id, account}, {:ok, acc} ->
      if valid_account?(id, account),
        do: {:cont, {:ok, [{id, account["adapter"], account["base"]} | acc]}},
        else: {:halt, {:error, {:invalid_account, id}}}
    end)
    |> reverse_ok()
  end

  defp valid_account?(id, %{"adapter" => adapter_id} = account) do
    Provider.valid_id?(id) and is_binary(adapter_id) and
      (not Map.has_key?(account, "base") or Provider.valid_id?(account["base"]))
  end

  defp valid_account?(_id, _account), do: false

  # Declarations of adapter types this host lacks are skipped once their
  # shape is known to be valid.
  defp config_declarations(declarations, types) do
    declarations
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn
      {id, %{"adapter" => adapter_id} = entry}, {:ok, acc} when is_binary(adapter_id) ->
        cond do
          not Provider.valid_id?(id) ->
            {:halt, {:error, {:invalid_provider_id, id}}}

          Map.has_key?(types, adapter_id) ->
            settings = Map.delete(entry, "adapter")
            provider = %Provider{id: id, adapter: types[adapter_id], settings: settings}
            {:cont, {:ok, [provider | acc]}}

          true ->
            {:cont, {:ok, acc}}
        end

      {id, _entry}, _acc ->
        {:halt, {:error, {:invalid_provider_declaration, id}}}
    end)
    |> reverse_ok()
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
    with {:ok, model_ref} <- first_model_ref(providers),
         {:ok, _selection} <- LLM.select(providers, model_ref) do
      :ok
    end
  end

  defp first_model_ref(providers) do
    Enum.find_value(providers, fn provider ->
      case provider_models(provider) do
        {:ok, [model | _models]} -> {:ok, "#{provider.id}/#{model}"}
        _other -> nil
      end
    end) || {:error, :no_models_configured}
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
