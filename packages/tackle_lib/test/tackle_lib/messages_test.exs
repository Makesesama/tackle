defmodule Tackle.Lib.MessagesTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Message
  alias Tackle.Lib.Messages
  alias Tackle.Lib.Tool.Call

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
      assert {:ok, %{"q" => "cats"}} = JSON.decode(tool_call.function.arguments)
    end

    test "maps a tool result linked back to its call id" do
      msg = Message.tool_result("call_1", "search", "found 3 cats")

      assert [entry] = Messages.to_provider([msg])
      assert entry.role == :tool
      assert entry.tool_call_id == "call_1"
      assert entry.name == "search"
      assert entry.content == "found 3 cats"
    end

    test "emits a content-part array when a tool result carries content parts" do
      msg =
        Message.tool_result("call_1", "read", "Read image chart.png (image/png).",
          parts: [%{"type" => "image", "media_type" => "image/png", "data" => "aGVsbG8="}]
        )

      assert [entry] = Messages.to_provider([msg])
      assert entry.role == :tool

      assert entry.content == [
               %{"type" => "text", "text" => "Read image chart.png (image/png)."},
               %{"type" => "image", "media_type" => "image/png", "data" => "aGVsbG8="}
             ]
    end

    test "omits an empty text part when tool content has no text projection" do
      msg =
        Message.tool_result("call_1", "read", "",
          parts: [%{"type" => "image", "media_type" => "image/png", "data" => "aGVsbG8="}]
        )

      assert [%{content: [%{"type" => "image"}]}] = Messages.to_provider([msg])
    end

    test "ignores an empty parts list on a tool result" do
      msg = Message.tool_result("call_1", "search", "found 3 cats", parts: [])

      assert [%{content: "found 3 cats"}] = Messages.to_provider([msg])
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

      assert [_, _, _, _] = result
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

    test "derives a stable id when an assistant tool call lacks one" do
      msg =
        Message.assistant(
          id: "msg_1",
          tool_calls: [%{id: "kept", name: "read"}, %{name: "search", arguments: %{}}]
        )

      assert [%{tool_calls: [%{id: "kept"}, %{id: "call_msg_1_1"}]}] = Messages.to_provider([msg])
      assert Messages.to_provider([msg]) == Messages.to_provider([msg])
    end

    test "derives distinct ids for id-less calls of messages without an id" do
      first = %Message{
        role: :assistant,
        tool_calls: [%Call{name: "search", arguments: %{"q" => 1}}]
      }

      second = %Message{
        role: :assistant,
        tool_calls: [%Call{name: "search", arguments: %{"q" => 2}}]
      }

      assert [%{tool_calls: [%{id: a}]}, %{tool_calls: [%{id: b}]}] =
               Messages.to_provider([first, second])

      assert a != b
    end
  end

  describe "unresolved_tool_calls/1" do
    test "returns calls without a matching tool result" do
      messages = [
        Message.user("run"),
        Message.assistant(
          content: nil,
          tool_calls: [
            %Call{id: "call_1", name: "search", arguments: %{"q" => "cats"}},
            %{id: "call_2", name: "read", arguments: %{}}
          ]
        ),
        Message.tool_result("call_1", "search", "3 cats")
      ]

      assert [%Call{id: "call_2", name: "read"}] = Messages.unresolved_tool_calls(messages)
    end

    test "returns nothing once every call has a result" do
      messages = [
        Message.assistant(
          content: nil,
          tool_calls: [%{id: "call_1", name: "search", arguments: %{}}]
        ),
        Message.tool_result("call_1", "search", "3 cats"),
        Message.assistant(content: "done")
      ]

      assert Messages.unresolved_tool_calls(messages) == []
    end

    test "keeps transcript order and lists a repeated id once" do
      messages = [
        Message.assistant(
          tool_calls: [
            %{id: "b", name: "second"},
            %{id: "a", name: "first"},
            %{id: "b", name: "x"}
          ]
        ),
        Message.assistant(tool_calls: [%{"id" => "c", "name" => "third"}])
      ]

      assert [
               %Call{id: "b", name: "second"},
               %Call{id: "a", name: "first"},
               %Call{id: "c", name: "third"}
             ] = Messages.unresolved_tool_calls(messages)
    end

    test "keeps calls from an earlier turn that were never settled" do
      messages = [
        Message.assistant(
          content: nil,
          tool_calls: [%{id: "call_1", name: "search", arguments: %{}}]
        ),
        Message.user("try again")
      ]

      assert [%Call{id: "call_1", name: "search"}] = Messages.unresolved_tool_calls(messages)
    end

    test "skips a call without an id, which no result can settle" do
      messages = [%Message{role: :assistant, tool_calls: [%Call{name: "search"}]}]

      assert Messages.unresolved_tool_calls(messages) == []
    end
  end

  describe "interrupted_results/3" do
    test "builds one synthetic error result per unresolved call, in transcript order" do
      ids = Agent.start_link(fn -> 0 end) |> elem(1)
      next_id = fn -> "msg-#{Agent.get_and_update(ids, &{&1, &1 + 1})}" end

      messages = [
        Message.assistant(
          tool_calls: [
            %{id: "call_1", name: "search"},
            %{id: "call_2", name: "read"},
            %{id: "call_3", name: "bash"}
          ]
        ),
        Message.tool_result("call_2", "read", "done")
      ]

      assert [first, second] =
               Messages.interrupted_results(messages, :cancelled, id_generator: next_id)

      assert %Message{
               id: "msg-0",
               role: :tool,
               tool_call_id: "call_1",
               tool_name: "search",
               content: "Error: Tool execution was cancelled before this call completed."
             } = first

      assert %Message{id: "msg-1", tool_call_id: "call_3", tool_name: "bash"} = second
    end

    test "says the outcome of a call found unresolved in stored history is unknown" do
      messages = [Message.assistant(tool_calls: [%{id: "call_1", name: "bash"}])]

      assert [%Message{content: content}] = Messages.interrupted_results(messages, :unknown)

      assert content ==
               "Error: Tool execution was interrupted before a result was recorded; " <>
                 "the outcome is unknown."
    end

    test "builds nothing when every call has a result" do
      messages = [
        Message.assistant(tool_calls: [%{id: "call_1", name: "bash"}]),
        Message.tool_result("call_1", "bash", "ok")
      ]

      assert Messages.interrupted_results(messages, :interrupted) == []
    end
  end
end
