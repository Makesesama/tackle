defmodule Tackle.Lib.MessagesTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Message
  alias Tackle.Lib.Messages

  describe "to_provider/1" do
    test "maps a user message to a structured user entry" do
      msg = Message.user("hello there")

      assert [%{role: :user, content: "hello there"}] = Messages.to_provider([msg])
    end

    test "maps a final assistant message to a structured assistant entry" do
      msg = Message.assistant(content: "the answer is 42")

      assert [%{role: :assistant, content: "the answer is 42"}] = Messages.to_provider([msg])
    end

    test "preserves opaque provider continuation state on assistant entries" do
      provider_state = %{"provider" => "example", "model" => "test", "opaque" => "value"}
      msg = Message.assistant(content: "answer", provider_state: provider_state)

      assert [%{provider_state: ^provider_state}] = Messages.to_provider([msg])
    end

    test "maps an assistant tool-call turn to native tool_calls with JSON-string arguments" do
      msg =
        Message.assistant(
          content: nil,
          tool_calls: [%{id: "call_1", name: "search", arguments: %{"q" => "cats"}}]
        )

      assert [entry] = Messages.to_provider([msg])
      assert entry.role == :assistant
      assert [tool_call] = entry.tool_calls
      assert tool_call.id == "call_1"
      assert tool_call.type == "function"
      assert tool_call.function.name == "search"
      # arguments are serialized to a JSON string (OpenAI tool-call convention)
      assert is_binary(tool_call.function.arguments)
      assert {:ok, %{"q" => "cats"}} = Tackle.Lib.JSON.decode(tool_call.function.arguments)
    end

    test "maps a tool result linked back to its call id" do
      msg = Message.tool_result("call_1", "search", "found 3 cats")

      assert [entry] = Messages.to_provider([msg])
      assert entry.role == :tool
      assert entry.tool_call_id == "call_1"
      assert entry.name == "search"
      assert entry.content == "found 3 cats"
    end

    test "preserves a full multi-turn tool exchange as separate linked messages" do
      messages = [
        Message.user("how many cats?"),
        Message.assistant(
          content: nil,
          tool_calls: [%{id: "call_1", name: "search", arguments: %{"q" => "cats"}}]
        ),
        Message.tool_result("call_1", "search", "3 cats"),
        Message.assistant(content: "There are 3 cats.")
      ]

      result = Messages.to_provider(messages)

      assert length(result) == 4
      assert Enum.map(result, & &1.role) == [:user, :assistant, :tool, :assistant]

      [_user, assistant_call, tool_result, _final] = result
      # the assistant's tool_call id matches the tool result's tool_call_id
      assert [%{id: call_id}] = assistant_call.tool_calls
      assert tool_result.tool_call_id == call_id
    end

    test "drops degenerate assistant turns with neither content nor tool calls" do
      msg = Message.assistant(content: nil)

      assert [] = Messages.to_provider([msg])
    end

    test "generates a linking id when an assistant tool call lacks one" do
      msg =
        Message.assistant(tool_calls: [%{name: "search", arguments: %{}}])

      assert [%{tool_calls: [%{id: id}]}] = Messages.to_provider([msg])
      assert is_binary(id) and id != ""
    end
  end
end
