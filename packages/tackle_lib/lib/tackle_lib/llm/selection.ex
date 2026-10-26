defmodule Tackle.Lib.LLM.Selection do
  @moduledoc """
  An immutable provider and model selection.

  Selections are created through `Tackle.Lib.LLM.select/2`. The adapter-local
  `model` is passed to the selected adapter together with the provider's id
  and settings, while `ref` preserves the canonical `provider_id/model`
  identifier for configuration and auditing.
  """

  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Provider

  @enforce_keys [:adapter, :provider_id, :model, :ref]
  defstruct [:adapter, :provider_id, :model, :ref, :model_info, provider_settings: %{}]

  @type t :: %__MODULE__{
          adapter: module(),
          provider_id: String.t(),
          provider_settings: Provider.settings(),
          model: String.t(),
          ref: String.t(),
          model_info: Tackle.Lib.ModelInfo.t() | nil
        }

  @doc false
  @spec resolve([Provider.source()], String.t()) :: {:ok, t()} | {:error, term()}
  def resolve(sources, model_ref) when is_list(sources) and is_binary(model_ref) do
    with {:ok, {provider_id, model}} <- parse_model_ref(model_ref),
         {:ok, index} <- index_providers(sources, &validate_chat_adapter/1),
         {:ok, provider} <- fetch_provider(index, provider_id),
         {:ok, models} <- Provider.models(provider),
         :ok <- ensure_model(models, provider_id, model),
         {:ok, model_info} <- LLM.model_info(provider, model) do
      {:ok,
       %__MODULE__{
         adapter: provider.adapter,
         provider_id: provider_id,
         provider_settings: provider.settings,
         model: model,
         ref: model_ref,
         model_info: model_info
       }}
    end
  end

  def resolve(_sources, model_ref), do: {:error, {:invalid_model_ref, model_ref}}

  @doc "Returns the provider a selection was resolved from."
  @spec provider(t()) :: Provider.t()
  def provider(%__MODULE__{} = selection) do
    %Provider{
      id: selection.provider_id,
      adapter: selection.adapter,
      settings: selection.provider_settings
    }
  end

  # The helpers below are shared with `Tackle.Lib.Decision.Selection` so both
  # selections parse references and index providers identically.

  @doc false
  @spec parse_model_ref(String.t()) :: {:ok, {String.t(), String.t()}} | {:error, term()}
  def parse_model_ref(model_ref) do
    case String.split(model_ref, "/", parts: 2) do
      [provider_id, model] when model != "" ->
        if valid_provider_id?(provider_id) and model == String.trim(model) do
          {:ok, {provider_id, model}}
        else
          {:error, {:invalid_model_ref, model_ref}}
        end

      _ ->
        {:error, {:invalid_model_ref, model_ref}}
    end
  end

  @doc false
  @spec index_providers([Provider.source()], (module() -> :ok | {:error, term()})) ::
          {:ok, %{String.t() => Provider.t()}} | {:error, term()}
  def index_providers(sources, validate_adapter) when is_list(sources) do
    with {:ok, providers} <- Provider.expand(sources),
         :ok <- validate_adapters(providers, validate_adapter) do
      {:ok, Map.new(providers, &{&1.id, &1})}
    end
  end

  def index_providers(sources, _validate_adapter), do: {:error, {:invalid_providers, sources}}

  @doc false
  @spec fetch_provider(%{String.t() => Provider.t()}, String.t()) ::
          {:ok, Provider.t()} | {:error, term()}
  def fetch_provider(index, provider_id) do
    case Map.fetch(index, provider_id) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, {:unknown_provider, provider_id}}
    end
  end

  defp validate_adapters(providers, validate_adapter) do
    providers
    |> Enum.map(& &1.adapter)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn adapter, :ok ->
      case validate_adapter.(adapter) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_chat_adapter(adapter) do
    with {:module, ^adapter} <- Code.ensure_loaded(adapter),
         :ok <- require_generation(adapter),
         :ok <- require_callback(adapter, :adapter_id, [0]) do
      require_callback(adapter, :models, [1, 0])
    else
      {:error, {:invalid_adapter, _adapter, _reason}} = error -> error
      {:error, reason} -> {:error, {:invalid_adapter, adapter, {:not_loaded, reason}}}
    end
  end

  # An adapter generates, streams, or both; `Tackle.Lib.LLM` calls the one
  # it has.
  defp require_generation(adapter) do
    if function_exported?(adapter, :generate, 2) or function_exported?(adapter, :stream, 3),
      do: :ok,
      else: {:error, {:invalid_adapter, adapter, {:missing_callback, {:generate, 2}}}}
  end

  defp require_callback(adapter, name, arities) do
    if Enum.any?(arities, &function_exported?(adapter, name, &1)),
      do: :ok,
      else: {:error, {:invalid_adapter, adapter, {:missing_callback, {name, List.last(arities)}}}}
  end

  defp valid_provider_id?(provider_id), do: Provider.valid_id?(provider_id)

  defp ensure_model(models, provider_id, model) do
    if model in models,
      do: :ok,
      else: {:error, {:unknown_model, "#{provider_id}/#{model}"}}
  end
end
