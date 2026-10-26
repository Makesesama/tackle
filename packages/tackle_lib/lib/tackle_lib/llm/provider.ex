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
  optional instance-aware callbacks `models/1`, `model_info/2`,
  `decision_models/1`, and `local?/1`, which take precedence over their
  arity-zero versions.
  """

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
    with :ok <- ensure_loaded(adapter),
         :ok <- ensure_exported(adapter, :adapter_id, 0),
         {:ok, adapter_id} <- call(adapter, :adapter_id, []),
         :ok <- validate_adapter_id(adapter_id) do
      if function_exported?(adapter, :default_providers, 0) do
        default_providers(adapter)
      else
        {:ok, [%__MODULE__{id: adapter_id, adapter: adapter, settings: %{}}]}
      end
    end
  end

  def defaults(adapter), do: {:error, {:invalid_adapter, adapter, :not_a_module}}

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

  @doc "Returns the validated chat models of one provider."
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

  @doc false
  @spec validate_models(term(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def validate_models(models, provider_id) when is_list(models) do
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

  def validate_models(models, provider_id),
    do: {:error, {:invalid_models, provider_id, models}}

  @doc false
  # Calls the arity-one instance callback with the provider settings when the
  # adapter exports it, else the arity-zero callback.
  @spec instance_call(t(), atom()) :: {:ok, term()} | {:error, term()}
  def instance_call(%__MODULE__{adapter: adapter, settings: settings}, callback) do
    with :ok <- ensure_loaded(adapter) do
      cond do
        function_exported?(adapter, callback, 1) -> call(adapter, callback, [settings])
        function_exported?(adapter, callback, 0) -> call(adapter, callback, [])
        true -> {:error, {:invalid_adapter, adapter, {:missing_callback, {callback, 0}}}}
      end
    end
  end

  @doc false
  @spec call(module(), atom(), list()) :: {:ok, term()} | {:error, term()}
  def call(adapter, callback, args) do
    {:ok, apply(adapter, callback, args)}
  rescue
    exception ->
      {:error, {:adapter_callback_failed, adapter, callback, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:adapter_callback_failed, adapter, callback, {kind, reason}}}
  end

  @doc false
  @spec model_info(t(), String.t()) :: {:ok, term()} | {:error, term()}
  def model_info(%__MODULE__{adapter: adapter, settings: settings}, model),
    do: model_info(adapter, settings, model)

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

  defp ensure_loaded(adapter) do
    case Code.ensure_loaded(adapter) do
      {:module, ^adapter} -> :ok
      {:error, reason} -> {:error, {:invalid_adapter, adapter, {:not_loaded, reason}}}
    end
  end

  defp ensure_exported(adapter, name, arity) do
    if function_exported?(adapter, name, arity),
      do: :ok,
      else: {:error, {:invalid_adapter, adapter, {:missing_callback, {name, arity}}}}
  end

  defp validate_adapter_id(adapter_id) do
    if valid_id?(adapter_id), do: :ok, else: {:error, {:invalid_adapter_id, adapter_id}}
  end

  defp valid_model?(model),
    do: is_binary(model) and model != "" and model == String.trim(model)
end
