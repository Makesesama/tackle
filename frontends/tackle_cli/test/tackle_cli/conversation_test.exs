defmodule Tackle.CLI.TUI.ConversationTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias Tackle.CLI.TUI.Conversation
  alias Tackle.CLI.TUI.State.Stream
  alias Tackle.Lib.{Message, State}

  test "refresh preserves the row inside a multi-widget tool card, not just its header" do
    messages =
      [Message.tool_result("read", "read", "one\ntwo\nthree\nfour")] ++
        Enum.map(1..10, &Message.user("following #{&1}"))

    state = projection(messages)
    conversation = Conversation.new(%Rect{width: 80, height: 4}) |> Conversation.refresh(state)

    conversation =
      conversation |> Conversation.scroll_to_entry("tool:read") |> Conversation.scroll(3)

    assert conversation.anchor == %{id: "tool:read", offset: 3}
    refreshed = Conversation.refresh(conversation, state)
    assert refreshed.scroll_offset == conversation.scroll_offset
    assert refreshed.anchor == conversation.anchor
  end

  test "growing viewport does not silently resume following" do
    state = projection(Enum.map(1..10, &Message.user("message #{&1}")))
    conversation = Conversation.new(%Rect{width: 80, height: 4}) |> Conversation.refresh(state)
    conversation = Conversation.scroll_to(conversation, :start)
    resized = Conversation.resize(conversation, %Rect{width: 80, height: 100})
    refute resized.follow?
    refute Conversation.refresh(resized, state).follow?
  end

  test "search reaches entries beyond the result limit" do
    state =
      projection(
        Enum.map(1..205, &Message.user("message #{&1}")) ++
          [Message.user("needle in newest turn")]
      )

    conversation = Conversation.new(%Rect{width: 80, height: 10}) |> Conversation.refresh(state)
    assert [%{preview: "needle in newest turn"}] = Conversation.search(conversation, "needle")
    assert length(Conversation.search(conversation, "message")) == 200
  end

  defp projection(messages) do
    %{
      agent_state: %State{messages: messages},
      pending_prompt: nil,
      tool_activity: [],
      stream: %Stream{},
      thinking_expanded?: false,
      error: nil
    }
  end
end
