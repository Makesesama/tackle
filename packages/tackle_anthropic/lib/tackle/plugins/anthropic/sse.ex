defmodule Tackle.Plugins.Anthropic.SSE do
  @moduledoc false

  # Incremental parser for Anthropic's Messages streaming SSE protocol.
  #
  # Each `data:` payload is a JSON object whose `type` names the event
  # (`message_start`, `content_block_start`, `content_block_delta`,
  # `content_block_stop`, `message_delta`, `message_stop`, `ping`, `error`).
  # The parser accumulates content blocks, emits provider-neutral delta events,
  # and produces the final adapter response plus replayable `provider_state`.

  alias Tackle.Lib.JSON
  alias Tackle.Lib.LLM.Error
  alias Tackle.Lib.Usage

  defstruct buffer: "",
            event_name: nil,
            data_lines: [],
            blocks: %{},
            content: "",
            thinking: "",
            usage: %{},
            model: nil,
            stop_reason: nil,
            done?: false,
            usage_emitted?: false,
            error: nil,
            cancelled?: false,
            tool_names: %{},
            is_oauth: true

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      tool_names: Keyword.get(opts, :tool_names, %{}),
      is_oauth: Keyword.get(opts, :is_oauth, true)
    }
  end

  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = state), do: %{state | cancelled?: true}

  @spec push(t(), binary(), (map() -> any())) :: t()
  def push(%__MODULE__{done?: true} = state, chunk, _callback) when is_binary(chunk), do: state

  def push(%__MODULE__{} = state, chunk, callback) when is_binary(chunk) do
    {complete_lines, buffer} = split_complete_lines(state.buffer <> chunk)
    state = %{state | buffer: buffer}

    Enum.reduce(complete_lines, state, fn line, acc ->
      if acc.done?, do: acc, else: consume_line(acc, line, callback)
    end)
  end

  @spec finish(t(), (map() -> any())) :: t()
  def finish(%__MODULE__{done?: true} = state, _callback), do: state

  def finish(%__MODULE__{} = state, callback) do
    state =
      if state.buffer == "" do
        state
      else
        consume_line(%{state | buffer: ""}, state.buffer, callback)
      end

    if state.done?, do: state, else: dispatch_event(state, callback)
  end

  @spec result(t(), String.t(), keyword() | map() | nil) ::
          {:ok, %{data: map(), usage: Usage.t() | nil, model: String.t(), provider_state: map()}}
          | {:error, term()}
  def result(%__MODULE__{cancelled?: true}, _requested_model, _schema), do: {:error, :cancelled}

  def result(%__MODULE__{error: %Error{} = error}, _requested_model, _schema),
    do: {:error, error}

  def result(%__MODULE__{error: error}, _requested_model, _schema) when not is_nil(error),
    do: {:error, Error.new(:invalid_response, details: error)}

  # A stream that stops before `message_stop` lost its connection.
  def result(%__MODULE__{done?: false}, _requested_model, _schema),
    do: {:error, Error.new(:transport, details: :stream_ended_without_message_stop)}

  def result(%__MODULE__{stop_reason: nil}, _requested_model, _schema),
    do: {:error, Error.new(:invalid_response, details: :stream_ended_without_stop_reason)}

  def result(%__MODULE__{} = state, requested_model, schema) do
    model = state.model || requested_model
    tool_calls = tool_calls(state)

    data =
      if schema && tool_calls == [] do
        structured_data(state.content)
      else
        {:ok,
         %{}
         |> maybe_put("content", present_string(state.content))
         |> maybe_put("thinking", present_string(state.thinking))
         |> Map.put("tool_calls", tool_calls)}
      end

    with {:ok, data} <- data do
      {:ok,
       %{
         data: data,
         usage: usage(state.usage),
         model: model,
         provider_state: provider_state(state)
       }}
    end
  end

  defp split_complete_lines(data) do
    lines = :binary.split(data, "\n", [:global])
    {buffer, complete_lines} = List.pop_at(lines, -1)
    {complete_lines, buffer}
  end

  defp consume_line(state, raw_line, callback) do
    line = trim_trailing_cr(raw_line)

    case line do
      "" ->
        dispatch_event(state, callback)

      <<":", _rest::binary>> ->
        state

      <<"event:", value::binary>> ->
        %{state | event_name: trim_optional_space(value)}

      <<"data:", value::binary>> ->
        %{state | data_lines: [trim_optional_space(value) | state.data_lines]}

      _other ->
        state
    end
  end

  defp trim_trailing_cr(line) do
    case String.ends_with?(line, "\r") do
      true -> binary_part(line, 0, byte_size(line) - 1)
      false -> line
    end
  end

  defp trim_optional_space(<<" ", rest::binary>>), do: rest
  defp trim_optional_space(value), do: value

  defp dispatch_event(%__MODULE__{data_lines: []} = state, _callback), do: state

  defp dispatch_event(%__MODULE__{} = state, callback) do
    payload = state.data_lines |> Enum.reverse() |> Enum.join("\n")
    state = %{state | data_lines: [], event_name: nil}

    case JSON.decode(payload) do
      {:ok, %{} = event} -> handle_event(state, event, callback)
      {:ok, _other} -> %{state | error: :invalid_sse_event}
      {:error, _reason} -> %{state | error: {:invalid_sse_json, truncate(payload, 512)}}
    end
  end

  defp handle_event(state, %{"type" => "message_start"} = event, _callback) do
    message = Map.get(event, "message", %{})

    %{
      state
      | model: Map.get(message, "model") || state.model,
        usage: merge_usage(state.usage, Map.get(message, "usage"))
    }
  end

  defp handle_event(state, %{"type" => "content_block_start"} = event, callback) do
    index = Map.get(event, "index")
    block = start_block(Map.get(event, "content_block", %{}))

    state = maybe_emit_start(put_block(state, index, block), index, block, callback)

    state
  end

  defp handle_event(state, %{"type" => "content_block_delta"} = event, callback) do
    apply_delta(state, Map.get(event, "index"), Map.get(event, "delta", %{}), callback)
  end

  defp handle_event(state, %{"type" => "content_block_stop"} = event, _callback) do
    finalize_block(state, Map.get(event, "index"))
  end

  defp handle_event(state, %{"type" => "message_delta"} = event, _callback) do
    stop_reason = get_in(event, ["delta", "stop_reason"])

    %{
      state
      | stop_reason: stop_reason || state.stop_reason,
        usage: merge_usage(state.usage, Map.get(event, "usage"))
    }
  end

  defp handle_event(state, %{"type" => "message_stop"}, callback) do
    emit_usage(%{state | done?: true}, callback)
  end

  defp handle_event(state, %{"type" => "ping"}, _callback), do: state

  # An error after the stream started, such as `overloaded_error`.
  defp handle_event(state, %{"type" => "error", "error" => error}, _callback) do
    %{state | error: Error.from_stream(error)}
  end

  defp handle_event(state, _event, _callback), do: state

  defp start_block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: %{type: :text, text: text}

  defp start_block(%{"type" => "text"}), do: %{type: :text, text: ""}

  defp start_block(%{"type" => "thinking", "thinking" => thinking, "signature" => signature}) do
    %{type: :thinking, thinking: text_or_empty(thinking), signature: text_or_empty(signature)}
  end

  defp start_block(%{"type" => "thinking"}), do: %{type: :thinking, thinking: "", signature: ""}

  defp start_block(%{"type" => "redacted_thinking", "data" => data}),
    do: %{type: :redacted_thinking, data: text_or_empty(data)}

  defp start_block(%{"type" => "tool_use", "id" => id, "name" => name}),
    do: %{type: :tool_use, id: id, name: name, json: "", input: nil}

  defp start_block(%{"type" => "tool_use"}),
    do: %{type: :tool_use, id: nil, name: nil, json: "", input: nil}

  defp start_block(_block), do: %{type: :unknown}

  defp maybe_emit_start(state, _index, %{type: :text, text: text}, callback)
       when is_binary(text) and text != "" do
    emit(callback, %{type: :text_delta, delta: text})
    %{state | content: state.content <> text}
  end

  defp maybe_emit_start(state, _index, %{type: :thinking, thinking: thinking}, callback)
       when is_binary(thinking) and thinking != "" do
    emit(callback, %{type: :reasoning_delta, delta: thinking})
    %{state | thinking: state.thinking <> thinking}
  end

  defp maybe_emit_start(state, _index, _block, _callback), do: state

  defp apply_delta(state, index, %{"type" => "text_delta", "text" => text}, callback)
       when is_binary(text) do
    state = ensure_block(state, index, %{type: :text, text: ""})

    case Map.get(state.blocks, index) do
      %{type: :text} = block ->
        emit(callback, %{type: :text_delta, delta: text})

        put_block(%{state | content: state.content <> text}, index, %{
          block
          | text: block.text <> text
        })

      _other ->
        state
    end
  end

  defp apply_delta(state, index, %{"type" => "thinking_delta", "thinking" => thinking}, callback)
       when is_binary(thinking) do
    state = ensure_block(state, index, %{type: :thinking, thinking: "", signature: ""})

    case Map.get(state.blocks, index) do
      %{type: :thinking} = block ->
        emit(callback, %{type: :reasoning_delta, delta: thinking})

        put_block(
          %{state | thinking: state.thinking <> thinking},
          index,
          %{block | thinking: block.thinking <> thinking}
        )

      _other ->
        state
    end
  end

  defp apply_delta(
         state,
         index,
         %{"type" => "signature_delta", "signature" => signature},
         _callback
       )
       when is_binary(signature) do
    case Map.get(state.blocks, index) do
      %{type: :thinking} = block ->
        put_block(state, index, %{block | signature: block.signature <> signature})

      _other ->
        state
    end
  end

  defp apply_delta(
         state,
         index,
         %{"type" => "input_json_delta", "partial_json" => json},
         callback
       )
       when is_binary(json) do
    state =
      ensure_block(state, index, %{type: :tool_use, id: nil, name: nil, json: "", input: nil})

    case Map.get(state.blocks, index) do
      %{type: :tool_use} = block ->
        emit(callback, %{
          type: :tool_input_delta,
          delta: json,
          tool_call_id: block.id,
          tool_name: block.name
        })

        put_block(state, index, %{block | json: block.json <> json})

      _other ->
        state
    end
  end

  defp apply_delta(state, _index, _delta, _callback), do: state

  defp finalize_block(state, index) do
    case Map.get(state.blocks, index) do
      %{type: :tool_use} = block ->
        case decode_tool_input(block.json) do
          {:ok, input} -> put_block(state, index, %{block | input: input})
          {:error, reason} -> %{state | error: reason}
        end

      _other ->
        state
    end
  end

  defp decode_tool_input(""), do: {:ok, %{}}

  defp decode_tool_input(json) do
    case JSON.decode(json) do
      {:ok, %{} = input} -> {:ok, input}
      {:ok, _other} -> {:error, :tool_call_arguments_not_an_object}
      {:error, _reason} -> {:error, {:invalid_tool_call_arguments, truncate(json, 512)}}
    end
  end

  defp ensure_block(state, index, block) do
    if Map.has_key?(state.blocks, index), do: state, else: put_block(state, index, block)
  end

  defp put_block(state, index, block), do: %{state | blocks: Map.put(state.blocks, index, block)}

  defp ordered_blocks(state) do
    state.blocks
    |> Enum.sort_by(fn {index, _block} -> index end)
    |> Enum.map(fn {_index, block} -> block end)
  end

  defp tool_calls(state) do
    for %{type: :tool_use} = block <- ordered_blocks(state), is_binary(block.id) do
      name = Map.get(state.tool_names, block.name, block.name)

      %{
        "id" => block.id,
        "name" => name,
        "arguments" => JSON.encode!(block.input || %{})
      }
    end
  end

  # `Tackle.Lib.LLM` stamps the provider and model it is replayed to; the
  # auth mode is checked here (`Tackle.Plugins.Anthropic.Convert`).
  defp provider_state(state) do
    %{
      "oauth" => state.is_oauth,
      "stop_reason" => state.stop_reason,
      "content_blocks" => provider_blocks(state)
    }
  end

  defp provider_blocks(state) do
    state
    |> ordered_blocks()
    |> Enum.flat_map(&provider_block/1)
  end

  defp provider_block(%{type: :text, text: text}) when is_binary(text) and text != "",
    do: [%{"type" => "text", "text" => text}]

  defp provider_block(%{type: :thinking, thinking: thinking, signature: signature})
       when is_binary(thinking) and thinking != "" do
    if is_binary(signature) and signature != "" do
      [%{"type" => "thinking", "thinking" => thinking, "signature" => signature}]
    else
      [%{"type" => "text", "text" => thinking}]
    end
  end

  defp provider_block(%{type: :redacted_thinking, data: data})
       when is_binary(data) and data != "" do
    [%{"type" => "redacted_thinking", "data" => data}]
  end

  defp provider_block(%{type: :tool_use, id: id, name: name, input: input})
       when is_binary(id) and is_binary(name) do
    [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input || %{}}]
  end

  defp provider_block(_block), do: []

  # `message_start` and `message_delta` each report part of the usage; later
  # reported values win.
  defp merge_usage(merged, %{} = usage),
    do: Map.merge(merged, Map.reject(usage, fn {_key, value} -> is_nil(value) end))

  defp merge_usage(merged, _usage), do: merged

  # Anthropic's input buckets are already disjoint: `input_tokens` excludes
  # cache reads and writes.
  defp usage(raw) when map_size(raw) == 0, do: nil

  defp usage(raw) do
    Usage.new(
      input_tokens: raw["input_tokens"],
      output_tokens: raw["output_tokens"],
      cache_read_tokens: raw["cache_read_input_tokens"],
      cache_write_tokens: raw["cache_creation_input_tokens"],
      reasoning_tokens: get_in(raw, ["output_tokens_details", "thinking_tokens"]),
      raw: raw
    )
  end

  defp emit_usage(%{usage_emitted?: true} = state, _callback), do: state

  defp emit_usage(%{usage: raw} = state, callback) when map_size(raw) > 0 do
    emit(callback, %{type: :usage, usage: usage(raw)})
    %{state | usage_emitted?: true}
  end

  defp emit_usage(state, _callback), do: state

  defp structured_data(content) do
    case JSON.decode(content) do
      {:ok, %{} = data} -> {:ok, data}
      {:ok, _other} -> {:error, :structured_response_not_an_object}
      {:error, _reason} -> {:error, :invalid_structured_response}
    end
  end

  defp present_string(""), do: nil
  defp present_string(value), do: value

  defp text_or_empty(value) when is_binary(value), do: value
  defp text_or_empty(_value), do: ""

  defp truncate(value, limit) when is_binary(value) and byte_size(value) > limit,
    do: binary_part(value, 0, limit)

  defp truncate(value, _limit), do: value

  defp emit(callback, event) when is_function(callback, 1), do: callback.(event)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
