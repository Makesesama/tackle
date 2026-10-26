defmodule Tackle.LibTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Call

  describe "last_answer/1" do
    test "is the content of a final answer that ends the conversation" do
      state = conversation([user("hi"), assistant(content: "hello")])

      assert Tackle.Lib.last_answer(state) == "hello"
    end

    test "is nil when the last assistant message also requested tools" do
      call = %Call{id: "c1", name: "search", arguments: %{}}
      state = conversation([user("hi"), assistant(content: "Let me look.", tool_calls: [call])])

      assert Tackle.Lib.last_answer(state) == nil
    end

    test "does not return an earlier turn's answer for a conversation that ends otherwise" do
      call = %Call{id: "c1", name: "search", arguments: %{}}
      answered = [user("first"), assistant(content: "first answer")]

      # A failed turn left only its user message.
      assert Tackle.Lib.last_answer(conversation(answered ++ [user("second")])) == nil

      # An interrupted turn ended with a tool result.
      interrupted =
        answered ++
          [
            user("second"),
            assistant(tool_calls: [call]),
            Message.tool_result("c1", "search", "Error: interrupted")
          ]

      assert Tackle.Lib.last_answer(conversation(interrupted)) == nil
    end

    test "is nil for an empty conversation or an empty answer" do
      assert Tackle.Lib.last_answer(State.new()) == nil
      assert Tackle.Lib.last_answer(conversation([user("hi"), assistant(content: "")])) == nil
    end
  end

  defp conversation(messages), do: Enum.reduce(messages, State.new(), &State.add_message(&2, &1))

  defp user(content), do: Message.user(content)
  defp assistant(opts), do: Message.assistant(opts)
end
