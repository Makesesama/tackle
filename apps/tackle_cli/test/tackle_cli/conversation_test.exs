defmodule Tackle.CLI.TUI.ConversationTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias Tackle.CLI.Test.AgentStates
  alias Tackle.CLI.TUI.Conversation
  alias Tackle.CLI.TUI.State.Stream
  alias Tackle.Lib.Message

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

  test "native transcript keeps exploration grouped across hidden thinking and turn settlement" do
    live = %{
      projection([])
      | stream: %Stream{
          timeline: [
            %{
              kind: :tool,
              id: "search",
              name: "bash",
              arguments: %{"command" => "rg activity lib | head -120"},
              output: "found",
              status: :completed
            },
            %{kind: :thinking, content: "Check the implementation"},
            %{
              kind: :tool,
              id: "read",
              name: "read",
              arguments: %{"path" => "lib/tool_groups.ex"},
              status: :running
            }
          ]
        }
    }

    conversation = Conversation.new(%Rect{width: 80, height: 20}) |> Conversation.refresh(live)
    assert [group] = conversation.sections.turn.entries
    assert group.id == "group:tool:search"
    assert group.tool_status == :running

    assert [%{id: "group:tool:search"}] =
             Conversation.search(conversation, "Check the implementation")

    assert Conversation.refresh(conversation, live).native == conversation.native

    settled =
      projection([
        Message.assistant(
          tool_calls: [
            %{
              id: "search",
              name: "bash",
              arguments: %{"command" => "rg activity lib | head -120"}
            }
          ]
        ),
        Message.tool_result("search", "bash", "found"),
        Message.assistant(
          thinking: "Check the implementation",
          tool_calls: [%{id: "read", name: "read", arguments: %{"path" => "lib/tool_groups.ex"}}]
        ),
        Message.tool_result("read", "read", "contents")
      ])

    refreshed = Conversation.refresh(conversation, settled)
    assert [group] = refreshed.sections.settled.entries
    assert group.id == "group:tool:search"
    assert group.tool_status == :completed
    assert refreshed.sections.turn.entries == []

    assert [%{id: "group:tool:search"}] =
             Conversation.search(refreshed, "Check the implementation")

    expanded = Conversation.refresh(refreshed, %{settled | thinking_expanded?: true})
    assert Enum.map(expanded.sections.settled.entries, & &1.kind) == [:tool, :thinking, :tool]
    assert Conversation.refresh(expanded, settled).sections.settled.entries == [group]
  end

  test "expanding an older activity group preserves selection and reading anchor" do
    messages =
      [
        Message.assistant(tool_calls: [%{id: "a", name: "read", arguments: %{"path" => "a.ex"}}]),
        Message.assistant(
          thinking: "Inspect b",
          tool_calls: [%{id: "b", name: "read", arguments: %{"path" => "b.ex"}}]
        )
      ] ++ Enum.map(1..20, &Message.user("Later message #{&1}"))

    state = Map.put(projection(messages), :selected_entry, "group:tool:a")

    conversation =
      Conversation.new(%Rect{width: 80, height: 4})
      |> Conversation.refresh(state)
      |> Conversation.scroll_to_entry("group:tool:a")

    expanded_state = %{state | thinking_expanded?: true}
    expanded = Conversation.refresh(conversation, expanded_state)
    assert expanded.selected_entry == "tool:a"
    assert expanded.anchor == %{id: "tool:a", offset: 0}
    refute expanded.follow?

    collapsed = Conversation.refresh(expanded, %{state | selected_entry: "tool:b"})
    assert collapsed.selected_entry == "group:tool:a"
    assert collapsed.anchor == %{id: "group:tool:a", offset: 0}

    shell = %Tackle.CLI.TUI.State{
      size: {80, 24},
      conversation: conversation,
      agent_state: state.agent_state,
      focus: :transcript,
      selected_entry: "group:tool:a"
    }

    assert {:noreply, toggled} = Tackle.CLI.TUI.Viewport.toggle_thinking(shell)
    assert toggled.selected_entry == "tool:a"
    assert toggled.conversation.anchor.id == "tool:a"
  end

  defp projection(messages) do
    %{
      agent_state: AgentStates.with_messages(messages),
      pending_prompt: nil,
      tool_activity: [],
      stream: %Stream{},
      thinking_expanded?: false,
      error: nil
    }
  end
end
