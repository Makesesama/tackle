defmodule Tackle.Lib.LLM.Error do
  @moduledoc """
  A provider or transport failure, as adapters report it.

  Adapters return `{:error, %Tackle.Lib.LLM.Error{}}` whenever a provider
  request fails: an HTTP error response, a transport failure, or an error the
  provider reports inside a stream. The agent loop decides from the struct
  alone whether to retry (`Tackle.Lib.Retry.retryable?/1`), how long to wait
  (`:retry_after_ms`), and whether to compact and ask again
  (`Tackle.Lib.LLM.context_window_exceeded?/1`); it never inspects provider
  wording. Failures that are not provider failures, such as missing
  credentials, an invalid model, or cancellation, stay plain reasons.

  ## Fields

    * `:kind` - what failed, one of:
      * `:transport` - the connection failed, closed, or the stream ended early
      * `:timeout` - the provider or the connection did not answer in time
      * `:rate_limited` - the provider asked to slow down (HTTP 429)
      * `:overloaded` - the provider is over capacity (HTTP 503, 529)
      * `:server` - another provider-side failure (other 5xx)
      * `:context_window_exceeded` - the request does not fit the model's context
      * `:quota_exceeded` - credits, billing, or plan usage are exhausted
      * `:auth` - the credentials were rejected (HTTP 401, 403)
      * `:invalid_request` - the provider refused the request (other 4xx)
      * `:invalid_response` - the provider's answer could not be used
      * `:unknown` - a failure the adapter could not classify

      Only `:transport`, `:timeout`, `:rate_limited`, `:overloaded`, and
      `:server` are transient.
    * `:status` - the HTTP status, or `nil`.
    * `:retry_after_ms` - how long the provider asked to wait before retrying,
      from `Retry-After` or `retry-after-ms`, or `nil`.
    * `:message` - a human-readable, single-line description that hosts may
      show. It may quote the provider's error message.
    * `:details` - the raw failure (a decoded or bounded response body, a
      provider error object, or a transport reason) for logs and diagnostics.
      Hosts should not show it to users verbatim.

  It is an exception, so `Exception.message/1` returns `:message` and adapters
  or hosts may raise it.

  ## Constructors

  Adapters share the classification instead of keeping their own:

    * `from_response/3` - an HTTP error response (status, body, headers)
    * `from_transport/1` - a transport failure, such as `Req.TransportError`
      or `Mint.TransportError`
    * `from_caught/2` - a failure caught around an HTTP client call
    * `from_stream/1` - an error object reported inside a stream
    * `new/2` - any other kind, with an explicit message

  Context overflow is recognized by one shared list of provider phrases
  (`overflow_message?/1`), and only in a response's error code and message,
  never in echoed request content.
  """

  @kinds [
    :transport,
    :timeout,
    :rate_limited,
    :overloaded,
    :server,
    :context_window_exceeded,
    :quota_exceeded,
    :auth,
    :invalid_request,
    :invalid_response,
    :unknown
  ]

  @type kind ::
          :transport
          | :timeout
          | :rate_limited
          | :overloaded
          | :server
          | :context_window_exceeded
          | :quota_exceeded
          | :auth
          | :invalid_request
          | :invalid_response
          | :unknown

  @type t :: %__MODULE__{
          kind: kind(),
          status: pos_integer() | nil,
          retry_after_ms: non_neg_integer() | nil,
          message: String.t(),
          details: term()
        }

  defexception kind: :unknown, status: nil, retry_after_ms: nil, message: nil, details: nil

  # Phrases providers use for a request that does not fit the context window.
  # They are matched, lowercased, against error codes and messages only.
  @overflow_markers [
    "context_length_exceeded",
    "context_window_exceeded",
    "maximum context length",
    "maximum allowed input length",
    "exceeds the context window",
    "exceeds the context length",
    "exceeds the maximum number of tokens",
    "exceed context limit",
    "prompt is too long",
    "input is too long",
    "too many tokens",
    "reduce the length of the messages"
  ]

  # Error codes and types that name exhausted credits or plan usage. A 429 with
  # one of them will not succeed on retry.
  @quota_codes [
    "insufficient_quota",
    "quota_exceeded",
    "usage_limit_reached",
    "billing_hard_limit_reached",
    "insufficient_balance",
    "insufficient_credits",
    "billing_error"
  ]

  @rate_limit_codes [
    "rate_limit_exceeded",
    "rate_limit_error",
    "rate_limited",
    "too_many_requests",
    "resource_exhausted"
  ]
  @overloaded_codes ["overloaded_error", "overloaded", "server_overloaded", "service_unavailable"]
  @server_codes ["server_error", "api_error", "internal_error", "internal_server_error"]
  @auth_codes [
    "authentication_error",
    "permission_error",
    "invalid_api_key",
    "unauthorized",
    "forbidden"
  ]
  @invalid_request_codes ["invalid_request_error", "invalid_prompt", "bad_request"]
  @timeout_codes ["timeout", "timeout_error", "request_timeout"]

  @timeout_reasons [:timeout, :receive_timeout, :connect_timeout, :checkout_timeout]

  @max_message_length 500
  @max_body_bytes 16_384

  @doc "The error kinds, in the order documented above."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Builds an error of `kind`.

  Options: `:message` (defaults to a description of the kind), `:status`,
  `:retry_after_ms`, and `:details`.
  """
  @spec new(kind(), keyword()) :: t()
  def new(kind, opts \\ []) when kind in @kinds and is_list(opts) do
    %__MODULE__{
      kind: kind,
      status: Keyword.get(opts, :status),
      retry_after_ms: Keyword.get(opts, :retry_after_ms),
      message: Keyword.get(opts, :message) || describe(kind, Keyword.get(opts, :status)),
      details: Keyword.get(opts, :details)
    }
  end

  @impl true
  def message(%__MODULE__{message: message}) when is_binary(message), do: message
  def message(%__MODULE__{kind: kind, status: status}), do: describe(kind, status)

  @doc """
  Classifies an HTTP error response.

  `body` may be decoded JSON or raw text; a JSON text body is decoded and a
  long one is bounded. `headers` may be a Req-style map of lists or a list of
  pairs; `Retry-After` and `retry-after-ms` set `:retry_after_ms`.

  A 400, 413, or 422 whose error code or message names a context limit is
  `:context_window_exceeded`; a quota or billing code, or 402, is
  `:quota_exceeded`; 401 and 403 are `:auth`; 408, 504, and 524 are
  `:timeout`; 429 is `:rate_limited`; 503 and 529 are `:overloaded`; other
  5xx are `:server`; other 4xx are `:invalid_request`.
  """
  @spec from_response(integer(), term(), map() | [{term(), term()}] | nil) :: t()
  def from_response(status, body, headers \\ []) when is_integer(status) do
    body = normalize_body(body)
    error = error_object(body)
    kind = status_kind(status, error)

    new(kind,
      status: status,
      retry_after_ms: retry_after_ms(headers || []),
      message: with_provider_message(describe(kind, status), error_message(error)),
      details: body
    )
  end

  @doc """
  Classifies a failure to complete an HTTP exchange.

  Accepts `Req.TransportError`, `Mint.TransportError`, other exceptions an
  HTTP client returns, POSIX-style atoms such as `:econnrefused`, and
  `{:exit, reason}`. Timeouts are `:timeout`; everything else is `:transport`.
  """
  @spec from_transport(term()) :: t()
  def from_transport(%__MODULE__{} = error), do: error

  def from_transport(reason) do
    kind = if timeout_reason?(reason), do: :timeout, else: :transport

    new(kind,
      message: with_provider_message(describe(kind, nil), transport_message(reason)),
      details: reason
    )
  end

  @doc """
  Classifies a failure caught (`catch kind, reason`) around an HTTP client call.

  An exit, such as a connection pool's checkout timeout, is a transport
  failure (`from_transport/1`); a raised error or a throw is `:unknown`, so a
  bug or an invalid request option is never retried.
  """
  @spec from_caught(:error | :exit | :throw, term()) :: t()
  def from_caught(:exit, reason), do: from_transport({:exit, reason})

  def from_caught(:error, reason) do
    exception = Exception.normalize(:error, reason)

    new(:unknown,
      message: with_provider_message(describe(:unknown, nil), Exception.message(exception)),
      details: exception
    )
  end

  def from_caught(:throw, reason), do: new(:unknown, details: {:throw, reason})

  @doc """
  Classifies an error a provider reports inside a stream.

  `error` is the provider's error object, such as an OpenAI-style
  `%{"code" => ..., "message" => ...}`, an Anthropic-style
  `%{"type" => "overloaded_error", ...}`, an object wrapping one under
  `"error"` (with the upstream `"status"` and `"headers"` some providers
  relay beside it), or a bare message. Its code, type, or numeric status
  decides the kind; overflow phrases in its code or message make it
  `:context_window_exceeded`. Anything else is `:unknown`.
  """
  @spec from_stream(term()) :: t()
  def from_stream(error) do
    object = error_object(error)
    codes = error_codes(object)
    status = numeric_code(object) || numeric_code(error)

    kind =
      cond do
        overflow_message?(object) -> :context_window_exceeded
        is_integer(status) -> status_kind(status, object)
        true -> code_kind(codes) || :unknown
      end

    new(kind,
      status: status,
      retry_after_ms: stream_retry_after_ms(error),
      message: with_provider_message(describe(kind, status), error_message(object)),
      details: error
    )
  end

  # Some providers relay the HTTP status and headers of an upstream failure
  # alongside the error object.
  defp stream_retry_after_ms(%{"headers" => headers}) when is_map(headers) or is_list(headers),
    do: retry_after_ms(headers)

  defp stream_retry_after_ms(_error), do: nil

  @doc """
  Returns true when an error object or text names a context-window overflow.

  Only codes, types, messages, and relayed upstream messages
  (`metadata.raw`) are searched, so request content a provider echoes back
  cannot trigger it.
  """
  @spec overflow_message?(term()) :: boolean()
  def overflow_message?(error) do
    error
    |> error_object()
    |> overflow_texts()
    |> Enum.any?(fn text ->
      downcased = String.downcase(text)
      Enum.any?(@overflow_markers, &String.contains?(downcased, &1))
    end)
  end

  @doc """
  Returns the wait a response's headers ask for, in milliseconds, or `nil`.

  Reads `retry-after-ms` (milliseconds), then `Retry-After` as seconds or an
  HTTP date (IMF-fixdate), relative to `now`. A date in the past is `0`.
  """
  @spec retry_after_ms(map() | [{term(), term()}], DateTime.t()) :: non_neg_integer() | nil
  def retry_after_ms(headers, now \\ DateTime.utc_now()) do
    case header(headers, "retry-after-ms") |> parse_number() do
      ms when is_number(ms) and ms >= 0 ->
        ceil(ms)

      _other ->
        case header(headers, "retry-after") do
          nil -> nil
          value -> parse_retry_after(value, now)
        end
    end
  end

  # ── Classification ────────────────────────────────────────────────────

  defp status_kind(status, error) when status in [400, 413, 422] do
    cond do
      overflow_message?(error) -> :context_window_exceeded
      quota?(error) -> :quota_exceeded
      true -> :invalid_request
    end
  end

  defp status_kind(402, _error), do: :quota_exceeded
  defp status_kind(status, _error) when status in [401, 403], do: :auth
  defp status_kind(status, _error) when status in [408, 504, 524], do: :timeout

  defp status_kind(429, error),
    do: if(quota?(error), do: :quota_exceeded, else: :rate_limited)

  defp status_kind(status, _error) when status in [503, 529], do: :overloaded

  defp status_kind(status, error) when status in 500..599,
    do: if(code_kind(error_codes(error)) == :overloaded, do: :overloaded, else: :server)

  defp status_kind(status, error) when status in 400..499,
    do: if(quota?(error), do: :quota_exceeded, else: :invalid_request)

  defp status_kind(_status, _error), do: :invalid_response

  defp quota?(error), do: Enum.any?(error_codes(error), &(&1 in @quota_codes))

  defp code_kind(codes) do
    Enum.find_value(codes, fn code ->
      cond do
        code in @quota_codes -> :quota_exceeded
        code in @rate_limit_codes -> :rate_limited
        code in @overloaded_codes -> :overloaded
        code in @server_codes -> :server
        code in @auth_codes -> :auth
        code in @timeout_codes -> :timeout
        code in @invalid_request_codes -> :invalid_request
        true -> nil
      end
    end)
  end

  defp timeout_reason?(%{__exception__: true, reason: reason}), do: timeout_reason?(reason)
  defp timeout_reason?({:exit, reason}), do: timeout_reason?(reason)
  defp timeout_reason?({:timeout, _detail}), do: true
  defp timeout_reason?(reason) when reason in @timeout_reasons, do: true
  defp timeout_reason?(_reason), do: false

  # ── Error objects ─────────────────────────────────────────────────────

  defp normalize_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, %{} = decoded} -> decoded
      _other -> bounded(body)
    end
  end

  defp normalize_body(body), do: body

  defp bounded(body) when byte_size(body) <= @max_body_bytes, do: body
  defp bounded(body), do: binary_part(body, 0, @max_body_bytes)

  # The object that describes the failure: `body["error"]` when it is one,
  # otherwise the body itself.
  defp error_object(%{"error" => %{} = error}), do: error

  defp error_object(%{"error" => error} = body) when is_binary(error),
    do: Map.put(body, "message", error)

  defp error_object(%{} = body) when not is_struct(body), do: body

  defp error_object(body) when is_binary(body) do
    # An HTML error page (a proxy's 502, say) is not a message worth showing.
    if String.starts_with?(String.trim_leading(body), "<"), do: %{}, else: %{"message" => body}
  end

  defp error_object(_body), do: %{}

  defp error_codes(%{} = error) do
    [error["code"], error["type"], error["status"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
  end

  defp numeric_code(%{"code" => code}) when is_integer(code) and code in 100..599, do: code
  defp numeric_code(%{"status" => code}) when is_integer(code) and code in 100..599, do: code
  defp numeric_code(_error), do: nil

  defp overflow_texts(%{} = error) do
    [error["code"], error["type"], error["message"], get_in(error, ["metadata", "raw"])]
    |> Enum.filter(&is_binary/1)
  end

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(%{"detail" => detail}) when is_binary(detail), do: detail
  defp error_message(_error), do: nil

  defp transport_message(%{__exception__: true} = exception), do: Exception.message(exception)
  defp transport_message({:exit, reason}), do: transport_message(reason)
  defp transport_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp transport_message(reason) when is_binary(reason), do: reason
  defp transport_message(reason), do: inspect(reason, limit: 10, printable_limit: 200)

  # ── Messages ──────────────────────────────────────────────────────────

  defp with_provider_message(description, nil), do: description

  defp with_provider_message(description, detail) do
    case detail |> String.replace(~r/\s+/, " ") |> String.trim() do
      "" -> description
      detail -> description <> ": " <> truncate(detail)
    end
  end

  defp truncate(text) do
    if String.length(text) > @max_message_length,
      do: String.slice(text, 0, @max_message_length) <> "…",
      else: text
  end

  defp describe(kind, nil), do: describe(kind)
  defp describe(kind, status), do: "#{describe(kind)} (HTTP #{status})"

  defp describe(:transport), do: "The connection to the provider failed"
  defp describe(:timeout), do: "The provider did not respond in time"
  defp describe(:rate_limited), do: "The provider is rate limiting requests"
  defp describe(:overloaded), do: "The provider is overloaded"
  defp describe(:server), do: "The provider failed"
  defp describe(:context_window_exceeded), do: "The request exceeds the model's context window"
  defp describe(:quota_exceeded), do: "The provider account's quota or credits are exhausted"
  defp describe(:auth), do: "The provider rejected the credentials"
  defp describe(:invalid_request), do: "The provider rejected the request"
  defp describe(:invalid_response), do: "The provider returned an unusable response"
  defp describe(:unknown), do: "The provider request failed"

  # ── Retry-After ───────────────────────────────────────────────────────

  defp header(headers, name) when is_map(headers) or is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} -> if String.downcase(to_string(key)) == name, do: header_value(value)
      _other -> nil
    end)
  end

  defp header(_headers, _name), do: nil

  defp header_value([value | _rest]) when is_binary(value), do: value
  defp header_value(value) when is_binary(value), do: value
  defp header_value(_value), do: nil

  defp parse_retry_after(value, now) do
    case parse_number(value) do
      seconds when is_number(seconds) and seconds >= 0 -> ceil(seconds * 1_000)
      _other -> parse_http_date(value, now)
    end
  end

  defp parse_number(nil), do: nil

  defp parse_number(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _other -> nil
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # IMF-fixdate, the only HTTP date format senders may generate:
  # `Sun, 06 Nov 1994 08:49:37 GMT`.
  defp parse_http_date(value, now) do
    with [_all, day, month, year, hour, minute, second] <-
           Regex.run(
             ~r/^\s*[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT\s*$/,
             value
           ),
         month when is_integer(month) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, date} <-
           Date.new(String.to_integer(year), month + 1, String.to_integer(day)),
         {:ok, time} <-
           Time.new(String.to_integer(hour), String.to_integer(minute), String.to_integer(second)),
         {:ok, at} <- DateTime.new(date, time, "Etc/UTC") do
      max(DateTime.diff(at, now, :millisecond), 0)
    else
      _invalid -> nil
    end
  end
end
