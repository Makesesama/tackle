defmodule Tackle.Lib.LLM.Provider do
  @moduledoc """
  A configured instance of an LLM adapter.

  An adapter module implements a provider protocol once; a provider is one
  configured use of it. Several providers may share an adapter, each with its
  own id, settings, and credentials, such as a local and a cloud Ollama server,
  or two Codex subscriptions:

      {:ok, work} = Provider.new("codex-work", MyApp.Codex)
      {:ok, home} = Provider.new("codex-home", MyApp.Codex)

      Tackle.Lib.LLM.select([work, home], "codex-home/gpt-5.5")

  The provider id is the model-reference prefix and the credential namespace.
  The adapter's `adapter_id/0` only names the adapter type.

  ## Default providers

  Selection functions accept bare adapter modules as well as providers. A bare
  module expands to its default providers: those returned by the optional
  `default_providers/0` callback, or else one provider whose id is the
  adapter's `adapter_id/0` with empty settings.

  ## Settings

  Settings are an opaque, JSON-compatible map with string keys. Tackle.Lib
  never interprets them; it passes them to the adapter as
  `opts[:provider_settings]` together with `opts[:provider_id]`, and to the
  instance-aware versions of the optional catalog callbacks, which take
  precedence over their arity-zero versions: `models/1` and `model_info/2`
  of `Tackle.Lib.LLM`, and, for adapters that also implement
  `Tackle.Lib.Decision`, its `decision_models/1` and `local?/1`.

  Adapters read conventional settings with the helpers below:
  `string_setting/3`, `put_base_url/2` (`"base_url"`), and `api_key/3`
  (`"api_key_env"`).
  """

  alias Tackle.Lib.CredentialStore

  @enforce_keys [:id, :adapter]
  defstruct [:id, :adapter, settings: %{}]

  @type settings :: %{optional(String.t()) => term()}

  @type t :: %__MODULE__{id: String.t(), adapter: module(), settings: settings()}

  @typedoc "A provider, or an adapter module standing for its default providers."
  @type source :: t() | module()

  @id_pattern ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/

  @doc """
  Builds a provider after validating its id and settings.

  Ids are lowercase letters, digits, and inner hyphens. The adapter is not
  loaded or checked here; selection validates the callbacks it needs.
  """
  @spec new(String.t(), module(), settings()) :: {:ok, t()} | {:error, term()}
  def new(id, adapter, settings \\ %{}) do
    cond do
      not valid_id?(id) ->
        {:error, {:invalid_provider_id, id}}

      not is_atom(adapter) or is_nil(adapter) ->
        {:error, {:invalid_adapter, adapter, :not_a_module}}

      not is_map(settings) ->
        {:error, {:invalid_provider_settings, id, settings}}

      true ->
        {:ok, %__MODULE__{id: id, adapter: adapter, settings: settings}}
    end
  end

  @doc "Returns true when `id` is a valid provider id."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id), do: is_binary(id) and Regex.match?(@id_pattern, id)

  @doc """
  Returns an adapter's default providers.

  The adapter must export `adapter_id/0`. `default_providers/0`, when exported,
  must return a non-empty list of `{id, settings}` tuples.
  """
  @spec defaults(module()) :: {:ok, [t()]} | {:error, term()}
  def defaults(adapter) when is_atom(adapter) and not is_nil(adapter) do
    with {:ok, adapter_id} <- adapter_id(adapter) do
      if function_exported?(adapter, :default_providers, 0) do
        default_providers(adapter)
      else
        {:ok, [%__MODULE__{id: adapter_id, adapter: adapter, settings: %{}}]}
      end
    end
  end

  def defaults(adapter), do: {:error, {:invalid_adapter, adapter, :not_a_module}}

  @doc """
  Returns an adapter's type id, its `adapter_id/0`.

  The adapter is loaded and must export `adapter_id/0` returning a valid id
  (see `valid_id?/1`). A callback that raises, throws, or exits is
  `{:error, {:adapter_callback_failed, adapter, :adapter_id, detail}}`.
  """
  @spec adapter_id(module()) :: {:ok, String.t()} | {:error, term()}
  def adapter_id(adapter) when is_atom(adapter) and not is_nil(adapter) do
    with :ok <- ensure_loaded(adapter),
         :ok <- ensure_exported(adapter, :adapter_id, 0),
         {:ok, adapter_id} <- call(adapter, :adapter_id, []),
         :ok <- validate_adapter_id(adapter_id) do
      {:ok, adapter_id}
    end
  end

  def adapter_id(adapter), do: {:error, {:invalid_adapter, adapter, :not_a_module}}

  @doc """
  Expands providers and adapter modules into providers with unique ids.

  Order is preserved; a module contributes its default providers in place.
  """
  @spec expand([source()]) :: {:ok, [t()]} | {:error, term()}
  def expand(sources) when is_list(sources) do
    sources
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn source, {:ok, acc, seen} ->
      with {:ok, providers} <- from_source(source),
           {:ok, seen} <- track_ids(providers, seen) do
        {:cont, {:ok, Enum.reverse(providers, acc), seen}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, providers, _seen} -> {:ok, Enum.reverse(providers)}
      {:error, reason} -> {:error, reason}
    end
  end

  def expand(sources), do: {:error, {:invalid_providers, sources}}

  @doc """
  Returns the validated chat models of one provider: `models/1` with its
  settings, else `models/0`.

  The list may be empty; its entries must be unique, non-empty, trimmed
  strings. Errors: `{:invalid_models, id, value}` for a value that is not a
  list, `{:invalid_model_id, id, model}`, `{:duplicate_model_id, id, model}`,
  `{:invalid_adapter, adapter, reason}` for an adapter that cannot be loaded
  or exports neither callback, and `{:adapter_callback_failed, adapter,
  :models, detail}`.
  """
  @spec models(t()) :: {:ok, [String.t()]} | {:error, term()}
  def models(%__MODULE__{} = provider) do
    with {:ok, models} <- instance_call(provider, :models) do
      validate_models(models, provider.id)
    end
  end

  @doc "Returns the validated decision models of one provider."
  @spec decision_models(t()) :: {:ok, [String.t()]} | {:error, term()}
  def decision_models(%__MODULE__{} = provider) do
    with {:ok, models} <- instance_call(provider, :decision_models) do
      validate_models(models, provider.id)
    end
  end

  @doc """
  Whether the provider's decision models run on hardware the user controls.

  Adapters without `local?/1` or `local?/0` are remote.
  """
  @spec local?(t()) :: {:ok, boolean()} | {:error, term()}
  def local?(%__MODULE__{adapter: adapter} = provider) do
    with :ok <- ensure_loaded(adapter) do
      local_flag(provider)
    end
  end

  defp local_flag(%__MODULE__{adapter: adapter} = provider) do
    if function_exported?(adapter, :local?, 1) or function_exported?(adapter, :local?, 0) do
      case instance_call(provider, :local?) do
        {:ok, local} when is_boolean(local) -> {:ok, local}
        {:ok, other} -> {:error, {:invalid_local_flag, provider.id, other}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, false}
    end
  end

  @doc "The adapter options that identify a provider: `:provider_id` and `:provider_settings`."
  @spec opts(t()) :: keyword()
  def opts(%__MODULE__{id: id, settings: settings}),
    do: [provider_id: id, provider_settings: settings]

  @doc """
  Reads the provider id an adapter was called with, or `default`.

  Adapters use it as their credential namespace so each provider keeps its
  own login.
  """
  @spec id(keyword(), String.t()) :: String.t()
  def id(opts, default) when is_list(opts) and is_binary(default) do
    case Keyword.get(opts, :provider_id) do
      id when is_binary(id) and id != "" -> id
      _missing -> default
    end
  end

  @doc "Reads the provider settings an adapter was called with, or `%{}`."
  @spec settings(keyword()) :: settings()
  def settings(opts) when is_list(opts) do
    case Keyword.get(opts, :provider_settings) do
      %{} = settings -> settings
      _missing -> %{}
    end
  end

  @doc """
  Reads a string setting of the provider an adapter was called with.

  Returns `{:ok, nil}` when the setting is absent and `{:ok, value}` for a
  non-empty string. Any other value is
  `{:error, {:invalid_provider_setting, provider_id, key, value}}`, where the
  provider id is `opts[:provider_id]`, else `default_id`.
  """
  @spec string_setting(keyword(), String.t(), String.t()) ::
          {:ok, String.t() | nil}
          | {:error, {:invalid_provider_setting, String.t(), String.t(), term()}}
  def string_setting(opts, key, default_id) when is_binary(key) and is_binary(default_id) do
    case Map.fetch(settings(opts), key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_provider_setting, id(opts, default_id), key, value}}
      :error -> {:ok, nil}
    end
  end

  @doc """
  Puts the provider's `"base_url"` setting into `opts[:base_url]`.

  An explicit `:base_url` option wins over the setting. Without either,
  `opts` is returned unchanged and the adapter uses its default URL. An
  invalid setting is an error (see `string_setting/3`).
  """
  @spec put_base_url(keyword(), String.t()) :: {:ok, keyword()} | {:error, term()}
  def put_base_url(opts, default_id) when is_list(opts) do
    case string_setting(opts, "base_url", default_id) do
      {:ok, nil} -> {:ok, opts}
      {:ok, url} -> {:ok, Keyword.put_new(opts, :base_url, url)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Looks up the API key of the provider an adapter was called with.

  The first key found wins:

    1. `opts[:api_key]`;
    2. the `"api_key"` (or `"key"`) entry of the credentials stored in the
       provider's namespace of `opts[:credential_store]` (see
       `Tackle.Lib.CredentialStore.from_opts/1`);
    3. the environment variable named by the provider's `"api_key_env"`
       setting, or `default_env` for the default provider (`default_id`)
       only, so another provider never picks up that key by accident.

  Keys are trimmed, and a blank key counts as none. A trimmed key with
  spaces, control characters, or other bytes outside printable ASCII is
  `{:error, :invalid_api_key}`, rejected before it reaches a request (an HTTP
  client would raise with the header in its error). Returns `:error` when no
  source has a key; adapters turn it into their own "missing key" error.
  Credential-store failures and invalid settings are errors.
  """
  @spec api_key(keyword(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | :error | {:error, term()}
  def api_key(opts, default_id, default_env \\ nil)
      when is_list(opts) and is_binary(default_id) and
             (is_binary(default_env) or is_nil(default_env)) do
    with :error <- normalize_api_key(Keyword.get(opts, :api_key)),
         :error <- stored_api_key(opts, id(opts, default_id)) do
      environment_api_key(opts, default_id, default_env)
    end
  end

  defp stored_api_key(opts, provider_id) do
    with {:ok, handle} <- CredentialStore.from_opts(opts),
         {:ok, credentials} <- CredentialStore.fetch(handle, provider_id) do
      key =
        Map.get(credentials, "api_key") || Map.get(credentials, :api_key) ||
          Map.get(credentials, "key") || Map.get(credentials, :key)

      normalize_api_key(key)
    end
  end

  defp environment_api_key(opts, default_id, default_env) do
    case string_setting(opts, "api_key_env", default_id) do
      {:ok, nil} ->
        if id(opts, default_id) == default_id and default_env,
          do: env_api_key(default_env),
          else: :error

      {:ok, name} ->
        env_api_key(name)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp env_api_key(name), do: name |> System.get_env() |> normalize_api_key()

  defp normalize_api_key(key) when is_binary(key) do
    case String.trim(key) do
      "" -> :error
      key -> if header_safe?(key), do: {:ok, key}, else: {:error, :invalid_api_key}
    end
  end

  defp normalize_api_key(_missing), do: :error

  defp header_safe?(value), do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x21..0x7E))

  defp validate_models(models, provider_id) when is_list(models) do
    Enum.reduce_while(models, {:ok, MapSet.new()}, fn model, {:ok, seen} ->
      cond do
        not valid_model?(model) ->
          {:halt, {:error, {:invalid_model_id, provider_id, model}}}

        MapSet.member?(seen, model) ->
          {:halt, {:error, {:duplicate_model_id, provider_id, model}}}

        true ->
          {:cont, {:ok, MapSet.put(seen, model)}}
      end
    end)
    |> case do
      {:ok, _seen} -> {:ok, models}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_models(models, provider_id),
    do: {:error, {:invalid_models, provider_id, models}}

  # Calls the arity-one instance callback with the provider settings when the
  # adapter exports it, else the arity-zero callback.
  defp instance_call(%__MODULE__{adapter: adapter, settings: settings}, callback) do
    with :ok <- ensure_loaded(adapter) do
      cond do
        function_exported?(adapter, callback, 1) -> call(adapter, callback, [settings])
        function_exported?(adapter, callback, 0) -> call(adapter, callback, [])
        true -> {:error, {:invalid_adapter, adapter, {:missing_callback, {callback, 0}}}}
      end
    end
  end

  defp call(adapter, callback, args) do
    {:ok, apply(adapter, callback, args)}
  rescue
    exception ->
      {:error, {:adapter_callback_failed, adapter, callback, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:adapter_callback_failed, adapter, callback, {kind, reason}}}
  end

  # Prefers the instance-aware `model_info/2`, like the other callbacks.
  @doc false
  @spec model_info(module(), settings(), String.t()) :: {:ok, term()} | {:error, term()}
  def model_info(adapter, settings, model) do
    with :ok <- ensure_loaded(adapter) do
      cond do
        function_exported?(adapter, :model_info, 2) ->
          call(adapter, :model_info, [model, settings])

        function_exported?(adapter, :model_info, 1) ->
          call(adapter, :model_info, [model])

        true ->
          {:ok, nil}
      end
    end
  end

  defp from_source(%__MODULE__{id: id, adapter: adapter, settings: settings} = provider) do
    with {:ok, _provider} <- new(id, adapter, settings), do: {:ok, [provider]}
  end

  defp from_source(adapter), do: defaults(adapter)

  defp track_ids(providers, seen) do
    Enum.reduce_while(providers, {:ok, seen}, fn %__MODULE__{id: id}, {:ok, seen} ->
      if MapSet.member?(seen, id),
        do: {:halt, {:error, {:duplicate_provider_id, id}}},
        else: {:cont, {:ok, MapSet.put(seen, id)}}
    end)
  end

  defp default_providers(adapter) do
    case call(adapter, :default_providers, []) do
      {:ok, [_ | _] = entries} -> build_defaults(adapter, entries)
      {:ok, other} -> {:error, {:invalid_default_providers, adapter, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_defaults(adapter, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn
      {id, settings}, {:ok, acc} ->
        case new(id, adapter, settings) do
          {:ok, provider} -> {:cont, {:ok, [provider | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      other, _acc ->
        {:halt, {:error, {:invalid_default_providers, adapter, other}}}
    end)
    |> case do
      {:ok, providers} -> {:ok, Enum.reverse(providers)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The adapter checks `Tackle.Lib.LLM`, `Tackle.Lib.LLM.Selection`, and
  # `Tackle.Lib.Decision.Selection` share, so every one reports a broken
  # adapter as `{:invalid_adapter, adapter, reason}`.

  @doc false
  @spec ensure_loaded(module()) :: :ok | {:error, {:invalid_adapter, module(), term()}}
  def ensure_loaded(adapter) do
    case Code.ensure_loaded(adapter) do
      {:module, ^adapter} -> :ok
      {:error, reason} -> {:error, {:invalid_adapter, adapter, {:not_loaded, reason}}}
    end
  end

  # An adapter generates, streams, or both; `Tackle.Lib.LLM` calls the one it
  # has.
  @doc false
  @spec ensure_generates(module()) :: :ok | {:error, {:invalid_adapter, module(), term()}}
  def ensure_generates(adapter) do
    if function_exported?(adapter, :generate, 2) or function_exported?(adapter, :stream, 3),
      do: :ok,
      else: {:error, {:invalid_adapter, adapter, {:missing_callback, {:generate, 2}}}}
  end

  # Requires one of `arities` of a callback, reporting the last as missing.
  @doc false
  @spec ensure_exported(module(), atom(), non_neg_integer() | [non_neg_integer()]) ::
          :ok | {:error, {:invalid_adapter, module(), term()}}
  def ensure_exported(adapter, name, arities) do
    arities = List.wrap(arities)

    if Enum.any?(arities, &function_exported?(adapter, name, &1)),
      do: :ok,
      else: {:error, {:invalid_adapter, adapter, {:missing_callback, {name, List.last(arities)}}}}
  end

  defp validate_adapter_id(adapter_id) do
    if valid_id?(adapter_id), do: :ok, else: {:error, {:invalid_adapter_id, adapter_id}}
  end

  defp valid_model?(model),
    do: is_binary(model) and model != "" and model == String.trim(model)
end
