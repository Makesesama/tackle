defmodule Tackle.Lib.Compaction.Policy do
  @moduledoc """
  Provider-neutral trigger and reserve arithmetic for context compaction.

  A policy is pure configuration: it holds no state and performs no provider
  calls. `resolve/3` combines a policy with one model's declared limits and
  the request around the conversation to produce the concrete numbers a
  compaction decision needs:

      response_reserve = policy.response_reserve
                         || the request's :max_tokens
                         || min(max_output_tokens || 8,192, policy.max_response_reserve)
                         (at most half the window; max_response_reserve defaults to 32,768)
      safety_reserve   = policy.safety_reserve (default 4,096)
      hard_safe_limit  = context_window - response_reserve - safety_reserve
      attention_limit  = floor(context_window * policy.attention_ratio)
      trigger_at       = min(hard_safe_limit, attention_limit)

      summary_max_tokens = policy.summary_max_tokens ||
                           min(max_output_tokens || 8,192, 8,192)
      max_retained_tokens = trigger_at - fixed_tokens - summary_max_tokens
      retain_tokens    = min(policy.retain_tokens ||
                               clamp(floor(context_window * retain_ratio), 4,096, 20,000),
                             max_retained_tokens / 2)

  The response reserve is what the next request can actually ask for. A model
  card's `max_output_tokens` is the most a request may ask for, which can be
  half the window (Codex models declare 128,000 of 272,000), so without an
  explicit request limit it is capped at `max_response_reserve`.

  The hybrid threshold keeps both output capacity and attention quality in
  view: `hard_safe_limit` reserves room for the next assistant response, while
  `attention_limit` compacts before the window is genuinely full.

  `fixed_tokens` is the part of every request that compaction cannot shrink:
  the system prompt, the tool definitions, and the checkpoint's own framing.
  A compaction leaves that, the summary, and the retained tail, so the tail
  must stay under `max_retained_tokens` for the result to land below
  `trigger_at`. The retention target is held to half of it, so a compaction
  leaves room for the conversation to grow before the next one.

  A window is *usable* when `trigger_at` exceeds `fixed_tokens` plus
  `summary_max_tokens`, so a compaction can get below the threshold at all.
  Automatic pressure compaction is skipped for windows that are not (manual
  and overflow compaction may still run, keeping the unclamped retention
  target). Callers must not silently assume a context window when the adapter
  does not declare one.
  """

  alias Tackle.Lib.ModelInfo

  @default_response_reserve 8_192
  @default_max_response_reserve 32_768
  @default_max_summary_tokens 8_192

  @type t :: %__MODULE__{
          response_reserve: pos_integer() | nil,
          max_response_reserve: pos_integer(),
          safety_reserve: non_neg_integer(),
          attention_ratio: float(),
          retain_tokens: pos_integer() | nil,
          retain_ratio: float(),
          min_retain_tokens: pos_integer(),
          max_retain_tokens: pos_integer(),
          summary_max_tokens: pos_integer() | nil,
          max_summary_tokens: pos_integer(),
          overflow_retry_limit: non_neg_integer()
        }

  @type resolved :: %{
          context_window: pos_integer(),
          response_reserve: pos_integer(),
          safety_reserve: non_neg_integer(),
          hard_safe_limit: non_neg_integer(),
          attention_limit: non_neg_integer(),
          trigger_at: non_neg_integer(),
          fixed_tokens: non_neg_integer(),
          retain_tokens: non_neg_integer(),
          max_retained_tokens: non_neg_integer() | nil,
          summary_max_tokens: pos_integer(),
          overflow_retry_limit: non_neg_integer(),
          usable?: boolean()
        }

  @enforce_keys []
  defstruct response_reserve: nil,
            max_response_reserve: @default_max_response_reserve,
            safety_reserve: 4_096,
            attention_ratio: 0.80,
            retain_tokens: nil,
            retain_ratio: 0.16,
            min_retain_tokens: 4_096,
            max_retain_tokens: 20_000,
            summary_max_tokens: nil,
            max_summary_tokens: @default_max_summary_tokens,
            overflow_retry_limit: 1

  @doc "Builds and validates a policy from options."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    policy = struct(__MODULE__, opts)

    with :ok <- optional_positive_integer(:response_reserve, policy.response_reserve),
         :ok <- positive_integer(:max_response_reserve, policy.max_response_reserve),
         :ok <- non_negative_integer(:safety_reserve, policy.safety_reserve),
         :ok <- ratio(:attention_ratio, policy.attention_ratio),
         :ok <- optional_positive_integer(:retain_tokens, policy.retain_tokens),
         :ok <- ratio(:retain_ratio, policy.retain_ratio),
         :ok <- positive_integer(:min_retain_tokens, policy.min_retain_tokens),
         :ok <- positive_integer(:max_retain_tokens, policy.max_retain_tokens),
         :ok <- optional_positive_integer(:summary_max_tokens, policy.summary_max_tokens),
         :ok <- positive_integer(:max_summary_tokens, policy.max_summary_tokens),
         :ok <- non_negative_integer(:overflow_retry_limit, policy.overflow_retry_limit),
         :ok <- ordered_retention(policy) do
      {:ok, policy}
    end
  end

  def new(opts), do: {:error, {:invalid_policy, opts}}

  @doc "Builds and validates a policy, raising on invalid options."
  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid compaction policy: #{inspect(reason)}"
    end
  end

  @doc """
  Resolves concrete trigger and reserve numbers against one model's limits.

  ## Options

    * `:fixed_tokens` - the estimated tokens of the request parts compaction
      cannot shrink: system prompt, tool definitions, and checkpoint framing
      (default 0).
    * `:max_tokens` - the output limit the conversation's requests ask for,
      or `nil` when they set none.

  `max_retained_tokens` is `nil` for a window that is not usable.
  """
  @spec resolve(t(), ModelInfo.t() | nil, keyword()) :: {:ok, resolved()} | {:error, term()}
  def resolve(policy, info, opts \\ [])

  def resolve(%__MODULE__{} = policy, %ModelInfo{context_window: window} = info, opts)
      when is_integer(window) and window > 0 do
    fixed_tokens = Keyword.get(opts, :fixed_tokens, 0)
    response_reserve = min(response_reserve(policy, info, opts), div(window, 2))
    safety_reserve = policy.safety_reserve
    hard_safe_limit = max(window - response_reserve - safety_reserve, 0)
    attention_limit = trunc(Float.floor(window * policy.attention_ratio))
    trigger_at = min(hard_safe_limit, attention_limit)

    summary_max_tokens =
      policy.summary_max_tokens ||
        min(info.max_output_tokens || policy.max_summary_tokens, policy.max_summary_tokens)

    retain_target =
      policy.retain_tokens ||
        window
        |> Kernel.*(policy.retain_ratio)
        |> Float.floor()
        |> trunc()
        |> clamp(policy.min_retain_tokens, policy.max_retain_tokens)
        |> min(window)

    headroom = trigger_at - fixed_tokens - summary_max_tokens
    usable? = trigger_at > 0 and headroom > 0

    {retain_tokens, max_retained_tokens} =
      if usable?,
        do: {min(retain_target, div(headroom, 2)), headroom},
        else: {retain_target, nil}

    {:ok,
     %{
       context_window: window,
       response_reserve: response_reserve,
       safety_reserve: safety_reserve,
       hard_safe_limit: hard_safe_limit,
       attention_limit: attention_limit,
       trigger_at: trigger_at,
       fixed_tokens: fixed_tokens,
       retain_tokens: retain_tokens,
       max_retained_tokens: max_retained_tokens,
       summary_max_tokens: summary_max_tokens,
       overflow_retry_limit: policy.overflow_retry_limit,
       usable?: usable?
     }}
  end

  def resolve(%__MODULE__{}, _info, _opts), do: {:error, :no_context_window}

  @doc "Returns true when `tokens` has reached the resolved pressure threshold."
  @spec pressure?(resolved(), non_neg_integer() | nil) :: boolean()
  def pressure?(%{usable?: true, trigger_at: trigger_at}, tokens) when is_integer(tokens),
    do: tokens >= trigger_at

  def pressure?(_resolved, _tokens), do: false

  defp response_reserve(%__MODULE__{response_reserve: reserve}, _info, _opts)
       when is_integer(reserve),
       do: reserve

  defp response_reserve(%__MODULE__{} = policy, %ModelInfo{} = info, opts) do
    case Keyword.get(opts, :max_tokens) do
      max_tokens when is_integer(max_tokens) and max_tokens > 0 ->
        max_tokens

      _unset ->
        min(info.max_output_tokens || @default_response_reserve, policy.max_response_reserve)
    end
  end

  defp ordered_retention(%{min_retain_tokens: min, max_retain_tokens: max}) when max >= min,
    do: :ok

  defp ordered_retention(%{min_retain_tokens: min, max_retain_tokens: max}),
    do: {:error, {:invalid_policy, {:retain_bounds, min, max}}}

  defp optional_positive_integer(_field, nil), do: :ok
  defp optional_positive_integer(field, value), do: positive_integer(field, value)

  defp positive_integer(_field, value) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(field, value), do: {:error, {:invalid_policy, {field, value}}}

  defp non_negative_integer(_field, value) when is_integer(value) and value >= 0, do: :ok
  defp non_negative_integer(field, value), do: {:error, {:invalid_policy, {field, value}}}

  defp ratio(_field, value) when is_float(value) and value > 0.0 and value <= 1.0, do: :ok
  defp ratio(field, value), do: {:error, {:invalid_policy, {field, value}}}

  defp clamp(value, min, max), do: value |> Kernel.max(min) |> Kernel.min(max)
end
