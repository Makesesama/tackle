defmodule Tackle.Session.Codec do
  @moduledoc """
  Durable plain-data codec for the session journal.

  Every value written to a journal must belong to a deliberately constrained
  data model: UTF-8 binaries, byte binaries, integers, finite floats, booleans,
  `nil`, lists, and plain maps with binary keys. Runtime values that cannot be
  reconstructed safely are rejected outright:

    * PIDs, ports, references, and functions;
    * Tasks, monitors, cancellation signals, and Registry values;
    * executable module identities and arbitrary structs;
    * tuples and non-byte-aligned bitstrings; and
    * terms larger or deeper than the configured limits.

  `%Tackle.Lib.State{}` is never serialized. Conversation data is converted to
  plain maps here and rebuilt into structs by `Tackle.Session.Loader`.

  Message content parts (see `Tackle.Lib.Tool.Content`) are plain maps with
  binary keys, so a tool result that read an image round-trips unchanged.
  """

  alias Tackle.Lib.Message
  alias Tackle.Lib.Usage

  @max_depth 32
  @max_binary_size 8 * 1024 * 1024
  @max_list_length 100_000
  @max_map_size 10_000
  @max_total_size 24 * 1024 * 1024

  @typedoc "A value accepted by the durable data model."
  @type plain ::
          nil | boolean | integer | float | binary | [plain] | %{optional(String.t()) => plain}

  @doc "Returns `:ok` when `value` belongs to the durable data model."
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(value) do
    with :ok <- validate_value(value, 0) do
      validate_total_size(value)
    end
  end

  @doc "Returns `value` or raises when it is not durable plain data."
  @spec validate!(term()) :: term()
  def validate!(value) do
    case validate(value) do
      :ok -> value
      {:error, reason} -> raise ArgumentError, "invalid durable value: #{inspect(reason)}"
    end
  end

  @doc """
  Recursively normalizes host values into durable plain data.

  `DateTime` values become RFC 3339 strings and atom map keys become binaries.
  Forbidden terms are left untouched so `validate/1` rejects them explicitly
  instead of silently dropping them.
  """
  @spec normalize(term()) :: term()
  def normalize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def normalize(%Usage{} = value), do: encode_usage(value)
  def normalize(%Message{} = value), do: encode_message!(value)

  def normalize(%{} = map) when not is_struct(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), normalize(value)} end)
  end

  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  def normalize(value), do: value

  @doc """
  Encodes one settled message into its durable map representation.

  The durable message keeps every field required for exact continuation:
  identity, role, content, structured content parts, reasoning state, normalized
  tool calls and results, timestamp, normalized usage, selected model, and
  validated provider continuation state.
  """
  @spec encode_message(Message.t()) :: {:ok, map()} | {:error, term()}
  def encode_message(%Message{} = message) do
    data = encode_message!(message)

    case validate(data) do
      :ok -> {:ok, data}
      {:error, reason} -> {:error, {:invalid_message, reason}}
    end
  end

  @doc "Encodes one message or raises for non-durable content."
  @spec encode_message!(Message.t()) :: map()
  def encode_message!(%Message{} = message) do
    %{
      "id" => message.id,
      "role" => encode_role(message.role),
      "content" => message.content,
      "parts" => message.parts,
      "thinking" => message.thinking,
      "tool_calls" => encode_tool_calls(message.tool_calls),
      "tool_call_id" => message.tool_call_id,
      "tool_name" => message.tool_name,
      "timestamp" => encode_datetime(message.timestamp),
      "token_usage" => encode_usage(message.token_usage),
      "model" => message.model,
      "provider_state" => normalize(message.provider_state)
    }
  end

  @doc """
  Rebuilds a `%Tackle.Lib.Message{}` from a durable map.

  Returns an explicit error for malformed or unsupported durable messages.
  """
  @spec decode_message(map()) :: {:ok, Message.t()} | {:error, term()}
  def decode_message(%{} = data) do
    with {:ok, role} <- decode_role(Map.get(data, "role")),
         {:ok, timestamp} <- decode_datetime(Map.get(data, "timestamp")),
         {:ok, tool_calls} <- decode_tool_calls(Map.get(data, "tool_calls")),
         {:ok, usage} <- decode_usage(Map.get(data, "token_usage")) do
      message = %Message{
        id: Map.get(data, "id"),
        role: role,
        content: Map.get(data, "content"),
        parts: decode_parts(Map.get(data, "parts")),
        thinking: Map.get(data, "thinking"),
        tool_calls: tool_calls,
        tool_call_id: Map.get(data, "tool_call_id"),
        tool_name: Map.get(data, "tool_name"),
        timestamp: timestamp,
        token_usage: usage,
        model: Map.get(data, "model"),
        provider_state: Map.get(data, "provider_state")
      }

      {:ok, message}
    end
  end

  def decode_message(other), do: {:error, {:invalid_durable_message, other}}

  @doc "Returns true when `role` is a durable message role."
  @spec valid_role?(term()) :: boolean()
  def valid_role?(role), do: match?({:ok, _}, decode_role(role))

  @doc false
  @spec encode_datetime(DateTime.t() | nil) :: String.t() | nil
  def encode_datetime(nil), do: nil
  def encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  @doc false
  @spec decode_datetime(term()) :: {:ok, DateTime.t() | nil} | {:error, term()}
  def decode_datetime(nil), do: {:ok, nil}

  def decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, {:invalid_timestamp, value, reason}}
    end
  end

  def decode_datetime(other), do: {:error, {:invalid_timestamp, other}}

  # Content parts are opaque, durable plain data. Malformed values decode to
  # `nil` so a hand-edited session degrades to text-only instead of failing to
  # load.
  defp decode_parts(parts) when is_list(parts) and parts != [], do: parts
  defp decode_parts(_parts), do: nil

  @doc false
  @spec encode_usage(Usage.t() | nil) :: map() | nil
  def encode_usage(nil), do: nil

  def encode_usage(%Usage{} = usage) do
    usage
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), normalize(value)} end)
  end

  @doc false
  @spec decode_usage(term()) :: {:ok, Usage.t() | nil} | {:error, term()}
  def decode_usage(nil), do: {:ok, nil}

  def decode_usage(%{} = data) do
    %Usage{} = usage = Usage.normalize(data)
    {:ok, usage}
  end

  def decode_usage(other), do: {:error, {:invalid_usage, other}}

  defp encode_role(nil), do: nil
  defp encode_role(role) when is_atom(role), do: Atom.to_string(role)
  defp encode_role(role) when is_binary(role), do: role

  defp decode_role(nil), do: {:ok, nil}

  defp decode_role(role) when role in ["user", "assistant", "tool"] do
    {:ok, String.to_existing_atom(role)}
  end

  defp decode_role(role), do: {:error, {:invalid_role, role}}

  defp encode_tool_calls(nil), do: []

  defp encode_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn call ->
      %{
        "id" => tool_field(call, :id),
        "name" => tool_field(call, :name),
        "arguments" => normalize(tool_field(call, :arguments) || %{})
      }
    end)
  end

  # Tool calls may be plain maps or `%Tackle.Lib.Tool.Call{}` structs, depending
  # on whether they came from a provider response or were replayed from durable
  # history.
  defp tool_field(call, key) when is_map(call) do
    Map.get(call, key) || Map.get(call, Atom.to_string(key))
  end

  defp tool_field(_call, _key), do: nil

  defp decode_tool_calls(nil), do: {:ok, nil}
  defp decode_tool_calls([]), do: {:ok, nil}

  defp decode_tool_calls(calls) when is_list(calls) do
    decoded =
      Enum.map(calls, fn call ->
        %{
          id: Map.get(call, "id"),
          name: Map.get(call, "name"),
          arguments: Map.get(call, "arguments", %{})
        }
      end)

    {:ok, decoded}
  end

  defp decode_tool_calls(other), do: {:error, {:invalid_tool_calls, other}}

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key

  defp validate_value(_value, depth) when depth > @max_depth do
    {:error, {:too_deep, depth}}
  end

  defp validate_value(nil, _depth), do: :ok
  defp validate_value(value, _depth) when is_boolean(value), do: :ok
  defp validate_value(value, _depth) when is_integer(value), do: :ok

  # Erlang/OTP floats are always finite; NaN and infinity are not
  # representable, so every float is durable once its total size is bounded.
  defp validate_value(value, _depth) when is_float(value), do: :ok

  defp validate_value(value, _depth) when is_binary(value) do
    if byte_size(value) <= @max_binary_size do
      :ok
    else
      {:error, {:binary_too_large, byte_size(value)}}
    end
  end

  defp validate_value(value, depth) when is_list(value) do
    if length(value) > @max_list_length do
      {:error, {:list_too_long, length(value)}}
    else
      reduce_values(value, depth)
    end
  end

  defp validate_value(value, depth) when is_map(value) do
    cond do
      is_struct(value) ->
        {:error, {:forbidden_term, :struct, value.__struct__}}

      map_size(value) > @max_map_size ->
        {:error, {:map_too_large, map_size(value)}}

      true ->
        validate_map(value, depth)
    end
  end

  defp validate_value(value, _depth) when is_pid(value), do: {:error, {:forbidden_term, :pid}}

  defp validate_value(value, _depth) when is_reference(value),
    do: {:error, {:forbidden_term, :reference}}

  defp validate_value(value, _depth) when is_port(value), do: {:error, {:forbidden_term, :port}}

  defp validate_value(value, _depth) when is_function(value),
    do: {:error, {:forbidden_term, :function}}

  defp validate_value(value, _depth) when is_tuple(value), do: {:error, {:forbidden_term, :tuple}}

  defp validate_value(value, _depth) when is_bitstring(value),
    do: {:error, {:forbidden_term, :bitstring}}

  defp validate_value(value, _depth) when is_atom(value),
    do: {:error, {:forbidden_term, :atom, value}}

  defp reduce_values([], _depth), do: :ok

  defp reduce_values([head | tail], depth) do
    case validate_value(head, depth + 1) do
      :ok -> reduce_values(tail, depth)
      {:error, _reason} = error -> error
    end
  end

  defp validate_map(map, depth) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      with :ok <- validate_key(key),
           :ok <- validate_value(value, depth + 1) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_key(key) when is_binary(key) do
    cond do
      not String.valid?(key) -> {:error, {:invalid_key_encoding, key}}
      byte_size(key) > 1024 -> {:error, {:key_too_large, byte_size(key)}}
      true -> :ok
    end
  end

  defp validate_key(key), do: {:error, {:invalid_key, key}}

  defp validate_total_size(value) do
    case :erlang.external_size(value) do
      size when size <= @max_total_size -> :ok
      size -> {:error, {:term_too_large, size}}
    end
  end
end
