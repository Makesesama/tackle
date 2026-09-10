defmodule Tackle.Plugins.DeepSeek.SSETest do
  use ExUnit.Case, async: true

  alias Tackle.Plugins.DeepSeek.SSE

  test "buffers split lines and accepts CRLF-delimited events" do
    wire =
      "data: " <>
        JSON.encode!(%{
          "model" => "deepseek-chat-actual",
          "choices" => [
            %{"delta" => %{"content" => "hello"}, "finish_reason" => "stop"}
          ]
        }) <>
        "\r\n\r\ndata: [DONE]\r\n\r\n"

    <<first::binary-size(13), rest::binary>> = wire

    parser =
      SSE.new()
      |> SSE.push(first, fn event -> send(self(), event) end)
      |> SSE.push(rest, fn event -> send(self(), event) end)
      |> SSE.finish(fn event -> send(self(), event) end)

    assert {:ok, result} = SSE.result(parser, "deepseek-chat", nil)
    assert result.model == "deepseek-chat-actual"
    assert result.data == %{"content" => "hello", "tool_calls" => []}
    assert_receive %{type: :text_delta, delta: "hello"}
  end

  test "requires a successful finish reason" do
    parser =
      SSE.new()
      |> SSE.push(
        event(%{"choices" => [%{"delta" => %{"content" => "partial"}, "finish_reason" => nil}]}),
        fn _event -> :ok end
      )
      |> SSE.finish(fn _event -> :ok end)

    assert {:error, :stream_ended_without_finish_reason} =
             SSE.result(parser, "deepseek-chat", nil)
  end

  test "reports incomplete and provider error responses" do
    incomplete =
      SSE.new()
      |> SSE.push(
        event(%{"choices" => [%{"delta" => %{}, "finish_reason" => "length"}]}),
        fn _event -> :ok end
      )
      |> SSE.finish(fn _event -> :ok end)

    assert {:error, {:incomplete_response, "length"}} =
             SSE.result(incomplete, "deepseek-chat", nil)

    provider_error =
      SSE.new()
      |> SSE.push(event(%{"error" => %{"message" => "bad request"}}), fn _event -> :ok end)
      |> SSE.finish(fn _event -> :ok end)

    assert {:error, {:provider_error, %{"message" => "bad request"}}} =
             SSE.result(provider_error, "deepseek-chat", nil)
  end

  test "reports malformed SSE JSON and malformed structured output" do
    malformed =
      SSE.new()
      |> SSE.push("data: {not-json}\n\n", fn _event -> :ok end)
      |> SSE.finish(fn _event -> :ok end)

    assert {:error, {:invalid_sse_json, "{not-json}"}} =
             SSE.result(malformed, "deepseek-chat", nil)

    structured =
      SSE.new()
      |> SSE.push(
        event(%{
          "choices" => [%{"delta" => %{"content" => "not-json"}, "finish_reason" => "stop"}]
        }),
        fn _event -> :ok end
      )
      |> SSE.finish(fn _event -> :ok end)

    assert {:error, :invalid_structured_response} =
             SSE.result(structured, "deepseek-chat", answer: [type: :string])
  end

  test "normalizes standard cached-token usage details" do
    parser =
      SSE.new()
      |> SSE.push(
        event(%{
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
          "usage" => %{
            "prompt_tokens" => 20,
            "completion_tokens" => 5,
            "total_tokens" => 25,
            "prompt_tokens_details" => %{"cached_tokens" => 6, "cache_write_tokens" => 2},
            "completion_tokens_details" => %{"reasoning_tokens" => 3}
          }
        }),
        fn event -> send(self(), event) end
      )
      |> SSE.finish(fn event -> send(self(), event) end)

    assert {:ok, result} = SSE.result(parser, "deepseek-reasoner", nil)

    assert result.usage == %{
             "input_tokens" => 12,
             "output_tokens" => 5,
             "reasoning_tokens" => 3,
             "cached_input_tokens" => 6,
             "cache_write_tokens" => 2,
             "total_tokens" => 25,
             "provider_usage" => %{
               "prompt_tokens" => 20,
               "completion_tokens" => 5,
               "total_tokens" => 25,
               "prompt_tokens_details" => %{
                 "cached_tokens" => 6,
                 "cache_write_tokens" => 2
               },
               "completion_tokens_details" => %{"reasoning_tokens" => 3}
             }
           }

    assert_receive %{type: :usage, usage: streamed_usage}
    assert streamed_usage == result.usage
  end

  defp event(payload), do: "data: #{JSON.encode!(payload)}\n\n"
end
