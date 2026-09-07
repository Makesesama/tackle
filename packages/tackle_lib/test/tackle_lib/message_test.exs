defmodule Tackle.Lib.MessageTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Message
  alias Tackle.Lib.Usage

  describe "user/1" do
    test "creates a user message" do
      message = Message.user("Hello")

      assert message.role == :user
      assert message.content == "Hello"
      assert message.id != nil
      assert message.timestamp
    end

    test "accepts a custom id generator" do
      message = Message.user("Hello", id_generator: fn -> "message-id" end)

      assert message.id == "message-id"
    end
  end

  describe "assistant/1" do
    test "creates an assistant message with content" do
      message = Message.assistant(content: "Hi there!")

      assert message.role == :assistant
      assert message.content == "Hi there!"
      assert message.tool_calls == nil
    end

    test "creates an assistant message with tool calls" do
      tool_calls = [%{name: "search", arguments: %{query: "test"}}]
      message = Message.assistant(tool_calls: tool_calls)

      assert message.role == :assistant
      assert message.tool_calls == tool_calls
    end

    test "creates an assistant message with thinking" do
      message = Message.assistant(thinking: "Let me think...", content: "Result")

      assert message.thinking == "Let me think..."
      assert message.content == "Result"
    end

    test "preserves token usage metadata" do
      usage = %{input_tokens: 10, output_tokens: 5}
      message = Message.assistant(content: "Result", token_usage: usage, model: "test/model")

      assert %Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15, model: "test/model"} =
               message.token_usage

      assert message.model == "test/model"
    end
  end

  describe "tool_result/3" do
    test "creates a tool result message" do
      message = Message.tool_result("call_123", "search", "Results here")

      assert message.role == :tool
      assert message.tool_call_id == "call_123"
      assert message.tool_name == "search"
      assert message.content == "Results here"
    end
  end

  describe "final_answer?/1" do
    test "returns true for assistant with content and no tool calls" do
      message = Message.assistant(content: "Final answer")
      assert Message.final_answer?(message)
    end

    test "returns false for assistant with tool calls" do
      message = Message.assistant(tool_calls: [%{name: "search", arguments: %{}}])
      refute Message.final_answer?(message)
    end

    test "returns false for user messages" do
      message = Message.user("Hello")
      refute Message.final_answer?(message)
    end

    test "returns false for assistant with empty content" do
      message = Message.assistant(content: "")
      refute Message.final_answer?(message)
    end
  end

  describe "has_tool_calls?/1" do
    test "returns true for message with tool calls" do
      message = Message.assistant(tool_calls: [%{name: "search", arguments: %{}}])
      assert Message.has_tool_calls?(message)
    end

    test "returns false for message without tool calls" do
      message = Message.assistant(content: "No tools")
      refute Message.has_tool_calls?(message)
    end

    test "returns false for empty tool calls list" do
      message = Message.assistant(tool_calls: [])
      refute Message.has_tool_calls?(message)
    end
  end
end
