defmodule Tackle.Lib.Retry do
  @moduledoc """
  Provider-neutral retry policy for transient LLM failures.

  The initial provider request is not counted as a retry. Retry attempt `1`
  waits about `base_delay_ms`, and later attempts double that delay up to
  `max_delay_ms`, with jitter unless `jitter?: false` (see `delay/3`). A
  provider's `Retry-After` hint lengthens the wait.

  Only adapters' `Tackle.Lib.LLM.Error`s of a transient kind are retried
  (see `retryable?/1`); authentication, quota, context-window, invalid
  requests, cancellation, and reasons that are not `Tackle.Lib.LLM.Error`s
  never are.

  Options: `:enabled?` (default `true`), `:max_retries` (`3`),
  `:base_delay_ms` (`2_000`), `:max_delay_ms` (`60_000`), and `:jitter?`
  (`true`).
  """

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.LLM.Error

  @default_max_retries 3
  @default_base_delay_ms 2_000
  @default_max_delay_ms 60_000
  @poll_interval_ms 50
  @option_keys [:enabled?, :max_retries, :base_delay_ms, :max_delay_ms, :jitter?]
  @transient_kinds [:transport, :timeout, :rate_limited, :overloaded, :server]

  @type t :: %__MODULE__{
          enabled?: boolean(),
          max_retries: non_neg_integer(),
          base_delay_ms: non_neg_integer(),
          max_delay_ms: non_neg_integer(),
          jitter?: boolean()
        }

  defstruct enabled?: true,
            max_retries: @default_max_retries,
            base_delay_ms: @default_base_delay_ms,
            max_delay_ms: @default_max_delay_ms,
            jitter?: true

  @doc "Builds and validates a retry policy from options."
  @spec new(keyword() | t() | false | nil) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = retry), do: validate(retry)
  def new(false), do: {:ok, %{new!() | enabled?: false}}
  def new(nil), do: {:ok, new!()}

  def new(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- @option_keys do
      retry = %__MODULE__{
        enabled?: Keyword.get(opts, :enabled?, true),
        max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
        base_delay_ms: Keyword.get(opts, :base_delay_ms, @default_base_delay_ms),
        max_delay_ms: Keyword.get(opts, :max_delay_ms, @default_max_delay_ms),
        jitter?: Keyword.get(opts, :jitter?, true)
      }

      validate(retry)
    else
      false -> {:error, {:invalid_retry_config, opts}}
      unknown -> {:error, {:unknown_retry_options, Enum.uniq(unknown)}}
    end
  end

  def new(value), do: {:error, {:invalid_retry_config, value}}

  @doc "Builds and validates a retry policy, raising on invalid options."
  @spec new!(keyword() | t() | false | nil) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, retry} -> retry
      {:error, reason} -> raise ArgumentError, "invalid retry config: #{inspect(reason)}"
    end
  end

  @doc """
  Returns the delay before one-indexed retry `attempt` of a request that
  failed with `reason`.

  The backoff doubles from `base_delay_ms` and is capped at `max_delay_ms`.
  With `jitter?` (the default) it is drawn uniformly from its upper half
  ("equal jitter"), so concurrent agents that fail together do not retry in
  lockstep. When `reason` is a `Tackle.Lib.LLM.Error` with `retry_after_ms`,
  the delay is at least that long, still capped at `max_delay_ms`.
  """
  @spec delay(t(), pos_integer(), term()) :: non_neg_integer()
  def delay(%__MODULE__{} = retry, attempt, reason \\ nil)
      when is_integer(attempt) and attempt > 0 do
    backoff =
      retry.base_delay_ms
      |> Kernel.*(Integer.pow(2, min(attempt - 1, 32)))
      |> min(retry.max_delay_ms)

    backoff
    |> jitter(retry.jitter?)
    |> max(retry_after_ms(reason))
    |> min(retry.max_delay_ms)
  end

  defp jitter(backoff, false), do: backoff
  defp jitter(backoff, true) when backoff < 2, do: backoff

  defp jitter(backoff, true) do
    half = div(backoff, 2)
    backoff - half + :rand.uniform(half + 1) - 1
  end

  defp retry_after_ms(%Error{retry_after_ms: ms}) when is_integer(ms) and ms >= 0, do: ms
  defp retry_after_ms(_reason), do: 0

  @doc "Returns true when another retry is available under the policy."
  @spec available?(t() | nil, non_neg_integer()) :: boolean()
  def available?(%__MODULE__{enabled?: true, max_retries: max_retries}, retries_used),
    do: retries_used < max_retries

  def available?(_retry, _retries_used), do: false

  @doc """
  Returns true when `reason` is a transient `Tackle.Lib.LLM.Error`.

  The decision is made from the error's `kind` alone: `:transport`,
  `:timeout`, `:rate_limited`, `:overloaded`, and `:server` are retried.
  Every other kind, and any reason that is not a `Tackle.Lib.LLM.Error`, is
  not.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?(%Error{kind: kind}), do: kind in @transient_kinds
  def retryable?(_reason), do: false

  @doc "Waits for a retry delay while polling a cooperative cancellation signal."
  @spec wait(non_neg_integer(), Cancellation.signal() | nil) ::
          :ok | {:cancelled, Cancellation.reason()}
  def wait(delay_ms, signal) when is_integer(delay_ms) and delay_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + delay_ms
    wait_until(deadline, signal)
  end

  defp validate(%__MODULE__{} = retry) do
    with :ok <- validate_boolean(:enabled?, retry.enabled?),
         :ok <- validate_non_negative(:max_retries, retry.max_retries),
         :ok <- validate_non_negative(:base_delay_ms, retry.base_delay_ms),
         :ok <- validate_non_negative(:max_delay_ms, retry.max_delay_ms),
         :ok <- validate_boolean(:jitter?, retry.jitter?) do
      {:ok, retry}
    end
  end

  defp validate_boolean(_field, value) when is_boolean(value), do: :ok
  defp validate_boolean(field, value), do: invalid(field, value)

  defp validate_non_negative(_field, value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative(field, value), do: invalid(field, value)

  defp invalid(field, value), do: {:error, {:invalid_retry_config, {field, value}}}

  defp wait_until(deadline, signal) do
    case Cancellation.reason(signal) do
      nil ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          :ok
        else
          Process.sleep(min(remaining, @poll_interval_ms))
          wait_until(deadline, signal)
        end

      reason ->
        {:cancelled, reason}
    end
  end
end
