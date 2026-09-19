defmodule Tackle.Web.AgentThreadsTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Message
  alias Tackle.Web.AgentThreads

  @anchor {"lib/widget.ex", :new, 12}

  test "a question and its answer form one thread" do
    question = user("q1", "Why?")
    answer = assistant("a1", "Because.")

    assert [thread] = AgentThreads.all([question, answer], %{"q1" => @anchor})
    assert thread.question == question
    assert thread.replies == [answer]
    assert thread.steps == 0
  end

  test "consecutive questions each own the answers that followed them" do
    messages = [
      user("q1", "First?"),
      assistant("a1", "First answer."),
      tool("t1", "read output"),
      assistant("a2", "Second answer."),
      user("q2", "Second?")
    ]

    assert [first, second] = AgentThreads.all(messages, %{"q1" => @anchor, "q2" => @anchor})
    assert first.replies == [assistant("a1", "First answer."), assistant("a2", "Second answer.")]
    # The tool result is not an answer, so it is counted rather than shown.
    assert first.steps == 1
    assert second.replies == []
  end

  test "tool work and tool-call messages with no content do not count as answers" do
    messages = [
      user("q1", "How?"),
      assistant("a1", nil),
      tool("t1", "grep output"),
      assistant("a2", "Like this.")
    ]

    assert [thread] = AgentThreads.all(messages, %{"q1" => @anchor})
    assert thread.replies == [assistant("a2", "Like this.")]
    assert thread.steps == 2
  end

  test "a question asked without a line is filed under the general key" do
    messages = [user("q1", "What does this do?")]

    assert [thread] = AgentThreads.all(messages, %{"q1" => :general})
    assert AgentThreads.key(thread.anchor) == :general
  end

  test "messages with no recorded anchor are ignored" do
    messages = [user("q1", "Unknown provenance."), assistant("a1", "Answer.")]

    assert AgentThreads.all(messages, %{}) == []
  end

  test "threads are grouped by the anchor comments use" do
    messages = [user("q1", "First?"), user("q2", "Second?")]
    anchors = %{"q1" => @anchor, "q2" => {"lib/widget.ex", :new, 30}}

    threads = messages |> AgentThreads.all(anchors) |> AgentThreads.by_anchor()

    assert Map.keys(threads) |> Enum.sort() == [
             {"lib/widget.ex", :new, 12},
             {"lib/widget.ex", :new, 30}
           ]

    assert [%{question: %Message{id: "q1"}}] = threads[{"lib/widget.ex", :new, 12}]
  end

  test "several questions about the same line stay in order" do
    messages = [user("q1", "First?"), user("q2", "Second?")]
    anchors = %{"q1" => @anchor, "q2" => @anchor}

    grouped = messages |> AgentThreads.all(anchors) |> AgentThreads.by_anchor()

    assert [%{question: %Message{id: "q1"}}, %{question: %Message{id: "q2"}}] =
             grouped[{"lib/widget.ex", :new, 12}]
  end

  test "the active anchor is the most recent question, and nil without one" do
    assert AgentThreads.active_anchor([]) == nil

    messages = [user("q1", "First?"), assistant("a1", "Answer.")]
    threads = AgentThreads.all(messages, %{"q1" => @anchor})

    assert AgentThreads.active_anchor(threads) == @anchor
  end

  defp user(id, content), do: %Message{id: id, role: :user, content: content}
  defp assistant(id, content), do: %Message{id: id, role: :assistant, content: content}
  defp tool(id, content), do: %Message{id: id, role: :tool, content: content, tool_name: "read"}
end
