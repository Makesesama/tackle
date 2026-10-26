defmodule Tackle.Plugins.Anthropic.SSETest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.JSON
  alias Tackle.Lib.LLM.Error
  alias Tackle.Lib.Usage
  alias Tackle.Plugins.Anthropic.SSE

  test "accumulates text deltas, emits usage, and returns a replayable state" do
    wire =
      sse("message_start", %{
        "message" => %{
          "model" => "claude-opus-5-5",
          "usage" => %{
            "input_tokens" => 10,
            "cache_read_input_tokens" => 40,
            "cache_creation_input_tokens" => 6,
            "output_tokens" => 1
          }
        }
      }) <>
        sse("content_block_start", %{
          "index" => 0,
          "content_block" => %{"type" => "text", "text" => ""}
        }) <>
        sse("content_block_delta", %{
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "hel"}
        }) <>
        sse("content_block_delta", %{
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "lo"}
        }) <>
        sse("content_block_stop", %{"index" => 0}) <>
        sse("message_delta", %{
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{"output_tokens" => 5, "input_tokens" => nil}
        }) <>
        sse("message_stop", %{})

    {parser, events} = run(wire)

    usage = %Usage{
      input_tokens: 10,
      output_tokens: 5,
      cache_read_tokens: 40,
      cache_write_tokens: 6,
      total_tokens: 61,
      raw: %{
        "input_tokens" => 10,
        "cache_read_input_tokens" => 40,
        "cache_creation_input_tokens" => 6,
        "output_tokens" => 5
      }
    }

    assert events == [
             %{type: :text_delta, delta: "hel"},
             %{type: :text_delta, delta: "lo"},
             %{type: :usage, usage: usage}
           ]

    assert {:ok, result} = SSE.result(parser, "claude-opus-5-5", nil)
    assert result.data == %{"content" => "hello", "tool_calls" => []}
    assert result.usage == usage
    assert result.model == "claude-opus-5-5"

    assert result.provider_state == %{
             "oauth" => true,
             "stop_reason" => "end_turn",
             "content_blocks" => [%{"type" => "text", "text" => "hello"}]
           }
  end

  test "streams thinking signatures and tool use, reversing Claude Code tool names" do
    wire =
      sse("message_start", %{
        "message" => %{"model" => "claude-opus-5-5", "usage" => %{"input_tokens" => 3}}
      }) <>
        sse("content_block_start", %{
          "index" => 0,
          "content_block" => %{"type" => "thinking", "thinking" => ""}
        }) <>
        sse("content_block_delta", %{
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "why"}
        }) <>
        sse("content_block_delta", %{
          "index" => 0,
          "delta" => %{"type" => "signature_delta", "signature" => "sig-1"}
        }) <>
        sse("content_block_stop", %{"index" => 0}) <>
        sse("content_block_start", %{
          "index" => 1,
          "content_block" => %{"type" => "tool_use", "id" => "toolu_1", "name" => "Read"}
        }) <>
        sse("content_block_delta", %{
          "index" => 1,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"path\":"}
        }) <>
        sse("content_block_delta", %{
          "index" => 1,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "\"a\"}"}
        }) <>
        sse("content_block_stop", %{"index" => 1}) <>
        sse("message_delta", %{
          "delta" => %{"stop_reason" => "tool_use"},
          "usage" => %{
            "output_tokens" => 7,
            "output_tokens_details" => %{"thinking_tokens" => 2}
          }
        }) <>
        sse("message_stop", %{})

    {parser, events} = run(wire, tool_names: %{"Read" => "read"}, is_oauth: true)

    assert events == [
             %{type: :reasoning_delta, delta: "why"},
             %{
               type: :tool_input_delta,
               delta: "{\"path\":",
               tool_call_id: "toolu_1",
               tool_name: "Read"
             },
             %{
               type: :tool_input_delta,
               delta: "\"a\"}",
               tool_call_id: "toolu_1",
               tool_name: "Read"
             },
             %{
               type: :usage,
               usage: %Usage{
                 input_tokens: 3,
                 output_tokens: 7,
                 reasoning_tokens: 2,
                 total_tokens: 10,
                 raw: %{
                   "input_tokens" => 3,
                   "output_tokens" => 7,
                   "output_tokens_details" => %{"thinking_tokens" => 2}
                 }
               }
             }
           ]

    assert {:ok, result} = SSE.result(parser, "claude-opus-5-5", nil)

    assert result.data == %{
             "thinking" => "why",
             "tool_calls" => [
               %{"id" => "toolu_1", "name" => "read", "arguments" => "{\"path\":\"a\"}"}
             ]
           }

    assert result.provider_state["content_blocks"] == [
             %{"type" => "thinking", "thinking" => "why", "signature" => "sig-1"},
             %{
               "type" => "tool_use",
               "id" => "toolu_1",
               "name" => "Read",
               "input" => %{"path" => "a"}
             }
           ]
  end

  test "captures redacted thinking as a replayable block" do
    wire =
      sse("message_start", %{"message" => %{"model" => "claude-fable-5"}}) <>
        sse("content_block_start", %{
          "index" => 0,
          "content_block" => %{"type" => "redacted_thinking", "data" => "opaque"}
        }) <>
        sse("content_block_stop", %{"index" => 0}) <>
        sse("content_block_delta", %{
          "index" => 1,
          "delta" => %{"type" => "text_delta", "text" => "done"}
        }) <>
        sse("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}}) <>
        sse("message_stop", %{})

    {parser, _events} = run(wire)
    assert {:ok, result} = SSE.result(parser, "claude-fable-5", nil)

    assert Enum.any?(result.provider_state["content_blocks"], fn block ->
             block == %{"type" => "redacted_thinking", "data" => "opaque"}
           end)
  end

  test "parses structured JSON responses when a schema is supplied" do
    wire =
      sse("message_start", %{"message" => %{"model" => "claude-haiku-4-5"}}) <>
        sse("content_block_delta", %{
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "{\"answer\":42}"}
        }) <>
        sse("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}}) <>
        sse("message_stop", %{})

    {parser, _events} = run(wire)

    assert {:ok, result} =
             SSE.result(parser, "claude-haiku-4-5", answer: [value: [type: :integer]])

    assert result.data == %{"answer" => 42}
  end

  test "tolerates payloads split across arbitrary chunk boundaries" do
    wire =
      sse("message_start", %{"message" => %{"model" => "claude-sonnet-5"}}) <>
        sse("content_block_delta", %{
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "hello"}
        }) <>
        sse("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}}) <>
        sse("message_stop", %{})

    chunks =
      wire
      |> String.to_charlist()
      |> Enum.map(&<<&1>>)

    test_pid = self()

    parser =
      Enum.reduce(chunks, SSE.new(), fn chunk, acc ->
        SSE.push(acc, chunk, &send(test_pid, {:event, &1}))
      end)

    parser = SSE.finish(parser, &send(test_pid, {:event, &1}))

    assert {:ok, result} = SSE.result(parser, "claude-sonnet-5", nil)
    assert result.data["content"] == "hello"
  end

  test "surfaces provider errors, incomplete streams, and cancellation" do
    error_wire =
      sse("error", %{
        "type" => "error",
        "error" => %{"type" => "overloaded_error", "message" => "busy"}
      })

    {parser, _events} = run(error_wire)

    assert {:error,
            %Error{
              kind: :overloaded,
              message: "The provider is overloaded: busy",
              details: %{"type" => "overloaded_error", "message" => "busy"}
            } = error} = SSE.result(parser, "claude-opus-5-5", nil)

    assert Tackle.Lib.Retry.retryable?(error)

    overflow_wire =
      sse("error", %{
        "type" => "error",
        "error" => %{"type" => "invalid_request_error", "message" => "prompt is too long"}
      })

    {parser, _events} = run(overflow_wire)

    assert {:error, %Error{kind: :context_window_exceeded}} =
             SSE.result(parser, "claude-opus-5-5", nil)

    incomplete =
      sse("message_start", %{"message" => %{"model" => "claude-opus-5-5"}}) <>
        sse("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}})

    {parser, _events} = run(incomplete)

    assert {:error, %Error{kind: :transport, details: :stream_ended_without_message_stop}} =
             SSE.result(parser, "claude-opus-5-5", nil)

    assert {:error, :cancelled} = SSE.result(SSE.cancel(SSE.new()), "claude-opus-5-5", nil)
  end

  test "counts text delivered on content_block_start" do
    wire =
      sse("message_start", %{"message" => %{"model" => "claude-sonnet-5"}}) <>
        sse("content_block_start", %{
          "index" => 0,
          "content_block" => %{"type" => "text", "text" => "seed"}
        }) <>
        sse("content_block_stop", %{"index" => 0}) <>
        sse("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}}) <>
        sse("message_stop", %{})

    {parser, events} = run(wire)
    assert Enum.any?(events, &(&1 == %{type: :text_delta, delta: "seed"}))

    assert {:ok, result} = SSE.result(parser, "claude-sonnet-5", nil)
    assert result.data["content"] == "seed"
  end

  defp run(wire, opts \\ []) do
    test_pid = self()
    callback = fn event -> send(test_pid, {:event, event}) end

    parser = SSE.new(opts)
    parser = SSE.push(parser, wire, callback)
    parser = SSE.finish(parser, callback)

    {parser, drain([])}
  end

  defp drain(acc) do
    receive do
      {:event, event} -> drain(acc ++ [event])
    after
      0 -> acc
    end
  end

  defp sse(type, payload) do
    payload = Map.put(payload, "type", type)
    "event: #{type}\ndata: #{JSON.encode!(payload)}\n\n"
  end
end
