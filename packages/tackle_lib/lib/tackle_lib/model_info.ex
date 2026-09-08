defmodule Tackle.Lib.ModelInfo do
  @moduledoc """
  Provider-supplied metadata for one adapter-local model.

  Model limits and price cards belong to adapters because they vary by provider
  and can change independently of the agent loop. Prices are expressed per
  `:unit_tokens` (one million by default). Tackle.Lib only validates the metadata
  and provides deterministic arithmetic for adapters that choose to estimate
  cost from normalized usage.
  """

  alias Tackle.Lib.Usage

  @type pricing :: %{
          required(:input) => number(),
          required(:output) => number(),
          required(:cache_read) => number(),
          required(:cache_write) => number(),
          required(:currency) => String.t(),
          required(:unit_tokens) => pos_integer()
        }

  @type t :: %__MODULE__{
          model: String.t(),
          context_window: pos_integer() | nil,
          max_output_tokens: pos_integer() | nil,
          pricing: pricing() | nil
        }

  @enforce_keys [:model]
  defstruct [:model, :context_window, :max_output_tokens, :pricing]

  @doc false
  @spec normalize(String.t(), t() | map() | nil) :: {:ok, t() | nil} | {:error, term()}
  def normalize(_model, nil), do: {:ok, nil}

  def normalize(model, %__MODULE__{} = info) do
    validate(%{info | model: model})
  end

  def normalize(model, %{} = info) do
    model_info = %__MODULE__{
      model: model,
      context_window: field(info, :context_window),
      max_output_tokens: field(info, :max_output_tokens),
      pricing: field(info, :pricing)
    }

    validate(model_info)
  end

  def normalize(model, info), do: {:error, {:invalid_model_info, model, info}}

  @doc """
  Adds an itemized estimated cost to one usage entry.

  Existing provider-reported numeric cost and itemization are preserved. When
  the price card supplies itemization, the breakdown is marked `estimated: true`.
  `cost_estimated: true` marks only a total derived from that price card.
  """
  @spec estimate_cost(t(), Usage.t() | map() | nil) :: Usage.t() | nil
  def estimate_cost(%__MODULE__{pricing: nil}, usage), do: Usage.normalize(usage)
  def estimate_cost(%__MODULE__{}, nil), do: nil

  def estimate_cost(%__MODULE__{pricing: pricing}, usage) do
    usage = Usage.normalize(usage)
    unit = pricing.unit_tokens

    breakdown =
      [
        input: token_cost(usage.input_tokens, pricing.input, unit),
        output: token_cost(usage.output_tokens, pricing.output, unit),
        cache_read: token_cost(usage.cache_read_tokens, pricing.cache_read, unit),
        cache_write: token_cost(usage.cache_write_tokens, pricing.cache_write, unit)
      ]
      |> Enum.reject(fn {_bucket, cost} -> is_nil(cost) end)
      |> Map.new()

    if map_size(breakdown) == 0 do
      usage
    else
      estimated_total = breakdown |> Map.values() |> Enum.sum()

      estimated_breakdown =
        breakdown |> Map.put(:total, estimated_total) |> Map.put(:estimated, true)

      if is_number(usage.cost) do
        %{
          usage
          | cost_breakdown: usage.cost_breakdown || estimated_breakdown,
            currency: usage.currency || pricing.currency
        }
      else
        %{
          usage
          | cost: estimated_total,
            cost_breakdown: estimated_breakdown,
            cost_estimated: true,
            currency: pricing.currency
        }
      end
    end
  end

  defp validate(%__MODULE__{} = info) do
    with :ok <- optional_positive_integer(info.model, :context_window, info.context_window),
         :ok <- optional_positive_integer(info.model, :max_output_tokens, info.max_output_tokens),
         :ok <- validate_output_limit(info),
         {:ok, pricing} <- normalize_pricing(info.model, info.pricing) do
      {:ok, %{info | pricing: pricing}}
    end
  end

  defp optional_positive_integer(_model, _field, nil), do: :ok

  defp optional_positive_integer(_model, _field, value) when is_integer(value) and value > 0,
    do: :ok

  defp optional_positive_integer(model, field, value),
    do: {:error, {:invalid_model_info, model, {field, value}}}

  defp validate_output_limit(%{
         model: model,
         context_window: context_window,
         max_output_tokens: max_output_tokens
       })
       when is_integer(context_window) and is_integer(max_output_tokens) and
              max_output_tokens > context_window,
       do: {:error, {:invalid_model_info, model, {:max_output_tokens, max_output_tokens}}}

  defp validate_output_limit(_info), do: :ok

  defp normalize_pricing(_model, nil), do: {:ok, nil}

  defp normalize_pricing(model, %{} = pricing) do
    normalized = %{
      input: field(pricing, :input),
      output: field(pricing, :output),
      cache_read: field(pricing, :cache_read),
      cache_write: field(pricing, :cache_write),
      currency: field(pricing, :currency) || "USD",
      unit_tokens: field(pricing, :unit_tokens) || 1_000_000
    }

    if valid_pricing?(normalized) do
      {:ok, normalized}
    else
      {:error, {:invalid_model_info, model, {:pricing, pricing}}}
    end
  end

  defp normalize_pricing(model, pricing),
    do: {:error, {:invalid_model_info, model, {:pricing, pricing}}}

  defp valid_pricing?(pricing) do
    Enum.all?(
      [:input, :output, :cache_read, :cache_write],
      &(is_number(Map.fetch!(pricing, &1)) and Map.fetch!(pricing, &1) >= 0)
    ) and is_binary(pricing.currency) and pricing.currency != "" and
      is_integer(pricing.unit_tokens) and pricing.unit_tokens > 0
  end

  defp token_cost(nil, _rate, _unit), do: nil
  defp token_cost(tokens, rate, unit), do: tokens * rate / unit

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
