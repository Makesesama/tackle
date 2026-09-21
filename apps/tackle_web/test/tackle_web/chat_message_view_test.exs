defmodule Tackle.Web.ChatMessageViewTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Message
  alias Tackle.Web.ChatMessageView

  test "questions and answers are visible on their own" do
    question = Message.user("Why?")
    answer = Message.assistant(content: "Because.")

    assert ChatMessageView.group_messages([question, answer]) == [
             {:visible, question},
             {:visible, answer}
           ]
  end

  test "tool work between an answer and the next question is grouped" do
    call = Message.assistant(tool_calls: [%{id: "c1", name: "read", arguments: %{}}])
    result = Message.tool_result("c1", "read", "file contents")
    answer = Message.assistant(content: "It does this.")

    assert [{:internal, [^call, ^result]}, {:visible, ^answer}] =
             ChatMessageView.group_messages([call, result, answer])
  end

  test "a tool result with no answer after it is still internal" do
    result = Message.tool_result("c1", "read", "file contents")

    # Deciding by block size would render this as the assistant's answer.
    assert ChatMessageView.group_messages([result]) == [{:internal, [result]}]
  end

  test "an assistant message that only reasons is internal" do
    reasoning = Message.assistant(thinking: "Let me look at the file.")

    assert ChatMessageView.group_messages([reasoning]) == [{:internal, [reasoning]}]
  end

  test "an assistant message with an empty answer is internal" do
    empty = Message.assistant(content: "   ")

    assert ChatMessageView.group_messages([empty]) == [{:internal, [empty]}]
  end

  test "a question ends an internal block" do
    call = Message.assistant(tool_calls: [%{id: "c1", name: "read", arguments: %{}}])
    question = Message.user("And now?")

    assert [{:internal, [^call]}, {:visible, ^question}] =
             ChatMessageView.group_messages([call, question])
  end

  test "a streaming message accumulates its deltas" do
    entry =
      ChatMessageView.new_streaming_message()
      |> ChatMessageView.append_streaming_delta("Hel")
      |> ChatMessageView.append_streaming_delta("lo")

    assert entry == %{content: "Hello"}
  end

  test "an empty transcript groups to nothing" do
    assert ChatMessageView.group_messages([]) == []
  end
end
