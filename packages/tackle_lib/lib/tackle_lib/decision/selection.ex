defmodule Tackle.Lib.Decision.Selection do
  @moduledoc """
  An immutable decision adapter and model selection.

  Selections are created through `Tackle.Lib.Decision.select/2`. The
  adapter-local `model` is sent in each request, while `ref` preserves the
  canonical `adapter_id/model` identifier for configuration and auditing.
  """

  alias Tackle.Lib.LLM.Selection, as: LLMSelection

  @enforce_keys [:adapter, :adapter_id, :model, :ref]
  defstruct [:adapter, :adapter_id, :model, :ref]

  @type t :: %__MODULE__{
          adapter: module(),
          adapter_id: String.t(),
          model: String.t(),
          ref: String.t()
        }

  @decision_callbacks [decision_models: 0, decide: 2]

  @doc false
  @spec resolve([module()], String.t()) :: {:ok, t()} | {:error, term()}
  def resolve(adapters, model_ref) when is_list(adapters) and is_binary(model_ref) do
    with {:ok, {adapter_id, model}} <- LLMSelection.parse_model_ref(model_ref),
         {:ok, adapter_index} <- LLMSelection.index_adapters(adapters, adapter_id: 0),
         {:ok, adapter} <- fetch_adapter(adapter_index, adapter_id),
         :ok <- ensure_decision_adapter(adapter, adapter_id),
         {:ok, models} <- decision_models(adapter, adapter_id),
         :ok <- ensure_model(models, model_ref, model) do
      {:ok, %__MODULE__{adapter: adapter, adapter_id: adapter_id, model: model, ref: model_ref}}
    end
  end

  def resolve(_adapters, model_ref), do: {:error, {:invalid_model_ref, model_ref}}

  defp fetch_adapter(adapter_index, adapter_id) do
    case Map.fetch(adapter_index, adapter_id) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, {:unknown_adapter, adapter_id}}
    end
  end

  defp ensure_decision_adapter(adapter, adapter_id) do
    if Enum.all?(@decision_callbacks, fn {name, arity} ->
         function_exported?(adapter, name, arity)
       end),
       do: :ok,
       else: {:error, {:unsupported_decision_adapter, adapter_id}}
  end

  defp decision_models(adapter, adapter_id) do
    with {:ok, models} <- LLMSelection.adapter_callback(adapter, :decision_models) do
      LLMSelection.validate_models(models, adapter_id)
    end
  end

  defp ensure_model(models, model_ref, model) do
    if model in models, do: :ok, else: {:error, {:unknown_decision_model, model_ref}}
  end
end
