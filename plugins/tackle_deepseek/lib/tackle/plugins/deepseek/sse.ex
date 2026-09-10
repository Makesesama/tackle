defmodule Tackle.Plugins.DeepSeek.SSE do
  @moduledoc false

  @enforce_keys []
  defstruct buffer: "",
            data_lines: [],
            content: "",
            thinking: "",
            tool_calls: %{},
            usage: nil,
            model: nil,
            finish_reason: nil,
            terminal?: false,
            done?: false,
            error: nil,
            cancelled?: false

  @type t :: %__MODULE__{
          buffer: binary(),
          data_lines: [binary()],
          content: binary(),
          thinking: binary(),
          tool_calls: %{optional(non_neg_integer()) => map()},
          usage: map() | nil,
          model: String.t() | nil,
          finish_reason: String.t() | nil,
          terminal?: boolean(),
          done?: boolean(),
          error: term() | nil,
          cancelled?: boolean()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = state), do: %{state | cancelled?: true}

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
    do: {:error, :stream_ended_without_finish_reason}

  def result(%__MODULE__{} = state, requested_model, schema) do
    tool_calls =
      state.tool_calls
      |> Enum.sort_by(fn {index, _call} -> index end)
      |> Enum.map(fn {_index, call} -> call end)

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
         provider_state: provider_state(state.thinking, requested_model)
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
      "[DONE]" -> %{state | done?: true}
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

  defp handle_event(state, %{"error" => error}, _callback),
    do: put_error(state, {:provider_error, error})

  defp handle_event(state, event, callback) do
    state =
      case string_or_nil(event["model"]) do
        nil -> state
        model -> %{state | model: model}
      end

    state = apply_usage(state, event["usage"], callback)

    case event["choices"] do
      [choice | _choices] when is_map(choice) -> apply_choice(state, choice, callback)
      _choices -> state
    end
  end

  defp apply_choice(state, choice, callback) do
    state = apply_delta(state, choice["delta"], callback)

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
  end

  defp apply_delta(state, delta, callback) when is_map(delta) do
    state = append_text_delta(state, delta["content"], callback)
    state = append_reasoning_delta(state, delta["reasoning_content"], callback)
    append_tool_deltas(state, delta["tool_calls"], callback)
  end

  defp apply_delta(state, _delta, _callback), do: state

  defp append_text_delta(state, delta, callback) when is_binary(delta) and delta != "" do
    emit(callback, %{type: :text_delta, delta: delta})
    %{state | content: state.content <> delta}
  end

  defp append_text_delta(state, _delta, _callback), do: state

  defp append_reasoning_delta(state, delta, callback) when is_binary(delta) and delta != "" do
    emit(callback, %{type: :reasoning_delta, delta: delta})
    %{state | thinking: state.thinking <> delta}
  end

  defp append_reasoning_delta(state, _delta, _callback), do: state

  defp append_tool_deltas(state, tool_calls, callback) when is_list(tool_calls) do
    tool_calls
    |> Enum.with_index()
    |> Enum.reduce(state, fn
      {%{} = delta, fallback_index}, acc ->
        index = non_negative_integer(delta["index"]) || fallback_index
        function = if is_map(delta["function"]), do: delta["function"], else: %{}
        existing = Map.get(acc.tool_calls, index, empty_call())

        call = %{
          "id" => string_or_nil(delta["id"]) || existing["id"],
          "name" => string_or_nil(function["name"]) || existing["name"],
          "arguments" => existing["arguments"] <> binary_or_empty(function["arguments"])
        }

        arguments_delta = binary_or_empty(function["arguments"])

        if arguments_delta != "" do
          emit(callback, %{
            type: :tool_input_delta,
            delta: arguments_delta,
            tool_call_id: call["id"],
            tool_name: call["name"]
          })
        end

        %{acc | tool_calls: Map.put(acc.tool_calls, index, call)}

      {_delta, _fallback_index}, acc ->
        acc
    end)
  end

  defp append_tool_deltas(state, _tool_calls, _callback), do: state

  defp apply_usage(state, usage, callback) when is_map(usage) do
    normalized = normalize_usage(usage)
    emit(callback, %{type: :usage, usage: normalized})
    %{state | usage: normalized}
  end

  defp apply_usage(state, _usage, _callback), do: state

  defp normalize_usage(usage) do
    cache_read =
      non_negative_integer(get_in(usage, ["prompt_tokens_details", "cached_tokens"])) ||
        non_negative_integer(usage["prompt_cache_hit_tokens"]) || 0

    cache_write =
      non_negative_integer(get_in(usage, ["prompt_tokens_details", "cache_write_tokens"])) || 0

    prompt_tokens = non_negative_integer(usage["prompt_tokens"])

    input_tokens =
      non_negative_integer(usage["prompt_cache_miss_tokens"]) ||
        subtract_cached(prompt_tokens, cache_read + cache_write)

    %{}
    |> maybe_put("input_tokens", input_tokens)
    |> maybe_put("output_tokens", non_negative_integer(usage["completion_tokens"]))
    |> maybe_put(
      "reasoning_tokens",
      non_negative_integer(get_in(usage, ["completion_tokens_details", "reasoning_tokens"]))
    )
    |> maybe_put("cached_input_tokens", cache_read)
    |> maybe_put("cache_write_tokens", cache_write)
    |> maybe_put("total_tokens", non_negative_integer(usage["total_tokens"]))
    |> Map.put("provider_usage", usage)
  end

  defp structured_data(content) do
    case JSON.decode(content) do
      {:ok, %{} = data} -> {:ok, data}
      {:ok, _other} -> {:error, :structured_response_not_an_object}
      {:error, _reason} -> {:error, :invalid_structured_response}
    end
  end

  defp provider_state("", _model), do: nil

  defp provider_state(reasoning_content, model) do
    %{
      "provider" => "deepseek",
      "model" => model,
      "reasoning_content" => reasoning_content
    }
  end

  defp empty_call, do: %{"id" => nil, "name" => nil, "arguments" => ""}
  defp put_error(%__MODULE__{error: nil} = state, error), do: %{state | error: error}
  defp put_error(state, _error), do: state
  defp emit(callback, event) when is_function(callback, 1), do: callback.(event)
  defp present_string(""), do: nil
  defp present_string(value), do: value
  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil
  defp binary_or_empty(value) when is_binary(value), do: value
  defp binary_or_empty(_value), do: ""
  defp subtract_cached(nil, _cached), do: nil
  defp subtract_cached(total, cached), do: max(0, total - cached)
  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(value) when is_float(value) and value >= 0, do: trunc(value)
  defp non_negative_integer(_value), do: nil
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
