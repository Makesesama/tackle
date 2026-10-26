defmodule Tackle.Plugins.Ollama.SSETest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.LLM.Error
  alias Tackle.Lib.Usage
  alias Tackle.Plugins.Ollama.SSE

  @noop &Function.identity/1

  test "reasoning, CRLF and arbitrary byte boundaries preserve deltas and usage" do
    wire =
      ": keepalive\r\n\r\n" <>
        frame(%{"reasoning" => "think", "reasoning_content" => "think"}) <>
        frame(%{"content" => "héllo"}) <>
        frame(%{}, "stop") <>
        sse(%{
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => 10,
            "completion_tokens" => 3,
            "prompt_tokens_details" => %{"cached_tokens" => 4}
          }
        }) <> "data: [DONE]\r\n\r\n"

    parser =
      Enum.reduce(:binary.bin_to_list(wire), SSE.new(), fn byte, acc ->
        SSE.push(acc, <<byte>>, &send(self(), {:event, &1}))
      end)

    assert {:ok, result} = parser |> SSE.finish(@noop) |> SSE.result("m", nil)
    assert result.data == %{"content" => "héllo", "thinking" => "think", "tool_calls" => []}
    assert result.stop_reason == :end

    assert result.provider_state == %{"reasoning" => "think"}

    assert %Usage{input_tokens: 6, cache_read_tokens: 4, total_tokens: 13} = result.usage
    assert_received {:event, %{type: :reasoning_delta, delta: "think"}}
    refute_received {:event, %{type: :reasoning_delta}}
    assert_received {:event, %{type: :usage}}
    refute_received {:event, %{type: :usage}}
  end

  test "tool identities are stable across interleaved fragments and unique per completion" do
    wire =
      frame(%{"tool_calls" => [call(1, nil, "b", "{"), call(0, "wire-id", "a", "{")]}) <>
        frame(%{"tool_calls" => [call(0, nil, nil, "}"), call(1, "late-id", nil, "}")]}) <>
        frame(%{}, "tool_calls") <> "data: [DONE]\n\n"

    parser = SSE.push(SSE.new(), wire, &send(self(), {:event, &1}))
    assert {:ok, result} = SSE.result(parser, "m", nil)
    assert result.stop_reason == :tool_calls

    assert [%{"id" => "wire-id", "name" => "a", "arguments" => "{}"}, generated] =
             result.data["tool_calls"]

    assert generated["name"] == "b"
    assert generated["arguments"] == "{}"
    assert_received {:event, %{type: :tool_input_delta, tool_call_id: "wire-id", delta: "{"}}
    assert_received {:event, %{type: :tool_input_delta, tool_call_id: "wire-id", delta: "}"}}
    id = generated["id"]
    assert_received {:event, %{type: :tool_input_delta, tool_call_id: ^id, delta: "{"}}
    assert_received {:event, %{type: :tool_input_delta, tool_call_id: ^id, delta: "}"}}

    assert {:ok, another} = SSE.new() |> SSE.push(wire, @noop) |> SSE.result("m", nil)
    refute Enum.at(another.data["tool_calls"], 1)["id"] == id
  end

  test "entirely id-less tool calls keep one identity across fragments" do
    wire =
      frame(%{"tool_calls" => [call(0, nil, "a", "{")]}) <>
        frame(%{"tool_calls" => [call(0, nil, nil, "}")]}) <>
        frame(%{}, "tool_calls") <> "data: [DONE]\n\n"

    assert {:ok, result} =
             SSE.new() |> SSE.push(wire, &send(self(), {:event, &1})) |> SSE.result("m", nil)

    [tool] = result.data["tool_calls"]
    id = tool["id"]
    assert_received {:event, %{type: :tool_input_delta, tool_call_id: ^id, delta: "{"}}
    assert_received {:event, %{type: :tool_input_delta, tool_call_id: ^id, delta: "}"}}
  end

  test "rejects malformed, truncated and incomplete streams" do
    cases = [
      {"data: {oops\n\n", {:invalid_sse_json, "{oops"}},
      {frame(%{"content" => "partial"}), :stream_ended_without_finish_reason},
      {frame(%{}, "stop"), :stream_ended_without_done},
      {frame(%{}, "length") <> "data: [DONE]\n\n", {:incomplete_response, "length"}},
      {frame(%{}, "stop") <> frame(%{"content" => "late"}), :data_after_finish_reason},
      {frame(%{"tool_calls" => [call(0, "id", "a", "[]")]}, "tool_calls") <> "data: [DONE]\n\n",
       :tool_call_arguments_not_an_object},
      {frame(%{"tool_calls" => [call(0, "id", nil, "{}")]}, "tool_calls") <> "data: [DONE]\n\n",
       :missing_tool_call_name},
      {frame(
         %{"tool_calls" => [call(0, "id", "a", "{}"), call(1, "id", "b", "{}")]},
         "tool_calls"
       ) <> "data: [DONE]\n\n", :duplicate_tool_call_id},
      {frame(%{"tool_calls" => [call(0, "id", "a", "{}"), call(0, "other", "b", "{}")]}),
       :duplicate_tool_call_index}
    ]

    truncated = [:stream_ended_without_finish_reason, :stream_ended_without_done]

    for {wire, error} <- cases do
      kind = if error in truncated, do: :transport, else: :invalid_response

      assert {:error, %Error{kind: ^kind, details: ^error}} =
               SSE.new() |> SSE.push(wire, @noop) |> SSE.finish(@noop) |> SSE.result("m", nil)
    end
  end

  test "provider errors, conflicting ids and cancellation remain failures" do
    wire =
      frame(%{"tool_calls" => [call(0, "one", "a", "{")]}) <>
        frame(%{"tool_calls" => [call(0, "two", nil, "}")]})

    assert {:error,
            %Error{kind: :invalid_response, details: {:conflicting_tool_call_identity, :id}}} =
             SSE.new() |> SSE.push(wire, @noop) |> SSE.result("m", nil)

    assert {:error, %Error{kind: :unknown, message: "The provider request failed: failed"}} =
             SSE.new() |> SSE.push(sse(%{"error" => "failed"}), @noop) |> SSE.result("m", nil)

    assert {:error, :cancelled} = SSE.new() |> SSE.cancel() |> SSE.result("m", nil)
  end

  defp call(index, id, name, arguments),
    do: %{"index" => index, "id" => id, "function" => %{"name" => name, "arguments" => arguments}}

  defp frame(delta, finish \\ nil),
    do: sse(%{"choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]})

  defp sse(event), do: "data: #{JSON.encode!(event)}\r\n\r\n"
end
