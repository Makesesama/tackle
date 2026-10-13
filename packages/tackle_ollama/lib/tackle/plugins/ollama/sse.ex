defmodule Tackle.Plugins.Ollama.SSE do
  @moduledoc false

  # Ollama's OpenAI-compatible stream ends with a finish-reason frame,
  # an optional empty-choices usage frame, and [DONE]. Tool ids may be absent.

  defstruct buffer: "",
            provider: nil,
            id_prefix: nil,
            generated_indices: MapSet.new(),
            data_lines: [],
            content: "",
            thinking: "",
            tool_calls: %{},
            usage: nil,
            usage_emitted?: false,
            model: nil,
            finish_reason: nil,
            terminal?: false,
            done?: false,
            error: nil,
            cancelled?: false

  @type t :: %__MODULE__{
          buffer: binary(),
          provider: String.t(),
          id_prefix: String.t(),
          generated_indices: MapSet.t(),
          data_lines: [binary()],
          content: binary(),
          thinking: binary(),
          tool_calls: %{optional(non_neg_integer()) => map()},
          usage: map() | nil,
          usage_emitted?: boolean(),
          model: String.t() | nil,
          finish_reason: String.t() | nil,
          terminal?: boolean(),
          done?: boolean(),
          error: term() | nil,
          cancelled?: boolean()
        }

  # `provider` is the adapter id recorded in reasoning provider state and used
  # as the prefix of synthesized tool-call ids.
  @spec new(String.t()) :: t()
  def new(provider \\ "ollama-cloud") when is_binary(provider) do
    %__MODULE__{
      provider: provider,
      id_prefix:
        provider <>
          "-generated-" <>
          Base.encode16(:crypto.strong_rand_bytes(12), case: :lower) <> "-"
    }
  end

  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = state), do: %{state | cancelled?: true}

  @doc "Whether any text, reasoning, or tool-call output was received."
  @spec output?(t()) :: boolean()
  def output?(%__MODULE__{} = state),
    do: state.content != "" or state.thinking != "" or map_size(state.tool_calls) > 0

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
    do: {:error, :stream_ended_without_finish_reason}

  def result(%__MODULE__{done?: false}, _requested_model, _schema),
    do: {:error, :stream_ended_without_done}

  def result(%__MODULE__{} = state, requested_model, schema) do
    tool_calls = ordered_tool_calls(state)

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
         usage: state.usage,
         model: state.model || requested_model,
         provider_state: provider_state(state, requested_model)
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

      # SSE comments may keep the connection alive.
      <<":", _rest::binary>> ->
        state

      <<"data:", data::binary>> ->
        %{state | data_lines: [trim_optional_space(data) | state.data_lines]}

      _other ->
        state
    end
  end

  defp dispatch_event(%__MODULE__{data_lines: []} = state, _callback), do: state

  defp dispatch_event(%__MODULE__{} = state, callback) do
    payload = state.data_lines |> Enum.reverse() |> Enum.join("\n")
    state = %{state | data_lines: []}

    case payload do
      "[DONE]" -> complete_stream(state, callback)
      _payload -> decode_event(state, payload, callback)
    end
  end

  defp complete_stream(%__MODULE__{done?: true} = state, _callback), do: state

  defp complete_stream(state, callback) do
    state = %{state | done?: true}

    state =
      if is_nil(state.error) and state.terminal? do
        state |> default_empty_arguments() |> validate_tool_calls()
      else
        state
      end

    if is_nil(state.error) and state.terminal? and is_map(state.usage) and
         not state.usage_emitted? do
      emit(callback, %{type: :usage, usage: state.usage})
      %{state | usage_emitted?: true}
    else
      state
    end
  end

  defp decode_event(state, payload, callback) do
    case JSON.decode(payload) do
      {:ok, %{} = event} -> handle_event(state, event, callback)
      {:ok, _other} -> put_error(state, :invalid_sse_event)
      {:error, _reason} -> put_error(state, {:invalid_sse_json, truncate(payload, 512)})
    end
  end

  defp handle_event(state, %{"error" => error}, _callback) when not is_nil(error),
    do: put_error(state, {:provider_error, error})

  defp handle_event(state, event, callback) do
    state = put_response_model(state, event["model"])

    cond do
      not is_nil(state.error) ->
        state

      state.terminal? ->
        handle_after_terminal(state, event)

      true ->
        handle_choices(state, event, callback)
    end
  end

  # Ollama repeats the terminal finish_reason on a content-free choice in
  # the usage chunk. That frame is accounting only; real output after the
  # finish reason is still rejected.
  defp handle_after_terminal(state, %{"choices" => choices} = event) when is_list(choices) do
    if Enum.all?(choices, &accounting_choice?(&1, state.finish_reason)) do
      maybe_apply_usage(state, event["usage"])
    else
      put_error(state, :data_after_finish_reason)
    end
  end

  defp handle_after_terminal(state, _event), do: put_error(state, :data_after_finish_reason)

  defp accounting_choice?(%{} = choice, finish_reason) do
    choice["finish_reason"] in [nil, finish_reason] and
      case choice["delta"] do
        nil -> true
        %{} = delta -> content_free_delta?(delta)
        _delta -> false
      end
  end

  defp accounting_choice?(_choice, _finish_reason), do: false

  defp content_free_delta?(delta) do
    delta["content"] in [nil, ""] and delta["reasoning"] in [nil, ""] and
      delta["reasoning_content"] in [nil, ""] and delta["tool_calls"] in [nil, []] and
      delta["reasoning_details"] in [nil, []]
  end

  defp handle_choices(state, %{"choices" => [%{} = choice]} = event, callback) do
    state
    |> apply_choice(choice, callback)
    |> maybe_apply_usage(event["usage"])
  end

  defp handle_choices(state, %{"choices" => []} = event, _callback),
    do: maybe_apply_usage(state, event["usage"])

  defp handle_choices(state, %{"choices" => choices}, _callback) when is_list(choices),
    do: put_error(state, {:invalid_sse_choices, length(choices)})

  defp handle_choices(state, _event, _callback), do: put_error(state, :invalid_sse_choices)

  defp maybe_apply_usage(%__MODULE__{error: nil} = state, %{} = usage),
    do: %{state | usage: normalize_usage(usage)}

  defp maybe_apply_usage(state, _usage), do: state

  defp apply_choice(state, choice, callback) do
    state = apply_delta(state, choice["delta"], callback)

    if is_nil(state.error) do
      case choice["finish_reason"] do
        reason when reason in [nil, ""] ->
          state

        reason when reason in ["stop", "tool_calls", "function_call", "end"] ->
          %{state | finish_reason: reason, terminal?: true}

        "length" ->
          put_error(state, {:incomplete_response, "length"})

        reason ->
          put_error(state, {:provider_finish_reason, reason})
      end
    else
      state
    end
  end

  defp apply_delta(state, delta, callback) when is_map(delta) do
    state
    |> append_text_delta(delta["content"], callback)
    |> append_reasoning_delta(reasoning_text(delta), callback)
    |> append_tool_deltas(delta["tool_calls"], callback)
  end

  defp apply_delta(state, nil, _callback), do: state
  defp apply_delta(state, _delta, _callback), do: put_error(state, :invalid_sse_delta)

  # `reasoning_content` is a documented alias of `reasoning`; some upstreams
  # send both with the same text, so only the first non-empty field is used.
  defp reasoning_text(delta) do
    Enum.find_value(["reasoning", "reasoning_content"], fn key ->
      case delta[key] do
        value when value in [nil, ""] -> nil
        value -> value
      end
    end)
  end

  defp append_text_delta(state, delta, callback) when is_binary(delta) and delta != "" do
    emit(callback, %{type: :text_delta, delta: delta})
    %{state | content: state.content <> delta}
  end

  defp append_text_delta(state, delta, _callback) when delta in [nil, ""], do: state
  defp append_text_delta(state, _delta, _callback), do: put_error(state, :invalid_text_delta)

  defp append_reasoning_delta(%__MODULE__{error: nil} = state, delta, callback)
       when is_binary(delta) do
    emit(callback, %{type: :reasoning_delta, delta: delta})
    %{state | thinking: state.thinking <> delta}
  end

  defp append_reasoning_delta(state, nil, _callback), do: state

  defp append_reasoning_delta(%__MODULE__{error: nil} = state, _delta, _callback),
    do: put_error(state, :invalid_reasoning_delta)

  defp append_reasoning_delta(state, _delta, _callback), do: state

  defp append_tool_deltas(state, nil, _callback), do: state
  defp append_tool_deltas(state, [], _callback), do: state

  defp append_tool_deltas(%__MODULE__{error: error} = state, _calls, _cb) when not is_nil(error),
    do: state

  defp append_tool_deltas(state, tool_calls, callback) when is_list(tool_calls) do
    {state, _seen} =
      Enum.reduce_while(tool_calls, {state, MapSet.new()}, fn delta, {acc, seen} ->
        with %{} <- delta,
             {:ok, index} <- tool_index(delta),
             {:ok, acc, delta} <- tool_identity(acc, index, delta),
             false <- MapSet.member?(seen, index),
             {:ok, call, arguments_delta} <- merge_tool_delta(acc.tool_calls[index], delta) do
          acc = accumulate_tool_delta(acc, index, call, arguments_delta, callback)
          {:cont, {acc, MapSet.put(seen, index)}}
        else
          true -> {:halt, {put_error(acc, :duplicate_tool_call_index), seen}}
          {:error, reason} -> {:halt, {put_error(acc, reason), seen}}
          _other -> {:halt, {put_error(acc, :invalid_tool_call_delta), seen}}
        end
      end)

    state
  end

  defp append_tool_deltas(state, _tool_calls, _callback),
    do: put_error(state, :invalid_tool_call_deltas)

  defp accumulate_tool_delta(acc, index, call, arguments_delta, callback) do
    if arguments_delta != "" do
      emit(callback, %{
        type: :tool_input_delta,
        delta: arguments_delta,
        tool_call_id: call["id"],
        tool_name: call["name"]
      })
    end

    %{acc | tool_calls: Map.put(acc.tool_calls, index, call)}
  end

  defp tool_index(%{"index" => index}) when is_integer(index) and index >= 0,
    do: {:ok, index}

  defp tool_index(_delta), do: {:error, :invalid_tool_call_index}

  # Never change an id already emitted to the host. A later wire id cannot
  # replace a synthesized id and orphan earlier events.
  defp tool_identity(state, index, delta) do
    cond do
      delta["id"] not in [nil, ""] and not is_binary(delta["id"]) ->
        {:error, {:invalid_tool_call_identity, :id}}

      MapSet.member?(state.generated_indices, index) ->
        {:ok, state, Map.put(delta, "id", state.tool_calls[index]["id"])}

      is_nil(state.tool_calls[index]) and delta["id"] in [nil, ""] ->
        state = %{state | generated_indices: MapSet.put(state.generated_indices, index)}
        {:ok, state, Map.put(delta, "id", state.id_prefix <> Integer.to_string(index))}

      true ->
        {:ok, state, delta}
    end
  end

  defp merge_tool_delta(existing, delta) do
    existing = existing || empty_call()

    with {:ok, function} <- optional_function(delta["function"]),
         {:ok, id} <- merge_identity(existing["id"], delta["id"], :id),
         {:ok, name} <- merge_identity(existing["name"], function["name"], :name),
         {:ok, arguments_delta} <- arguments_delta(function["arguments"]) do
      {:ok,
       %{
         "id" => id,
         "name" => name,
         "arguments" => existing["arguments"] <> arguments_delta
       }, arguments_delta}
    end
  end

  defp optional_function(nil), do: {:ok, %{}}
  defp optional_function(%{} = function), do: {:ok, function}
  defp optional_function(_function), do: {:error, :invalid_tool_call_function}

  defp merge_identity(existing, value, _field) when value in [nil, ""], do: {:ok, existing}

  defp merge_identity(nil, value, _field) when is_binary(value), do: {:ok, value}
  defp merge_identity(value, value, _field) when is_binary(value), do: {:ok, value}

  defp merge_identity(_existing, value, field) when is_binary(value),
    do: {:error, {:conflicting_tool_call_identity, field}}

  defp merge_identity(_existing, _value, field),
    do: {:error, {:invalid_tool_call_identity, field}}

  defp arguments_delta(nil), do: {:ok, ""}
  defp arguments_delta(value) when is_binary(value), do: {:ok, value}
  defp arguments_delta(_value), do: {:error, :invalid_tool_call_arguments_delta}

  defp validate_tool_calls(state) do
    calls = ordered_tool_calls(state)

    with :ok <- require_tool_calls_for_finish(calls, state.finish_reason),
         :ok <- validate_each_tool_call(calls),
         :ok <- validate_unique_tool_ids(calls) do
      state
    else
      {:error, reason} -> put_error(state, reason)
    end
  end

  # Some upstreams stream a call to an argument-less tool with no argument
  # fragments at all; that is an empty object, not malformed JSON.
  defp default_empty_arguments(state) do
    tool_calls =
      Map.new(state.tool_calls, fn
        {index, %{"arguments" => ""} = call} -> {index, %{call | "arguments" => "{}"}}
        entry -> entry
      end)

    %{state | tool_calls: tool_calls}
  end

  defp ordered_tool_calls(state) do
    state.tool_calls
    |> Enum.sort_by(fn {index, _call} -> index end)
    |> Enum.map(fn {_index, call} -> call end)
  end

  defp require_tool_calls_for_finish([], reason) when reason in ["tool_calls", "function_call"],
    do: {:error, :missing_tool_calls}

  defp require_tool_calls_for_finish(_calls, _reason), do: :ok

  defp validate_each_tool_call(calls) do
    Enum.reduce_while(calls, :ok, fn call, :ok ->
      case validate_tool_call(call) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_tool_call(call) do
    cond do
      not (is_binary(call["id"]) and call["id"] != "") ->
        {:error, :missing_tool_call_id}

      not (is_binary(call["name"]) and call["name"] != "") ->
        {:error, :missing_tool_call_name}

      true ->
        validate_tool_call_arguments(call["arguments"])
    end
  end

  defp validate_tool_call_arguments(arguments) do
    case JSON.decode(arguments) do
      {:ok, %{} = _arguments} -> :ok
      {:ok, _other} -> {:error, :tool_call_arguments_not_an_object}
      {:error, _reason} -> {:error, :invalid_tool_call_arguments_json}
    end
  end

  defp validate_unique_tool_ids(calls) do
    ids = Enum.map(calls, & &1["id"])

    if length(ids) == MapSet.size(MapSet.new(ids)),
      do: :ok,
      else: {:error, :duplicate_tool_call_id}
  end

  # Ollama reports `prompt_tokens` including cache reads and writes, and a
  # billed `cost` in USD credits. The reported cost is kept so hosts prefer it
  # over a price-card estimate.
  defp normalize_usage(usage) do
    cache_read =
      non_negative_integer(get_in(usage, ["prompt_tokens_details", "cached_tokens"])) || 0

    cache_write =
      non_negative_integer(get_in(usage, ["prompt_tokens_details", "cache_write_tokens"])) || 0

    prompt_tokens = non_negative_integer(usage["prompt_tokens"])
    output_tokens = non_negative_integer(usage["completion_tokens"])
    cost = non_negative_number(usage["cost"])

    %{}
    |> maybe_put("input_tokens", subtract_cached(prompt_tokens, cache_read + cache_write))
    |> maybe_put("output_tokens", output_tokens)
    |> maybe_put(
      "reasoning_tokens",
      non_negative_integer(get_in(usage, ["completion_tokens_details", "reasoning_tokens"]))
    )
    |> Map.put("cached_input_tokens", cache_read)
    |> Map.put("cache_write_tokens", cache_write)
    |> maybe_put(
      "total_tokens",
      compatible_total(usage["total_tokens"], prompt_tokens, output_tokens)
    )
    |> maybe_put("cost", cost)
    |> maybe_put("currency", if(cost, do: "USD"))
    |> Map.put("provider_usage", usage)
  end

  defp compatible_total(reported, prompt, completion) do
    reported = non_negative_integer(reported)

    case {prompt, completion, reported} do
      {prompt, completion, nil} when is_integer(prompt) and is_integer(completion) ->
        prompt + completion

      {prompt, completion, total} when prompt + completion == total ->
        total

      {nil, _completion, total} ->
        total

      {_prompt, nil, total} ->
        total

      _mismatch ->
        nil
    end
  end

  defp structured_data(content) do
    case JSON.decode(content) do
      {:ok, %{} = data} -> {:ok, data}
      {:ok, _other} -> {:error, :structured_response_not_an_object}
      {:error, _reason} -> {:error, :invalid_structured_response}
    end
  end

  defp put_response_model(state, nil), do: state

  defp put_response_model(%__MODULE__{model: nil} = state, model)
       when is_binary(model) and model != "",
       do: %{state | model: model}

  defp put_response_model(%__MODULE__{model: model} = state, model), do: state

  defp put_response_model(%__MODULE__{model: existing} = state, model)
       when is_binary(model) and model != "",
       do: put_error(state, {:conflicting_response_model, existing, model})

  defp put_response_model(state, _model), do: put_error(state, :invalid_response_model)

  defp provider_state(%__MODULE__{thinking: ""}, _model), do: nil

  defp provider_state(state, model) do
    %{"provider" => state.provider, "model" => model}
    |> maybe_put("reasoning", present_string(state.thinking))
  end

  defp trim_trailing_cr(<<>>), do: ""

  defp trim_trailing_cr(line) do
    if :binary.last(line) == ?\r,
      do: binary_part(line, 0, byte_size(line) - 1),
      else: line
  end

  defp trim_optional_space(<<" ", rest::binary>>), do: rest
  defp trim_optional_space(data), do: data
  defp truncate(value, limit) when byte_size(value) <= limit, do: value
  defp truncate(value, limit), do: binary_part(value, 0, limit)
  defp empty_call, do: %{"id" => nil, "name" => nil, "arguments" => ""}
  defp put_error(%__MODULE__{error: nil} = state, error), do: %{state | error: error}
  defp put_error(state, _error), do: state
  defp emit(callback, event) when is_function(callback, 1), do: callback.(event)
  defp present_string(""), do: nil
  defp present_string(value), do: value
  defp subtract_cached(nil, _cached), do: nil
  defp subtract_cached(total, cached), do: max(0, total - cached)
  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(value) when is_float(value) and value >= 0, do: trunc(value)
  defp non_negative_integer(_value), do: nil
  defp non_negative_number(value) when is_number(value) and value >= 0, do: value
  defp non_negative_number(_value), do: nil
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
