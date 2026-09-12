defmodule Tackle.Lib.Retry do
  @moduledoc """
  Provider-neutral retry policy for transient LLM failures.

  The initial provider request is not counted as a retry. Retry attempt `1`
  waits `base_delay_ms`, and later attempts double that delay up to
  `max_delay_ms`. Unknown, authentication, quota/billing, cancellation, and
  context-window errors are never classified as transient.
  """

  alias Tackle.Lib.Cancellation

  @default_max_retries 3
  @default_base_delay_ms 2_000
  @default_max_delay_ms 60_000
  @poll_interval_ms 50
  @option_keys [:enabled?, :max_retries, :base_delay_ms, :max_delay_ms]

  @type t :: %__MODULE__{
          enabled?: boolean(),
          max_retries: non_neg_integer(),
          base_delay_ms: non_neg_integer(),
          max_delay_ms: non_neg_integer()
        }

  defstruct enabled?: true,
            max_retries: @default_max_retries,
            base_delay_ms: @default_base_delay_ms,
            max_delay_ms: @default_max_delay_ms

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
        max_delay_ms: Keyword.get(opts, :max_delay_ms, @default_max_delay_ms)
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

  @doc "Returns the deterministic capped backoff for a one-indexed retry attempt."
  @spec delay(t(), pos_integer()) :: non_neg_integer()
  def delay(%__MODULE__{} = retry, attempt) when is_integer(attempt) and attempt > 0 do
    retry.base_delay_ms
    |> Kernel.*(Integer.pow(2, attempt - 1))
    |> min(retry.max_delay_ms)
  end

  @doc "Returns true when another retry is available under the policy."
  @spec available?(t() | nil, non_neg_integer()) :: boolean()
  def available?(%__MODULE__{enabled?: true, max_retries: max_retries}, retries_used),
    do: retries_used < max_retries

  def available?(_retry, _retries_used), do: false

  @doc "Classifies a provider or transport failure as transient."
  @spec retryable?(term()) :: boolean()
  def retryable?(reason) do
    text = error_text(reason)

    cond do
      permanent_reason?(reason) -> false
      permanent_http_status?(reason) -> false
      permanent_text?(text) -> false
      transient_http_status?(reason) -> true
      transient_transport?(reason) -> true
      true -> transient_text?(text)
    end
  end

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
         :ok <- validate_non_negative(:max_delay_ms, retry.max_delay_ms) do
      {:ok, retry}
    end
  end

  defp validate_boolean(_field, value) when is_boolean(value), do: :ok
  defp validate_boolean(field, value), do: invalid(field, value)

  defp validate_non_negative(_field, value) when is_integer(value) and value >= 0, do: :ok
  defp validate_non_negative(field, value), do: invalid(field, value)

  defp invalid(field, value), do: {:error, {:invalid_retry_config, {field, value}}}

  defp permanent_http_status?({:http_error, status, _body}) when is_integer(status),
    do: status >= 400 and status < 500 and not transient_status?(status)

  defp permanent_http_status?({:websocket_transport_failed, _phase, reason}),
    do: permanent_http_status?(reason)

  defp permanent_http_status?({:request_failed, reason}), do: permanent_http_status?(reason)
  defp permanent_http_status?(_reason), do: false

  defp permanent_reason?(reason) when reason in [:cancelled, :canceled, :aborted, :abort],
    do: true

  defp permanent_reason?({:request_failed, reason}), do: permanent_reason?(reason)

  defp permanent_reason?({:websocket_transport_failed, _phase, reason}),
    do: permanent_reason?(reason)

  defp permanent_reason?(_reason), do: false

  defp transient_http_status?({:http_error, status, _body}), do: transient_status?(status)

  defp transient_http_status?({:websocket_transport_failed, _phase, reason}),
    do: transient_http_status?(reason)

  defp transient_http_status?({:request_failed, reason}), do: transient_http_status?(reason)
  defp transient_http_status?(_reason), do: false

  defp transient_status?(status), do: status in [408, 425, 429, 500, 502, 503, 504, 524]

  defp transient_transport?({:request_failed, reason}), do: transient_transport?(reason)

  defp transient_transport?({:websocket_transport_failed, _phase, reason}),
    do: transient_transport?(reason)

  defp transient_transport?({kind, reason}) when kind in [:error, :exit],
    do: transient_transport?(reason)

  defp transient_transport?(reason)
       when reason in [
              :timeout,
              :receive_timeout,
              :connection_refused,
              :connection_closed,
              :connection_lost,
              :closed,
              :econnrefused,
              :econnreset,
              :enetdown,
              :enetunreach,
              :ehostunreach,
              :nxdomain,
              :eai_again
            ],
       do: true

  defp transient_transport?(_reason), do: false

  defp permanent_text?(text) do
    Regex.match?(
      ~r/context[_ -]?window|authentication|unauthori[sz]ed|forbidden|invalid[_ -]?api[_ -]?key|insufficient[_ -]?quota|\bquota\b|out of (?:budget|credits?)|(?:budget|credits?) exhausted|billing|usage limit|cancel(?:led|ed)/i,
      text
    )
  end

  defp transient_text?(text) do
    Regex.match?(
      ~r/overload|rate.?limit|too many requests|\b(?:429|500|502|503|504|524)\b|service.?unavailable|server.?error|internal.?error|provider.?returned.?error|network.?error|connection.?(?:error|refused|lost|closed)|other side closed|fetch failed|getaddrinfo|enotfound|eai_again|upstream.?connect|reset before headers|socket hang up|socket connection was closed|timed? out|timeout|terminated|websocket.?(?:closed|error)|ended without|stream ended before|http2 request did not get a response|retry delay|(?:please|can) retry your request|resourceexhausted/i,
      text
    )
  end

  defp error_text(reason), do: inspect(reason, limit: :infinity, printable_limit: 20_000)

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
