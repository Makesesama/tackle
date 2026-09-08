defmodule Tackle.Lib.Usage do
  @moduledoc """
  Normalized token and cost metadata for one LLM generation step.

  Providers vary a lot here: some return only prompt/completion token counts,
  some include reasoning/cache buckets, and many do not return money cost at all.
  Tackle.Lib therefore normalizes the token dimensions it knows about while keeping
  cost optional and preserving the original provider payload in `:raw` for host
  applications that need auditability or richer billing.

  The normalized input buckets are disjoint: `:input_tokens` is uncached input,
  `:cache_read_tokens` was served from cache, and `:cache_write_tokens` was written
  to cache. Total prompt volume is the sum of those three buckets.

  Tackle.Lib deliberately does **not** depend on pricing libraries such as
  `llm_db`. Adapters may expose price cards through `Tackle.Lib.LLM.model_info/1`;
  the library applies their deterministic arithmetic while leaving provider
  facts and persistence adapter/host-owned.
  """

  @type token_count :: non_neg_integer() | nil
  @type cost_breakdown :: %{
          optional(:input) => number(),
          optional(:output) => number(),
          optional(:cache_read) => number(),
          optional(:cache_write) => number(),
          optional(:total) => number(),
          optional(:estimated) => boolean()
        }

  @type t :: %__MODULE__{
          input_tokens: token_count(),
          output_tokens: token_count(),
          reasoning_tokens: token_count(),
          cache_read_tokens: token_count(),
          cache_write_tokens: token_count(),
          total_tokens: token_count(),
          cost: term() | nil,
          cost_breakdown: cost_breakdown() | nil,
          cost_estimated: boolean() | nil,
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
            cost_breakdown: nil,
            cost_estimated: nil,
            currency: nil,
            model: nil,
            provider: nil,
            raw: nil

  @doc """
  Normalizes provider-specific usage metadata into `%Tackle.Lib.Usage{}`.

  Accepts an existing `%Tackle.Lib.Usage{}`, atom-keyed maps, and string-keyed maps.
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
      cost_breakdown:
        normalize_cost_breakdown(first_present(usage, [:cost_breakdown, "cost_breakdown"])),
      cost_estimated:
        normalize_boolean(first_present(usage, [:cost_estimated, "cost_estimated"])),
      currency: first_present(usage, [:currency, "currency"]),
      model: first_present(usage, [:model, "model"]) || Keyword.get(opts, :model),
      provider: first_present(usage, [:provider, "provider"]) || Keyword.get(opts, :provider),
      raw: usage
    }
    |> fill_total_tokens()
  end

  @doc """
  Aggregates token and cost usage across multiple LLM generation steps.

  This is useful for deriving run/session totals from `Tackle.Lib.State.messages/1`
  without storing a second mutable counter. Token fields are summed field-by-field.

  Cost is intentionally conservative: it is summed only when every usage entry
  has a numeric cost and all non-nil currencies are the same. If any entry lacks
  cost, uses a non-numeric cost representation, or mixes currencies, aggregate
  cost is returned as `nil`. An aggregate containing any estimated generation is
  itself marked estimated.
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
      cost_breakdown: aggregate_cost_breakdown(normalized),
      cost_estimated: aggregate_cost_estimated(normalized),
      currency: aggregate_currency(normalized)
    }
  end

  @doc """
  Returns total prompt-token volume across uncached input, cache reads, and cache writes.
  """
  @spec prompt_tokens(t() | map() | nil) :: non_neg_integer() | nil
  def prompt_tokens(usage) do
    case normalize(usage) do
      nil ->
        nil

      %__MODULE__{} = usage ->
        sum_if_present([
          usage.input_tokens,
          usage.cache_read_tokens,
          usage.cache_write_tokens
        ])
    end
  end

  @doc """
  Returns the context tokens represented by one provider usage checkpoint.

  A provider's `:total_tokens` is preferred. Otherwise the value is derived
  from input, output, cache-read, and cache-write buckets, matching Pi's context
  calculation.
  """
  @spec context_tokens(t() | map() | nil) :: non_neg_integer() | nil
  def context_tokens(usage) do
    case normalize(usage) do
      %__MODULE__{total_tokens: total} when is_integer(total) -> total
      _unavailable -> nil
    end
  end

  @doc """
  Returns the token-weighted prompt cache hit rate as a ratio from `0.0` to `1.0`.

  The calculation matches Pi's cache-hit metric:
  `cache_read_tokens / (input_tokens + cache_read_tokens + cache_write_tokens)`.
  Returns `nil` when the provider did not report cache buckets or prompt usage is
  empty, so unsupported cache reporting is not presented as a zero-percent hit.
  """
  @spec cache_hit_rate(t() | map() | nil) :: float() | nil
  def cache_hit_rate(usage) do
    case normalize(usage) do
      %__MODULE__{cache_read_tokens: cache_read, cache_write_tokens: cache_write} = usage
      when is_integer(cache_read) or is_integer(cache_write) ->
        case prompt_tokens(usage) do
          prompt_tokens when is_integer(prompt_tokens) and prompt_tokens > 0 ->
            (cache_read || 0) / prompt_tokens

          _empty ->
            nil
        end

      _unreported ->
        nil
    end
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
    |> sum_if_present()
  end

  defp sum_if_present(counts) do
    counts
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      present -> Enum.sum(present)
    end
  end

  defp aggregate_cost([]), do: nil

  defp aggregate_cost(usages) do
    costs = Enum.map(usages, & &1.cost)

    if Enum.all?(costs, &is_number/1) && compatible_currencies?(usages) do
      Enum.sum(costs)
    end
  end

  defp aggregate_cost_breakdown([]), do: nil

  defp aggregate_cost_breakdown(usages) do
    breakdowns = Enum.map(usages, & &1.cost_breakdown)

    if Enum.all?(breakdowns, &is_map/1) && compatible_currencies?(usages) do
      amounts =
        [:input, :output, :cache_read, :cache_write, :total]
        |> Map.new(fn field ->
          values = Enum.map(breakdowns, &Map.get(&1, field))
          {field, if(Enum.all?(values, &is_number/1), do: Enum.sum(values), else: nil)}
        end)
        |> Enum.reject(fn {_field, value} -> is_nil(value) end)
        |> Map.new()

      if Enum.any?(breakdowns, &(&1[:estimated] == true)),
        do: Map.put(amounts, :estimated, true),
        else: amounts
    end
  end

  defp aggregate_cost_estimated([]), do: nil

  defp aggregate_cost_estimated(usages) do
    if Enum.all?(usages, &is_number(&1.cost)) and compatible_currencies?(usages) do
      Enum.any?(usages, &(&1.cost_estimated == true))
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
      sum_if_present([
        usage.input_tokens,
        usage.output_tokens,
        usage.cache_read_tokens,
        usage.cache_write_tokens
      ])

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

  defp normalize_cost_breakdown(%{} = breakdown) do
    amounts =
      [:input, :output, :cache_read, :cache_write, :total]
      |> Enum.reduce(%{}, fn field, normalized ->
        case first_present(breakdown, [field, Atom.to_string(field)]) do
          amount when is_number(amount) -> Map.put(normalized, field, amount)
          _unavailable -> normalized
        end
      end)

    if map_size(amounts) == 0 do
      nil
    else
      case first_present(breakdown, [:estimated, "estimated"]) do
        estimated when is_boolean(estimated) -> Map.put(amounts, :estimated, estimated)
        _unavailable -> amounts
      end
    end
  end

  defp normalize_cost_breakdown(_breakdown), do: nil

  defp normalize_boolean(value) when is_boolean(value), do: value
  defp normalize_boolean(_value), do: nil

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> nil
    end
  end
end
