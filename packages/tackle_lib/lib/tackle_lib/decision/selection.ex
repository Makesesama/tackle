defmodule Tackle.Lib.Decision.Selection do
  @moduledoc """
  An immutable decision provider and model selection.

  Selections are created through `Tackle.Lib.Decision.select/2`. The
  adapter-local `model` is sent in each request, while `ref` preserves the
  canonical `provider_id/model` identifier for configuration and auditing.
  `local` is `true` when the provider declares its decision models local
  through the optional `Tackle.Lib.Decision.local?/1` or `local?/0` callback.
  """

  alias Tackle.Lib.LLM.Provider
  alias Tackle.Lib.LLM.Selection, as: LLMSelection

  @enforce_keys [:adapter, :provider_id, :model, :ref]
  defstruct [:adapter, :provider_id, :model, :ref, provider_settings: %{}, local: false]

  @type t :: %__MODULE__{
          adapter: module(),
          provider_id: String.t(),
          provider_settings: Provider.settings(),
          model: String.t(),
          ref: String.t(),
          local: boolean()
        }

  @doc false
  @spec resolve([Provider.source()], String.t()) :: {:ok, t()} | {:error, term()}
  def resolve(sources, model_ref) when is_list(sources) and is_binary(model_ref) do
    with {:ok, {provider_id, model}} <- LLMSelection.parse_model_ref(model_ref),
         {:ok, index} <- LLMSelection.index_providers(sources, &Provider.ensure_loaded/1),
         {:ok, provider} <- LLMSelection.fetch_provider(index, provider_id),
         :ok <- ensure_decision_adapter(provider),
         {:ok, models} <- Provider.decision_models(provider),
         :ok <- ensure_model(models, model_ref, model),
         {:ok, local} <- Provider.local?(provider) do
      {:ok,
       %__MODULE__{
         adapter: provider.adapter,
         provider_id: provider_id,
         provider_settings: provider.settings,
         model: model,
         ref: model_ref,
         local: local
       }}
    end
  end

  def resolve(_sources, model_ref), do: {:error, {:invalid_model_ref, model_ref}}

  # Providers are expanded before validation, which already loads every
  # adapter and requires `adapter_id/0`; non-decision adapters may be listed.

  defp ensure_decision_adapter(%Provider{adapter: adapter, id: id}) do
    if Tackle.Lib.Decision.decision_adapter?(adapter),
      do: :ok,
      else: {:error, {:unsupported_decision_adapter, id}}
  end

  defp ensure_model(models, model_ref, model) do
    if model in models, do: :ok, else: {:error, {:unknown_decision_model, model_ref}}
  end
end
