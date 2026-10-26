defmodule Tackle.SDK.Protocol do
  @moduledoc """
  Pure JSON-RPC 2.0 codec for the Tackle SDK wire protocol.

  This module knows nothing about processes or I/O: it decodes incoming
  lines, builds responses and notifications, and serializes
  `Tackle.Lib.Event` structs into JSON-safe maps. Keeping it pure makes the
  wire contract testable without spawning anything.

  The wire format itself is specified in `PROTOCOL.md`. Frames are
  newline-delimited JSON-RPC 2.0 messages (ndjson).
  """

  alias Tackle.Lib.Event

  @jsonrpc "2.0"

  # Standard JSON-RPC 2.0 error codes.
  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603

  # Server-defined error codes (documented in PROTOCOL.md).
  @not_initialized -32002
  @turn_conflict -32000

  @doc "The protocol version this server speaks; returned by `initialize`."
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: 1

  @doc "Standard JSON-RPC error code: method not found."
  @spec method_not_found_code() :: neg_integer()
  def method_not_found_code, do: @method_not_found

  @doc "Standard JSON-RPC error code: invalid params."
  @spec invalid_params_code() :: neg_integer()
  def invalid_params_code, do: @invalid_params

  @doc "Standard JSON-RPC error code: internal error."
  @spec internal_error_code() :: neg_integer()
  def internal_error_code, do: @internal_error

  @doc "Server-defined error code: a request arrived before `initialize`."
  @spec not_initialized_code() :: neg_integer()
  def not_initialized_code, do: @not_initialized

  @doc "Server-defined error code: a session already has an active turn."
  @spec turn_conflict_code() :: neg_integer()
  def turn_conflict_code, do: @turn_conflict

  @doc """
  Decodes one input line into a request.

  Returns:

    * `:ignore` — blank line, nothing to do.
    * `{:ok, request}` — a validated request with `method`, `params`, and `id`
      (`nil` for client notifications, which expect no response).
    * `{:error, code, message}` — the line is not valid JSON-RPC 2.0.
  """
  @spec decode(binary()) ::
          :ignore
          | {:ok, %{method: String.t(), params: map(), id: term()}}
          | {:error, integer(), String.t()}
  def decode(line) when is_binary(line) do
    case String.trim(line) do
      "" ->
        :ignore

      trimmed ->
        case JSON.decode(trimmed) do
          {:ok, %{"jsonrpc" => "2.0", "method" => method} = frame} when is_binary(method) ->
            {:ok, %{method: method, params: normalize_params(frame["params"]), id: frame["id"]}}

          {:ok, _} ->
            {:error, @invalid_request, "frame is not a JSON-RPC 2.0 request"}

          {:error, _reason} ->
            {:error, @parse_error, "could not parse JSON"}
        end
    end
  end

  defp normalize_params(nil), do: %{}
  defp normalize_params(params) when is_map(params), do: params
  defp normalize_params(_), do: %{}

  @doc "Builds a success response for the given request id."
  @spec response(term(), map()) :: map()
  def response(id, %{} = result) do
    %{"jsonrpc" => @jsonrpc, "id" => id, "result" => result}
  end

  @doc "Builds an error response for the given request id."
  @spec error_response(term(), integer(), String.t(), term() | nil) :: map()
  def error_response(id, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if is_nil(data), do: error, else: Map.put(error, "data", json_safe(data))
    %{"jsonrpc" => @jsonrpc, "id" => id, "error" => error}
  end

  @doc "Builds a server-to-client notification (no id, no response expected)."
  @spec notification(String.t(), map()) :: map()
  def notification(method, %{} = params) do
    %{"jsonrpc" => @jsonrpc, "method" => method, "params" => params}
  end

  @doc "Encodes a frame as one ndjson line (trailing newline included)."
  @spec encode_line(map()) :: binary()
  def encode_line(%{} = frame) do
    JSON.encode!(frame) <> "\n"
  end

  @doc """
  Serializes a `Tackle.Lib.Event` into a JSON-safe map.

  The shape mirrors the struct: `type`, `id`, `parentId`, `data`, `timestamp`
  (ISO8601), and `metadata`. New event types and data fields may be added in
  minor protocol revisions; clients must ignore unknown fields.
  """
  @spec serialize_event(Event.t()) :: map()
  def serialize_event(%Event{} = event) do
    %{
      "type" => to_string(event.type),
      "id" => event.id,
      "parentId" => event.parent_id,
      "data" => json_safe(event.data),
      "timestamp" => event.timestamp && DateTime.to_iso8601(event.timestamp),
      "metadata" => json_safe(event.metadata)
    }
  end

  @doc """
  Recursively converts a term into something the stdlib `JSON` encoder accepts.

  Structs become plain maps (so `%Tackle.Lib.Usage{}` and friends serialize
  without the encoder knowing about them; an exception such as
  `%Tackle.Lib.LLM.Error{}` loses its `__exception__` marker), tuples become
  lists, and anything exotic falls back to its inspected form rather than
  crashing the stream.
  """
  @spec json_safe(term()) :: term()
  def json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def json_safe(%Date{} = value), do: Date.to_iso8601(value)
  def json_safe(%Time{} = value), do: Time.to_iso8601(value)

  def json_safe(%_{} = struct_value) do
    struct_value
    |> Map.from_struct()
    |> Map.delete(:__exception__)
    |> json_safe()
  end

  def json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {json_safe_key(key), json_safe(value)} end)
  end

  def json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  def json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()

  # Booleans and nil are atoms; keep them literal instead of stringifying.
  def json_safe(boolean) when is_boolean(boolean), do: boolean
  def json_safe(nil), do: nil

  # Functions, pids, and refs have no JSON form; fall back to a readable one.
  def json_safe(value) when is_function(value) or is_pid(value) or is_reference(value),
    do: inspect(value)

  def json_safe(atom) when is_atom(atom), do: to_string(atom)
  def json_safe(value), do: value

  defp json_safe_key(key) when is_binary(key), do: key
  defp json_safe_key(key) when is_atom(key), do: to_string(key)
  defp json_safe_key(key), do: inspect(key)
end
