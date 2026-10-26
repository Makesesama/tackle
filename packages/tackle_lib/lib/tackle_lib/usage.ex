defmodule Tackle.Lib.Usage do
  @moduledoc """
  Canonical token and cost metadata for one LLM generation step.

  Providers report usage in their own shapes: prompt or input counts that do or
  do not include cached tokens, cache buckets under different names, and money
  cost only sometimes. Adapters translate their provider's report into this
  struct, usually with `new/1`, and keep the provider's report in `:raw` for
  hosts that need auditability or richer billing. Tackle.Lib never guesses at
  provider field names.

  The input buckets are disjoint: `:input_tokens` is uncached input,
  `:cache_read_tokens` was served from cache, and `:cache_write_tokens` was
  written to cache. Total prompt volume is the sum of those three buckets. A
  provider whose prompt count includes cached tokens passes it to `new/1` as
  `:prompt_tokens`, which derives the uncached input.

  Tackle.Lib deliberately does **not** depend on pricing libraries such as
  `llm_db`. Adapters may expose price cards through the optional `model_info/1`
  callback in `Tackle.Lib.LLM`; the library applies their deterministic arithmetic
  while leaving provider facts and persistence adapter/host-owned.
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

  @type cache_reuse :: %{
          reusable_tokens: non_neg_integer(),
          reused_tokens: non_neg_integer(),
          missed_tokens: non_neg_integer(),
          rate: float()
        }

  @type t :: %__MODULE__{
          input_tokens: token_count(),
          output_tokens: token_count(),
          reasoning_tokens: token_count(),
          cache_read_tokens: token_count(),
          cache_write_tokens: token_count(),
          total_tokens: token_count(),
          cost: number() | nil,
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

  @count_fields [
    :input_tokens,
    :output_tokens,
    :reasoning_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :total_tokens
  ]

  @doc """
  Builds canonical usage from an adapter's translation of a provider report.

  `fields` are the struct's fields as a keyword list or an atom-keyed map,
  plus `:prompt_tokens`. Token counts that are not non-negative integers
  (floats are truncated) and costs that are not non-negative numbers become
  `nil`, so adapters can pass a provider's values without checking them; an
  unknown field raises `KeyError`.

  `:prompt_tokens` is for providers whose prompt count includes cache reads and
  writes, such as OpenAI's `prompt_tokens` and `input_tokens`. Unless
  `:input_tokens` is given too, the uncached input is `prompt_tokens -
  cache_read_tokens - cache_write_tokens` (at least zero). A reported
  `:total_tokens` that does not equal `prompt_tokens + output_tokens` is
  dropped, and a missing total is the sum of the input, output, cache-read,
  and cache-write buckets.

      iex> usage =
      ...>   Tackle.Lib.Usage.new(
      ...>     prompt_tokens: 120,
      ...>     cache_read_tokens: 100,
      ...>     output_tokens: 8,
      ...>     raw: %{"prompt_tokens" => 120}
      ...>   )
      iex> {usage.input_tokens, usage.cache_read_tokens, usage.total_tokens}
      {20, 100, 128}
  """
  @spec new(keyword() | map()) :: t()
  def new(fields) when is_list(fields) or is_map(fields) do
    {prompt, fields} = fields |> Map.new() |> Map.pop(:prompt_tokens)
    prompt = count(prompt)

    usage =
      __MODULE__
      |> struct!(fields)
      |> sanitize()

    usage
    |> derive_input(prompt)
    |> check_total(prompt)
    |> fill_total_tokens()
  end

  @doc """
  Normalizes canonical usage into `%Tackle.Lib.Usage{}`.

  Accepts a struct or a map with the struct's field names as atom or string
  keys, such as `to_map/1` output or a decoded journal entry; values are
  checked like `new/1` checks them and other keys are ignored. Provider-native
  reports (`prompt_tokens`, `cached_tokens`, ...) are not recognized: adapters
  translate them with `new/1`. `:model` and `:provider` in `opts` fill the
  fields when they are missing, and a missing total is derived from the
  buckets.
  """
  @spec normalize(t() | map() | nil, keyword()) :: t() | nil
  def normalize(usage, opts \\ [])

  def normalize(nil, _opts), do: nil

  def normalize(%__MODULE__{} = usage, opts) do
    # A struct built by hand can carry anything; sanitizing it keeps
    # normalize/2 total, so boundaries that promise not to raise can rely on it.
    usage = sanitize(usage)

    %{
      usage
      | model: usage.model || Keyword.get(opts, :model),
        provider: usage.provider || Keyword.get(opts, :provider)
    }
    |> fill_total_tokens()
  end

  def normalize(%{} = usage, opts) do
    fields =
      for {field, _default} <- Map.from_struct(%__MODULE__{}),
          do: {field, first_present(usage, [field, Atom.to_string(field)])}

    __MODULE__
    |> struct!(fields)
    |> normalize(opts)
  end

  @doc """
  Aggregates token and cost usage across multiple LLM generation steps.

  This is useful for deriving run/session totals from a state's `messages`
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
  Returns the cached share of total prompt volume as a ratio from `0.0` to `1.0`.

  The calculation is:
  `cache_read_tokens / (input_tokens + cache_read_tokens + cache_write_tokens)`.
  This raw share includes cold-start and newly appended content; use
  `cache_reuse_rate/1` to measure whether previously sent prompt tokens were
  actually reused. Returns `nil` when the provider did not report cache buckets
  or prompt usage is empty.
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
  Measures how much of each preceding prompt was served from cache.

  Unlike `cache_hit_rate/1`, which reports the cached share of all prompt
  volume, this compares consecutive generation checkpoints. For each reported
  checkpoint after the first, the reusable amount is the smaller of the
  previous and current prompt volumes. Cache reads are capped at that amount,
  then summed across the sequence.

  This makes naturally new conversation content neutral. For example, prompts
  of 10, 20, and 30 tokens can have a raw cache-hit rate of 50% while still
  achieving 100% reuse of every preceding prompt.

  Returns `nil` until at least one consecutive checkpoint reports cache
  buckets and has reusable prompt volume. A sequence must not span a
  compaction or any other non-append-only context rewrite, whose new prefix
  would count as a miss. To measure a conversation across rewrites, pass a
  list of sequences instead (such as `Tackle.Lib.State.usage_segments/1`):
  each is measured on its own and the totals are summed.
  """
  @spec cache_reuse([t() | map() | nil] | [[t() | map() | nil]]) :: cache_reuse() | nil
  def cache_reuse(usages) when is_list(usages) do
    {reusable_tokens, reused_tokens} =
      if usages != [] and Enum.all?(usages, &is_list/1) do
        usages
        |> Enum.map(&sequence_reuse/1)
        |> Enum.reduce({0, 0}, fn {reusable, reused}, {total_reusable, total_reused} ->
          {total_reusable + reusable, total_reused + reused}
        end)
      else
        sequence_reuse(usages)
      end

    if reusable_tokens > 0 do
      %{
        reusable_tokens: reusable_tokens,
        reused_tokens: reused_tokens,
        missed_tokens: reusable_tokens - reused_tokens,
        rate: reused_tokens / reusable_tokens
      }
    end
  end

  @doc "Returns the preceding-prompt cache reuse ratio of `cache_reuse/1`."
  @spec cache_reuse_rate([t() | map() | nil] | [[t() | map() | nil]]) :: float() | nil
  def cache_reuse_rate(usages) when is_list(usages) do
    case cache_reuse(usages) do
      %{rate: rate} -> rate
      nil -> nil
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

  defp sequence_reuse(usages) do
    {_previous_prompt, reusable_tokens, reused_tokens} =
      Enum.reduce(usages, {nil, 0, 0}, fn value, {previous_prompt, reusable, reused} ->
        usage = normalize(value)
        current_prompt = prompt_tokens(usage)

        cond do
          not is_integer(current_prompt) or current_prompt <= 0 ->
            {nil, reusable, reused}

          not is_integer(previous_prompt) ->
            {current_prompt, reusable, reused}

          not cache_buckets_reported?(usage) ->
            {current_prompt, reusable, reused}

          true ->
            current_reusable = min(previous_prompt, current_prompt)
            current_reused = min(usage.cache_read_tokens || 0, current_reusable)

            {
              current_prompt,
              reusable + current_reusable,
              reused + current_reused
            }
        end
      end)

    {reusable_tokens, reused_tokens}
  end

  defp cache_buckets_reported?(%__MODULE__{} = usage) do
    is_integer(usage.cache_read_tokens) or is_integer(usage.cache_write_tokens)
  end

  defp cache_buckets_reported?(nil), do: false

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

  defp sanitize(%__MODULE__{} = usage) do
    usage = struct!(usage, Map.new(@count_fields, &{&1, count(Map.fetch!(usage, &1))}))

    %{
      usage
      | cost: amount(usage.cost),
        cost_breakdown: normalize_cost_breakdown(usage.cost_breakdown),
        cost_estimated: normalize_boolean(usage.cost_estimated),
        currency: string(usage.currency),
        model: string(usage.model),
        provider: provider(usage.provider),
        raw: if(is_map(usage.raw), do: usage.raw)
    }
  end

  defp derive_input(%__MODULE__{input_tokens: nil} = usage, prompt) when is_integer(prompt) do
    cached = (usage.cache_read_tokens || 0) + (usage.cache_write_tokens || 0)
    %{usage | input_tokens: max(prompt - cached, 0)}
  end

  defp derive_input(usage, _prompt), do: usage

  defp check_total(%__MODULE__{total_tokens: total, output_tokens: output} = usage, prompt)
       when is_integer(total) and is_integer(output) and is_integer(prompt) and
              total != prompt + output,
       do: %{usage | total_tokens: nil}

  defp check_total(usage, _prompt), do: usage

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(value) when is_float(value) and value >= 0, do: trunc(value)
  defp count(value) when is_binary(value), do: parse_non_negative_integer(value)
  defp count(_value), do: nil

  defp amount(value) when is_number(value) and value >= 0, do: value
  defp amount(_value), do: nil

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp provider(value) when is_binary(value) or (is_atom(value) and not is_boolean(value)),
    do: value

  defp provider(_value), do: nil

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
