defmodule Tackle.Plugins.DeepSeek.SSETest do
  use ExUnit.Case, async: true

  alias Tackle.Plugins.DeepSeek.SSE

  test "buffers arbitrary UTF-8 splits and accepts comments, multiline data, and CRLF" do
    payload =
      JSON.encode!(%{
        "model" => "deepseek-flash-actual",
        "choices" => [%{"delta" => %{"content" => "héllo"}, "finish_reason" => "stop"}]
      })

    {left, right} = split_once(payload, ",")
    wire = ": keepalive\r\ndata: #{left},\r\ndata: #{right}\r\n\r\ndata: [DONE]\r\n\r\n"
    {utf8_at, 2} = :binary.match(wire, "é")
    <<first::binary-size(utf8_at + 1), rest::binary>> = wire

    parser =
      SSE.new()
      |> SSE.push(first, fn event -> send(self(), event) end)
      |> SSE.push(rest, fn event -> send(self(), event) end)
      |> SSE.finish(fn event -> send(self(), event) end)

    assert {:ok, result} = SSE.result(parser, "deepseek-flash", nil)
    assert result.model == "deepseek-flash-actual"
    assert result.data == %{"content" => "héllo", "tool_calls" => []}
    assert_receive %{type: :text_delta, delta: "héllo"}
  end

  test "requires both a successful finish reason and DONE" do
    unfinished =
      SSE.new()
      |> SSE.push(
        event(%{"choices" => [%{"delta" => %{"content" => "partial"}, "finish_reason" => nil}]}),
        fn _event -> :ok end
      )
      |> SSE.push("data: [DONE]\n\n", fn _event -> :ok end)

    assert {:error, :stream_ended_without_finish_reason} =
             SSE.result(unfinished, "deepseek-flash", nil)

    missing_done =
      SSE.new()
      |> SSE.push(
        event(%{
          "choices" => [%{"delta" => %{"content" => "complete"}, "finish_reason" => "stop"}]
        }),
        fn _event -> :ok end
      )
      |> SSE.finish(fn _event -> :ok end)

    assert {:error, :stream_ended_without_done} = SSE.result(missing_done, "deepseek-flash", nil)
  end

  test "reports incomplete responses and lets a provider error override parser errors" do
    incomplete =
      SSE.new()
      |> SSE.push(
        event(%{"choices" => [%{"delta" => %{}, "finish_reason" => "length"}]}),
        fn _event -> :ok end
      )
      |> SSE.finish(fn _event -> :ok end)

    assert {:error, {:incomplete_response, "length"}} =
             SSE.result(incomplete, "deepseek-flash", nil)

    provider_error =
      SSE.new()
      |> SSE.push("data: {not-json}\n\n", fn _event -> :ok end)
      |> SSE.push(event(%{"error" => %{"message" => "bad request"}}), fn _event -> :ok end)
      |> SSE.finish(fn _event -> :ok end)

    assert {:error, {:provider_error, %{"message" => "bad request"}}} =
             SSE.result(provider_error, "deepseek-flash", nil)
  end

  test "reports malformed SSE JSON and malformed structured output" do
    malformed =
      SSE.new()
      |> SSE.push("data: {not-json}\n\n", fn _event -> :ok end)
      |> SSE.finish(fn _event -> :ok end)

    assert {:error, {:invalid_sse_json, "{not-json}"}} =
             SSE.result(malformed, "deepseek-flash", nil)

    structured =
      SSE.new()
      |> SSE.push(
        event(%{
          "choices" => [%{"delta" => %{"content" => "not-json"}, "finish_reason" => "stop"}]
        }),
        fn _event -> :ok end
      )
      |> SSE.push("data: [DONE]\n\n", fn _event -> :ok end)

    assert {:error, :invalid_structured_response} =
             SSE.result(structured, "deepseek-flash", answer: [type: :string])
  end

  test "defers usage until DONE and keeps cache buckets disjoint" do
    callback = fn event -> send(self(), event) end

    parser =
      SSE.new()
      |> SSE.push(
        event(%{
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2, "total_tokens" => 12}
        }),
        callback
      )
      |> SSE.push(
        event(%{
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => 20,
            "completion_tokens" => 5,
            "total_tokens" => 25,
            "prompt_tokens_details" => %{"cached_tokens" => 6, "cache_write_tokens" => 2},
            "completion_tokens_details" => %{"reasoning_tokens" => 3}
          }
        }),
        callback
      )

    refute_receive %{type: :usage}
    parser = SSE.push(parser, "data: [DONE]\n\n", callback)

    assert {:ok, result} = SSE.result(parser, "deepseek-v4-pro", nil)

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
    refute_receive %{type: :usage}
  end

  test "rejects missing, empty, and multiple choices except trailing usage" do
    for payload <- [
          %{"usage" => %{"prompt_tokens" => 1}},
          %{"choices" => []},
          %{"choices" => [%{"delta" => %{}}, %{"delta" => %{}}]}
        ] do
      parser = SSE.new() |> SSE.push(event(payload), fn _event -> :ok end)
      assert {:error, _reason} = SSE.result(parser, "deepseek-flash", nil)
    end
  end

  test "rejects semantic chunks after a finish reason" do
    parser =
      SSE.new()
      |> SSE.push(
        event(%{"choices" => [%{"delta" => %{"content" => "one"}, "finish_reason" => "stop"}]}),
        fn _event -> :ok end
      )
      |> SSE.push(
        event(%{"choices" => [%{"delta" => %{"content" => "two"}, "finish_reason" => nil}]}),
        fn _event -> :ok end
      )
      |> SSE.push("data: [DONE]\n\n", fn _event -> :ok end)

    assert {:error, :data_after_finish_reason} = SSE.result(parser, "deepseek-flash", nil)
  end

  test "validates completed tool identity and object arguments" do
    cases = [
      {[
         %{
           "index" => 0,
           "id" => "call-1",
           "function" => %{"name" => "search", "arguments" => "{"}
         }
       ], :invalid_tool_call_arguments_json},
      {[%{"index" => 0, "function" => %{"name" => "search", "arguments" => "{}"}}],
       :missing_tool_call_id},
      {[%{"index" => 0, "id" => "call-1", "function" => %{"arguments" => "{}"}}],
       :missing_tool_call_name},
      {[
         %{
           "index" => 0,
           "id" => "call-1",
           "function" => %{"name" => "search", "arguments" => "[]"}
         }
       ], :tool_call_arguments_not_an_object},
      {[
         %{
           "index" => -1,
           "id" => "call-1",
           "function" => %{"name" => "search", "arguments" => "{}"}
         }
       ], :invalid_tool_call_index}
    ]

    for {tool_calls, expected} <- cases do
      parser = completed_tool_stream([tool_calls])
      assert {:error, ^expected} = SSE.result(parser, "deepseek-v4-pro", nil)
    end
  end

  test "rejects conflicting tool identity and duplicate completed IDs" do
    conflicting =
      completed_tool_stream([
        [
          %{
            "index" => 0,
            "id" => "call-1",
            "function" => %{"name" => "search", "arguments" => "{"}
          }
        ],
        [%{"index" => 0, "id" => "call-2", "function" => %{"arguments" => "}"}}]
      ])

    assert {:error, {:conflicting_tool_call_identity, :id}} =
             SSE.result(conflicting, "deepseek-v4-pro", nil)

    duplicate =
      completed_tool_stream([
        [
          %{"index" => 0, "id" => "same", "function" => %{"name" => "one", "arguments" => "{}"}},
          %{"index" => 1, "id" => "same", "function" => %{"name" => "two", "arguments" => "{}"}}
        ]
      ])

    assert {:error, :duplicate_tool_call_id} = SSE.result(duplicate, "deepseek-v4-pro", nil)
  end

  test "ignores all data after DONE" do
    parser =
      SSE.new()
      |> SSE.push(
        complete_event("first") <>
          "data: [DONE]\n\n" <>
          complete_event("second"),
        fn _event -> :ok end
      )
      |> SSE.finish(fn _event -> :ok end)

    assert {:ok, result} = SSE.result(parser, "deepseek-flash", nil)
    assert result.data["content"] == "first"
  end

  defp completed_tool_stream(tool_chunks) do
    callback = fn _event -> :ok end

    parser =
      Enum.reduce(tool_chunks, SSE.new(), fn tool_calls, parser ->
        SSE.push(
          parser,
          event(%{
            "choices" => [
              %{"delta" => %{"tool_calls" => tool_calls}, "finish_reason" => nil}
            ]
          }),
          callback
        )
      end)

    parser
    |> SSE.push(
      event(%{"choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]}),
      callback
    )
    |> SSE.push("data: [DONE]\n\n", callback)
  end

  defp complete_event(content) do
    event(%{"choices" => [%{"delta" => %{"content" => content}, "finish_reason" => "stop"}]})
  end

  defp split_once(binary, pattern) do
    {at, size} = :binary.match(binary, pattern)
    <<left::binary-size(at), _pattern::binary-size(size), right::binary>> = binary
    {left, right}
  end

  defp event(payload), do: "data: #{JSON.encode!(payload)}\n\n"
end
