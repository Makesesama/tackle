defmodule Tackle.Plugins.Codex.SSE do
  @moduledoc false

  @enforce_keys []
  defstruct buffer: "",
            data_lines: [],
            content_parts: %{},
            thinking_parts: %{},
            tool_calls: %{},
            provider_output: [],
            usage: nil,
            model: nil,
            terminal?: false,
            error: nil,
            cancelled?: false

  @type t :: %__MODULE__{
          buffer: binary(),
          data_lines: [binary()],
          content_parts: %{optional(non_neg_integer()) => binary()},
          thinking_parts: %{optional(non_neg_integer()) => binary()},
          tool_calls: %{optional(non_neg_integer()) => map()},
          provider_output: [map()],
          usage: map() | nil,
          model: String.t() | nil,
          terminal?: boolean(),
          error: term() | nil,
          cancelled?: boolean()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = state), do: %{state | cancelled?: true}

  @doc false
  @spec push_event(t(), map(), (map() -> any())) :: t()
  def push_event(%__MODULE__{} = state, %{} = event, callback) do
    handle_event(state, event, callback)
  end

  @spec push(t(), binary(), (map() -> any())) :: t()
  def push(%__MODULE__{} = state, chunk, callback) when is_binary(chunk) do
    [buffer | complete_lines] =
      state.buffer
      |> Kernel.<>(chunk)
      |> String.split("\n")
      |> Enum.reverse()

    state = %{state | buffer: buffer}

    complete_lines
    |> Enum.reverse()
    |> Enum.reduce(state, &consume_line(&2, &1, callback))
  end

  @spec finish(t(), (map() -> any())) :: t()
  def finish(%__MODULE__{} = state, callback) do
    state =
      if state.buffer == "" do
        state
      else
        consume_line(%{state | buffer: ""}, state.buffer, callback)
      end

    dispatch_event(state, callback)
  end

  @spec result(t(), String.t(), keyword() | map() | nil) ::
          {:ok,
           %{
             data: map(),
             usage: map() | nil,
             model: String.t(),
             provider_state: map() | nil
           }}
          | {:error, term()}
  def result(%__MODULE__{cancelled?: true}, _requested_model, _schema), do: {:error, :cancelled}

  def result(%__MODULE__{error: error}, _requested_model, _schema) when not is_nil(error),
    do: {:error, error}

  def result(%__MODULE__{terminal?: false}, _requested_model, _schema),
    do: {:error, :stream_ended_without_terminal_event}

  def result(%__MODULE__{} = state, requested_model, schema) do
    model = state.model || requested_model
    content = join_parts(state.content_parts)
    thinking = join_parts(state.thinking_parts, "\n\n")

    tool_calls =
      state.tool_calls
      |> Enum.sort_by(fn {index, _call} -> index end)
      |> Enum.map(fn {_index, call} -> call end)

    data =
      if schema && tool_calls == [] do
        structured_data(content)
      else
        {:ok,
         %{}
         |> maybe_put("content", present_string(content))
         |> maybe_put("thinking", present_string(thinking))
         |> Map.put("tool_calls", tool_calls)}
      end

    with {:ok, data} <- data do
      {:ok,
       %{
         data: data,
         usage: state.usage,
         model: model,
         provider_state: provider_state(state.provider_output, requested_model)
       }}
    end
  end

  defp consume_line(state, raw_line, callback) do
    line = String.trim_trailing(raw_line, "\r")

    cond do
      line == "" ->
        dispatch_event(state, callback)

      String.starts_with?(line, ":") ->
        state

      String.starts_with?(line, "data:") ->
        data = line |> String.replace_prefix("data:", "") |> String.trim_leading()
        %{state | data_lines: [data | state.data_lines]}

      true ->
        state
    end
  end

  defp dispatch_event(%__MODULE__{data_lines: []} = state, _callback), do: state

  defp dispatch_event(%__MODULE__{} = state, callback) do
    payload = state.data_lines |> Enum.reverse() |> Enum.join("\n")
    state = %{state | data_lines: []}

    case payload do
      "[DONE]" -> state
      _payload -> decode_event(state, payload, callback)
    end
  end

  defp decode_event(state, payload, callback) do
    case JSON.decode(payload) do
      {:ok, %{} = event} -> handle_event(state, event, callback)
      {:ok, _other} -> put_error(state, :invalid_sse_event)
      {:error, _reason} -> put_error(state, {:invalid_sse_json, String.slice(payload, 0, 512)})
    end
  end

  defp handle_event(state, %{"type" => type, "delta" => delta} = event, callback)
       when type in ["response.output_text.delta", "response.refusal.delta"] and is_binary(delta) do
    emit(callback, %{type: :text_delta, delta: delta})
    %{state | content_parts: append_part(state.content_parts, output_index(event), delta)}
  end

  defp handle_event(
         state,
         %{"type" => "response.reasoning_summary_text.delta", "delta" => delta} = event,
         callback
       )
       when is_binary(delta) do
    emit(callback, %{type: :reasoning_delta, delta: delta})
    %{state | thinking_parts: append_part(state.thinking_parts, output_index(event), delta)}
  end

  defp handle_event(
         state,
         %{"type" => "response.function_call_arguments.delta", "delta" => delta} = event,
         callback
       )
       when is_binary(delta) do
    index = output_index(event)
    call = Map.get(state.tool_calls, index, empty_call(event))
    call = Map.update(call, "arguments", delta, &(&1 <> delta))

    emit(callback, %{
      type: :tool_input_delta,
      delta: delta,
      tool_call_id: call["id"],
      tool_name: call["name"]
    })

    %{state | tool_calls: Map.put(state.tool_calls, index, call)}
  end

  defp handle_event(
         state,
         %{"type" => "response.output_item.added", "item" => %{"type" => "function_call"} = item} =
           event,
         _callback
       ) do
    put_tool_call(state, output_index(event), item)
  end

  defp handle_event(
         state,
         %{"type" => "response.output_item.done", "item" => %{"type" => "function_call"} = item} =
           event,
         _callback
       ) do
    put_tool_call(state, output_index(event), item)
  end

  defp handle_event(
         state,
         %{"type" => "response.output_item.done", "item" => %{"type" => "message"} = item} =
           event,
         _callback
       ) do
    put_part(state, :content_parts, output_index(event), message_text(item))
  end

  defp handle_event(
         state,
         %{"type" => "response.output_item.done", "item" => %{"type" => "reasoning"} = item} =
           event,
         _callback
       ) do
    put_part(state, :thinking_parts, output_index(event), reasoning_text(item))
  end

  defp handle_event(state, %{"type" => type, "response" => response}, callback)
       when type in ["response.completed", "response.done"] and is_map(response) do
    finalize_response(state, response, callback)
  end

  defp handle_event(state, %{"type" => "response.incomplete", "response" => response}, _callback) do
    reason = get_in(response, ["incomplete_details", "reason"])
    put_error(state, {:incomplete_response, reason || "unknown"})
  end

  defp handle_event(state, %{"type" => "response.failed", "response" => response}, _callback) do
    put_error(state, {:provider_error, response["error"] || response})
  end

  defp handle_event(state, %{"type" => "error"} = event, _callback) do
    put_error(state, {:provider_error, event["error"] || event["message"] || event})
  end

  defp handle_event(state, _event, _callback), do: state

  defp finalize_response(state, response, callback) do
    case response["status"] do
      status when status in [nil, "completed"] ->
        state = apply_terminal_output(state, response["output"] || [])
        usage = normalize_usage(response["usage"])
        if usage, do: emit(callback, %{type: :usage, usage: usage})

        %{
          state
          | terminal?: true,
            provider_output: provider_output(response["output"]),
            usage: usage,
            model: string_or_nil(response["model"]) || state.model
        }

      "incomplete" ->
        reason = get_in(response, ["incomplete_details", "reason"])
        put_error(state, {:incomplete_response, reason || "unknown"})

      status ->
        put_error(state, {:provider_error, response["error"] || status})
    end
  end

  defp apply_terminal_output(state, output) when is_list(output) do
    output
    |> Enum.with_index()
    |> Enum.reduce(state, fn
      {%{"type" => "function_call"} = item, index}, acc ->
        put_tool_call(acc, index, item)

      {%{"type" => "message"} = item, index}, acc ->
        put_part(acc, :content_parts, index, message_text(item))

      {%{"type" => "reasoning"} = item, index}, acc ->
        put_part(acc, :thinking_parts, index, reasoning_text(item))

      {_item, _index}, acc ->
        acc
    end)
  end

  defp apply_terminal_output(state, _output), do: state

  defp put_tool_call(state, index, item) do
    existing = Map.get(state.tool_calls, index, %{})

    arguments =
      case item["arguments"] do
        value when is_binary(value) -> value
        _value -> existing["arguments"] || ""
      end

    call = %{
      "id" => string_or_nil(item["call_id"]) || existing["id"],
      "name" => string_or_nil(item["name"]) || existing["name"],
      "arguments" => arguments
    }

    %{state | tool_calls: Map.put(state.tool_calls, index, call)}
  end

  defp empty_call(event) do
    %{
      "id" => string_or_nil(event["call_id"]),
      "name" => string_or_nil(event["name"]),
      "arguments" => ""
    }
  end

  defp output_index(%{"output_index" => index}) when is_integer(index) and index >= 0, do: index
  defp output_index(_event), do: 0

  defp message_text(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "", fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> text
      %{"type" => "refusal", "refusal" => text} when is_binary(text) -> text
      _item -> ""
    end)
  end

  defp message_text(_item), do: ""

  defp reasoning_text(item), do: text_parts(item["summary"])

  defp text_parts(parts) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      _part -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp text_parts(_parts), do: ""

  defp normalize_usage(nil), do: nil

  defp normalize_usage(%{} = usage) do
    cached = non_negative_integer(get_in(usage, ["input_tokens_details", "cached_tokens"])) || 0

    cache_write =
      non_negative_integer(get_in(usage, ["input_tokens_details", "cache_write_tokens"])) || 0

    input = non_negative_integer(usage["input_tokens"])

    %{}
    |> maybe_put("input_tokens", subtract_cached(input, cached + cache_write))
    |> maybe_put("output_tokens", non_negative_integer(usage["output_tokens"]))
    |> maybe_put(
      "reasoning_tokens",
      non_negative_integer(get_in(usage, ["output_tokens_details", "reasoning_tokens"]))
    )
    |> maybe_put("cached_input_tokens", cached)
    |> maybe_put("cache_write_tokens", cache_write)
    |> maybe_put("total_tokens", non_negative_integer(usage["total_tokens"]))
    |> Map.put("provider_usage", usage)
  end

  defp normalize_usage(_usage), do: nil

  defp subtract_cached(nil, _cached), do: nil
  defp subtract_cached(input, cached), do: max(0, input - cached)

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(value) when is_float(value) and value >= 0, do: trunc(value)
  defp non_negative_integer(_value), do: nil

  defp structured_data(content) do
    case JSON.decode(content) do
      {:ok, %{} = data} -> {:ok, data}
      {:ok, _other} -> {:error, :structured_response_not_an_object}
      {:error, _reason} -> {:error, :invalid_structured_response}
    end
  end

  defp append_part(parts, index, delta), do: Map.update(parts, index, delta, &(&1 <> delta))

  defp put_part(state, _field, _index, ""), do: state

  defp put_part(state, field, index, text) do
    Map.update!(state, field, &Map.put(&1, index, text))
  end

  defp join_parts(parts, separator \\ "") do
    parts
    |> Enum.sort_by(fn {index, _text} -> index end)
    |> Enum.map_join(separator, fn {_index, text} -> text end)
  end

  defp provider_output(output) when is_list(output) do
    Enum.map(output, fn
      %{"type" => "reasoning"} = item -> Map.delete(item, "content")
      item -> item
    end)
  end

  defp provider_output(_output), do: []

  defp provider_state([], _model), do: nil

  defp provider_state(output, model) do
    %{"provider" => "openai-codex", "model" => model, "output" => output}
  end

  defp put_error(%__MODULE__{error: nil} = state, error), do: %{state | error: error}
  defp put_error(state, _error), do: state

  defp emit(callback, event) when is_function(callback, 1), do: callback.(event)

  defp present_string(""), do: nil
  defp present_string(value), do: value
  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
