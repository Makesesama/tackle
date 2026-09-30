defmodule Tackle.CLI.TUI.ConversationTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias Tackle.CLI.TUI.Conversation
  alias Tackle.CLI.TUI.State.Stream
  alias Tackle.Lib.{Message, State}

  test "refresh preserves the row inside a multi-widget tool card, not just its header" do
    messages =
      [Message.tool_result("read", "custom", "one\ntwo\nthree\nfour")] ++
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
        Enum.map(1..206, fn
          206 -> Message.user("needle in newest turn")
          index -> Message.user("message #{index}")
        end)
      )

    conversation = Conversation.new(%Rect{width: 80, height: 10}) |> Conversation.refresh(state)
    assert [%{preview: "needle in newest turn"}] = Conversation.search(conversation, "needle")
    assert Enum.count_until(Conversation.search(conversation, "message"), 201) == 200
  end

  test "spacer anchors choose the next entry within and across retained sections" do
    state = %{
      projection([Message.user("one"), Message.user("two")])
      | stream: %Stream{timeline: [%{kind: :assistant, content: "tail"}]}
    }

    old = Conversation.new(%Rect{width: 80, height: 1}) |> Conversation.refresh(state)

    for {offset, id} <- [{1, "message:1:user"}, {3, "streaming:response"}] do
      scrolled = old |> Conversation.scroll_to(:start) |> Conversation.scroll(offset)
      assert scrolled.anchor == %{id: id, offset: 0}
      updated = Conversation.refresh(scrolled, state, [:turn])
      assert updated.scroll_offset == scrolled.scroll_offset
      assert updated.anchor == scrolled.anchor
    end
  end

  test "height-only resize re-budgets file cards and preserves cached no-op refreshes" do
    content = Enum.map_join(1..84, "\n", &"source #{&1}")

    state =
      projection([
        Message.assistant(
          tool_calls: [
            %{id: "w", name: "write", arguments: %{path: "a", content: content}}
          ]
        )
      ])

    short = Conversation.new(%Rect{width: 80, height: 18}) |> Conversation.refresh(state)
    assert short.content_height == 17
    short = Conversation.scroll_to(short, :start)
    tall = Conversation.resize(short, %Rect{width: 80, height: 30})
    assert tall.content_height == 23
    assert tall.anchor == short.anchor
    refute tall.follow?
    assert Conversation.refresh(tall, state).native == tall.native

    tiny = Conversation.resize(tall, %Rect{width: 80, height: 4})
    assert tiny.content_height == 4
    assert tiny.sections.settled.code_rows == 1
  end

  test "height-only resize reuses cells that do not depend on file preview budgets" do
    state = projection([Message.user("hello"), Message.tool_result("r", "read", "content")])
    short = Conversation.new(%Rect{width: 80, height: 18}) |> Conversation.refresh(state)
    tall = Conversation.resize(short, %Rect{width: 80, height: 30})
    assert tall.sections.settled.groups == short.sections.settled.groups
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
