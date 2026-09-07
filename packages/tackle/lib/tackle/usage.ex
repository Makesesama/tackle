defmodule Tackle.Usage do
  @moduledoc """
  Normalized token and cost metadata for one LLM generation step.

  Providers vary a lot here: some return only prompt/completion token counts,
  some include reasoning/cache buckets, and many do not return money cost at all.
  Tackle therefore normalizes the token dimensions it knows about while keeping
  cost optional and preserving the original provider payload in `:raw` for host
  applications that need auditability or richer billing.

  Tackle deliberately does **not** depend on pricing libraries such as
  `llm_db`. Price cards, currency policy, credit conversion, and persistence are
  host-application concerns. Hosts can calculate cost in their adapter or
  persistence layer and place it in `:cost` / `:currency` when available.
  """

  @type token_count :: non_neg_integer() | nil

  @type t :: %__MODULE__{
          input_tokens: token_count(),
          output_tokens: token_count(),
          reasoning_tokens: token_count(),
          cache_read_tokens: token_count(),
          cache_write_tokens: token_count(),
          total_tokens: token_count(),
          cost: term() | nil,
          currency: String.t() | nil,
          model: String.t() | nil,
          provider: String.t() | atom() | nil,
          raw: map() | nil
        }

  defstruct input_tokens: nil,
            output_tokens: nil,
            reasoning_tokens: nil,
            cache_read_tokens: nil,
            cache_write_tokens: nil,
            total_tokens: nil,
            cost: nil,
            currency: nil,
            model: nil,
            provider: nil,
            raw: nil

  @doc """
  Normalizes provider-specific usage metadata into `%Tackle.Usage{}`.

  Accepts an existing `%Tackle.Usage{}`, atom-keyed maps, and string-keyed maps.
  Unknown fields are not discarded; the original map is retained in `:raw`.
  """
  @spec normalize(t() | map() | nil, keyword()) :: t() | nil
  def normalize(usage, opts \\ [])

  def normalize(nil, _opts), do: nil

  def normalize(%__MODULE__{} = usage, opts) do
    %{
      usage
      | model: usage.model || Keyword.get(opts, :model),
        provider: usage.provider || Keyword.get(opts, :provider)
    }
    |> fill_total_tokens()
  end

  def normalize(%{} = usage, opts) do
    %__MODULE__{
      input_tokens:
        first_integer(usage, [
          :input_tokens,
          :prompt_tokens,
          :input,
          "input_tokens",
          "prompt_tokens",
          "input"
        ]),
      output_tokens:
        first_integer(usage, [
          :output_tokens,
          :completion_tokens,
          :output,
          "output_tokens",
          "completion_tokens",
          "output"
        ]),
      reasoning_tokens:
        first_integer(usage, [:reasoning_tokens, :reasoning, "reasoning_tokens", "reasoning"]),
      cache_read_tokens:
        first_integer(usage, [
          :cache_read_tokens,
          :cache_read,
          :cached_input_tokens,
          "cache_read_tokens",
          "cache_read",
          "cached_input_tokens"
        ]),
      cache_write_tokens:
        first_integer(usage, [
          :cache_write_tokens,
          :cache_write,
          :cache_creation_input_tokens,
          "cache_write_tokens",
          "cache_write",
          "cache_creation_input_tokens"
        ]),
      total_tokens: first_integer(usage, [:total_tokens, :total, "total_tokens", "total"]),
      cost: first_present(usage, [:cost, :total_cost, "cost", "total_cost"]),
      currency: first_present(usage, [:currency, "currency"]),
      model: first_present(usage, [:model, "model"]) || Keyword.get(opts, :model),
      provider: first_present(usage, [:provider, "provider"]) || Keyword.get(opts, :provider),
      raw: usage
    }
    |> fill_total_tokens()
  end

  @doc """
  Aggregates token and cost usage across multiple LLM generation steps.

  This is useful for deriving run/session totals from `Tackle.State.messages/1`
  without storing a second mutable counter. Token fields are summed field-by-field.

  Cost is intentionally conservative: it is summed only when every usage entry
  has a numeric cost and all non-nil currencies are the same. If any entry lacks
  cost, uses a non-numeric cost representation, or mixes currencies, aggregate
  cost is returned as `nil`.
  """
  @spec aggregate([t() | map() | nil]) :: t()
  def aggregate(usages) when is_list(usages) do
    normalized = usages |> Enum.map(&normalize/1) |> Enum.reject(&is_nil/1)

    %__MODULE__{
      input_tokens: sum_token_field(normalized, :input_tokens),
      output_tokens: sum_token_field(normalized, :output_tokens),
      reasoning_tokens: sum_token_field(normalized, :reasoning_tokens),
      cache_read_tokens: sum_token_field(normalized, :cache_read_tokens),
      cache_write_tokens: sum_token_field(normalized, :cache_write_tokens),
      total_tokens: sum_token_field(normalized, :total_tokens),
      cost: aggregate_cost(normalized),
      currency: aggregate_currency(normalized)
    }
  end

  @doc """
  Converts a usage struct to a plain map without nil values.
  """
  @spec to_map(t() | nil) :: map() | nil
  def to_map(nil), do: nil

  def to_map(%__MODULE__{} = usage) do
    usage
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp sum_token_field(usages, field) do
    usages
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      counts -> Enum.sum(counts)
    end
  end

  defp aggregate_cost([]), do: nil

  defp aggregate_cost(usages) do
    costs = Enum.map(usages, & &1.cost)

    if Enum.all?(costs, &is_number/1) && compatible_currencies?(usages) do
      Enum.sum(costs)
    end
  end

  defp aggregate_currency(usages) do
    usages
    |> Enum.map(& &1.currency)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [currency] -> currency
      _ -> nil
    end
  end

  defp compatible_currencies?(usages) do
    usages
    |> Enum.map(& &1.currency)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length()
    |> Kernel.<=(1)
  end

  defp fill_total_tokens(%__MODULE__{total_tokens: total} = usage) when is_integer(total),
    do: usage

  defp fill_total_tokens(%__MODULE__{} = usage) do
    total =
      [usage.input_tokens, usage.output_tokens]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        counts -> Enum.sum(counts)
      end

    %{usage | total_tokens: total}
  end

  defp first_integer(map, keys) do
    case first_present(map, keys) do
      value when is_integer(value) and value >= 0 -> value
      value when is_float(value) and value >= 0 -> trunc(value)
      value when is_binary(value) -> parse_non_negative_integer(value)
      _ -> nil
    end
  end

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} when not is_nil(value) -> value
        _ -> nil
      end
    end)
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> nil
    end
  end
end
