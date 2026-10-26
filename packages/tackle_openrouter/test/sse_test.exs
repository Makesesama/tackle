defmodule Tackle.Plugins.OpenRouter.SSETest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.LLM.Error
  alias Tackle.Plugins.OpenRouter.SSE

  @noop &Function.identity/1

  test "handles CRLF framing, comments, and an OpenAI-style empty-choices usage frame" do
    wire =
      ": OPENROUTER PROCESSING\r\n\r\n" <>
        "data: " <>
        JSON.encode!(%{
          "choices" => [%{"delta" => %{"content" => "hi"}, "finish_reason" => "stop"}]
        }) <>
        "\r\n\r\n" <>
        "data: " <>
        JSON.encode!(%{
          "choices" => [],
          "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 1}
        }) <>
        "\r\n\r\ndata: [DONE]\r\n\r\n"

    assert {:ok, result} =
             SSE.new() |> SSE.push(wire, @noop) |> SSE.finish(@noop) |> SSE.result("m", nil)

    assert result.data == %{"content" => "hi", "tool_calls" => []}
    assert result.usage["input_tokens"] == 3
    assert result.usage["total_tokens"] == 4
    refute Map.has_key?(result.usage, "cost")
    assert result.provider_state == nil
  end

  test "reads reasoning from the first populated alias without duplicating it" do
    delta = %{"reasoning" => "think", "reasoning_content" => "think"}

    wire =
      "data: " <>
        JSON.encode!(%{"choices" => [%{"delta" => delta, "finish_reason" => "stop"}]}) <>
        "\n\ndata: [DONE]\n\n"

    test_pid = self()
    callback = &send(test_pid, {:event, &1})

    assert {:ok, result} =
             SSE.new() |> SSE.push(wire, callback) |> SSE.finish(callback) |> SSE.result("m", nil)

    assert result.data["thinking"] == "think"

    assert result.provider_state == %{"reasoning" => "think"}

    assert_received {:event, %{type: :reasoning_delta, delta: "think"}}
    refute_received {:event, %{type: :reasoning_delta}}
  end

  test "rejects invalid JSON payloads and conflicting tool identities" do
    assert {:error, %Error{kind: :invalid_response, details: {:invalid_sse_json, "{oops"}}} =
             SSE.new()
             |> SSE.push("data: {oops\n\n", @noop)
             |> SSE.result("m", nil)

    calls = fn id ->
      %{
        "choices" => [
          %{"delta" => %{"tool_calls" => [%{"index" => 0, "id" => id}]}, "finish_reason" => nil}
        ]
      }
    end

    wire = "data: #{JSON.encode!(calls.("a"))}\n\ndata: #{JSON.encode!(calls.("b"))}\n\n"

    assert {:error,
            %Error{kind: :invalid_response, details: {:conflicting_tool_call_identity, :id}}} =
             SSE.new() |> SSE.push(wire, @noop) |> SSE.result("m", nil)
  end
end
