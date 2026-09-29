defmodule Tackle.CLI.TUI.TextSelectionTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias ExRatatui.Event.{Key, Mouse}
  alias ExRatatui.Layout.Rect
  alias Tackle.CLI.{Native, TUI}
  alias Tackle.CLI.TUI.{Browser, Conversation, State, TextSelection, Viewport}
  alias Tackle.CLI.Widgets.{Browse, Input}
  alias Tackle.CLI.Widgets.Conversation, as: Widget
  alias Tackle.Lib.Message

  test "drag selects painted text, highlights only its cells and copies on release" do
    state = state("hello world") |> gesture("down", 3, 0) |> gesture("drag", 7, 0)
    assert TextSelection.range(state.conversation.text_selection) == {{0, 3}, {0, 8}}
    {:ok, rows} = render(state)

    assert Enum.any?(hd(rows), fn {text, _, _, _, bits} ->
             text == "hello" and band(bits, 64) != 0
           end)

    state = gesture(state, "up", 7, 0)
    assert_received {:copied, "hello"}
    assert state.notice == "Copied selection"
    refute state.conversation.text_selection.dragging?

    assert {:noreply, _} = TUI.handle_event(%Key{code: "c", modifiers: ["ctrl"]}, state)
    assert_received {:copied, "hello"}
    assert {:noreply, cleared} = TUI.handle_event(%Key{code: "esc"}, state)
    assert cleared.conversation.text_selection == nil
    assert Input.get_value(cleared.input) == "draft"
    assert {:noreply, cleared} = TUI.handle_event(%Key{code: "esc"}, cleared)
    assert Input.get_value(cleared.input) == ""
  end

  test "reverse drag includes the starting glyph and preserves wide and combining glyphs" do
    state("界éxyz") |> gesture("down", 6, 0) |> gesture("drag", 4, 0) |> gesture("up", 4, 0)
    assert_received {:copied, "界éx"}
  end

  test "single click does not copy; double and triple click select words and screen lines" do
    state = state("hello world") |> gesture("down", 5, 0, 0) |> gesture("up", 5, 0, 10)
    refute_received {:copied, _}
    state = state |> gesture("down", 5, 0, 100) |> gesture("up", 5, 0, 110)
    assert_received {:copied, "hello"}
    state |> gesture("down", 5, 0, 200) |> gesture("up", 5, 0, 210)
    assert_received {:copied, "›  hello world"}
  end

  test "scrolling extends an active drag, retains released selection, ignores stale timers" do
    state = state(Enum.map_join(1..60, "\n", &"line #{&1}"))
    state = gesture(state, "down", 3, 1)
    y = state.conversation.rect.height - 1
    state = gesture(state, "drag", 8, y)
    offset = state.conversation.scroll_offset
    token = state.conversation.text_selection.token
    state = TextSelection.tick(state, token)
    assert state.conversation.scroll_offset > offset
    state = gesture(state, "up", 8, y)
    assert_received {:copied, text}
    assert text =~ "line 2"
    assert text =~ "line 10"
    range = TextSelection.range(state.conversation.text_selection)
    assert TextSelection.tick(state, token) == state
    state = Viewport.scroll(state, -3)
    assert TextSelection.range(state.conversation.text_selection) == range
    assert TextSelection.tick(state, make_ref()) == state
  end

  test "settled selections survive appended streaming output but invalidate on changed selected cells or width" do
    state =
      state("hello world")
      |> gesture("down", 3, 0)
      |> gesture("drag", 7, 0)
      |> gesture("up", 7, 0)

    old = state.conversation.text_selection
    state = %{state | stream: %State.Stream{timeline: [%{kind: :assistant, content: "tail"}]}}
    state = Viewport.refresh(state, [:turn])
    assert state.conversation.text_selection == old

    state = %{
      state
      | stream: %State.Stream{timeline: [%{kind: :assistant, content: "longer tail"}]}
    }

    state = Viewport.refresh(state, [:turn])
    assert state.conversation.text_selection == old

    resized = Conversation.resize(state.conversation, %{state.conversation.rect | width: 20})
    assert resized.text_selection == nil
    changed = %{state | agent_state: %{state.agent_state | messages: [Message.user("changed")]}}
    assert Viewport.refresh(changed).conversation.text_selection == nil
  end

  test "overlays, other browse pages and out-of-pane clicks cannot select transcript" do
    state = state("hello world")

    assert TextSelection.mouse(%Mouse{kind: "down", x: 0, y: 0}, state).conversation.text_selection ==
             nil

    overlay = %{state | overlay: {:help, %{offset: 0}}}
    assert gesture(overlay, "down", 3, 0).conversation.text_selection == nil
    page = %{state | focus: :transcript, browse_page: :overview}
    assert gesture(page, "down", 3, 0).conversation.text_selection == nil
  end

  test "Browse transcript paints the same selected cells below its tabs" do
    state = state("hello world")
    {:noreply, state} = Browser.toggle_focus(state)
    state = state |> gesture("down", 3, 0) |> gesture("drag", 7, 0)
    widget = Browser.widget(state)
    assert widget.text_selection == {{0, 3}, {0, 8}}

    rect = %{
      state.conversation.rect
      | y: state.conversation.rect.y - 1,
        height: state.conversation.rect.height + 1
    }

    [{paragraph, _}] = Browse.render(widget, rect)

    assert Enum.any?(Enum.at(paragraph.text, 1).spans, fn span ->
             span.content == "hello" and :reversed in span.style.modifiers
           end)
  end

  test "clipboard errors remain visible and do not discard selection" do
    state = %{state("hello world") | clipboard_writer: fn _ -> {:error, :unavailable} end}
    state = state |> gesture("down", 3, 0) |> gesture("drag", 7, 0) |> gesture("up", 7, 0)
    assert state.notice =~ "Copy failed"
    assert state.conversation.text_selection != nil
  end

  test "native extraction rejects invalid ranges and bounds work" do
    c = state("hello").conversation

    assert_raise ArgumentError, fn ->
      Native.conversation_selection_text(c.native, {{2, 0}, {0, 1}})
    end

    assert_raise ArgumentError, fn ->
      Native.conversation_selection_text(c.native, {{0, 0}, {100, 1}})
    end

    c = state(String.duplicate("x\n", 27_000)).conversation

    assert Native.conversation_selection_text(c.native, {{0, 0}, {26_999, 1}}) ==
             {:error, "selection too large"}
  end

  test "stationary bottom-row click while following does not copy after relayout" do
    state = state(Enum.map_join(1..60, "\n", &"line #{&1}")) |> Viewport.scroll_to(:end)
    rect = state.conversation.rect
    mouse = %Mouse{kind: "down", button: "left", x: 3, y: rect.y + rect.height - 1}
    {:noreply, state, _} = TUI.handle_event(mouse, state)
    {:noreply, state, _} = TUI.handle_event(%{mouse | kind: "up"}, state)
    refute TextSelection.selected?(state)
    refute_received {:copied, _}
  end

  test "appending within a selected live message preserves unchanged painted selection" do
    state = state("question")
    stream = %State.Stream{timeline: [%{kind: :assistant, content: "first paragraph\n\nsecond"}]}
    state = %{state | stream: stream} |> Viewport.refresh() |> Viewport.scroll_to(:start)
    # Prompt, spacer, then the first assistant row.
    state = state |> gesture("down", 3, 2) |> gesture("drag", 7, 2) |> gesture("up", 7, 2)
    assert_received {:copied, "first"}
    selection = state.conversation.text_selection

    stream = %State.Stream{
      timeline: [%{kind: :assistant, content: "first paragraph\n\nsecond extended\n\nthird"}]
    }

    updated = %{state | stream: stream} |> Viewport.refresh([:turn])
    assert updated.conversation.text_selection == selection
  end

  test "large soft-wrapped extraction matches painted rows across batches" do
    source = String.duplicate("abcdefghij ", 8_000)
    {cell, _} = Native.conversation_markdown(source, 80, Widget.style(%ExRatatui.Style{}))
    {native, height} = Native.conversation_new([cell], 80)
    text = Native.conversation_selection_text(native, {{0, 0}, {height - 1, 80}})
    assert is_binary(text)
    assert length(String.split(text, "\n")) == height
    assert String.replace(text, ~r/\s/u, "") == String.replace(source, " ", "")
  end

  defp state(text) do
    pid = self()
    input = Input.new()
    :ok = Input.set_value(input, "draft")

    %State{
      input: input,
      draft_empty?: false,
      agent_state: %Tackle.Lib.State{messages: [Message.user(text)]},
      size: {40, 20},
      conversation: Conversation.new(%Rect{width: 40, height: 12}),
      clipboard_writer: fn text ->
        send(pid, {:copied, text})
        :ok
      end
    }
    |> Viewport.refresh()
    |> Viewport.scroll_to(:start)
  end

  defp gesture(state, kind, col, row, now \\ 0) do
    rect = state.conversation.rect

    TextSelection.mouse(
      %Mouse{kind: kind, button: "left", x: rect.x + col, y: rect.y + row},
      state,
      now
    )
  end

  defp render(state) do
    c = state.conversation

    Native.conversation_render(
      c.native,
      c.width,
      c.rect.height,
      c.scroll_offset,
      [],
      Widget.style(%ExRatatui.Style{}),
      TextSelection.range(c.text_selection)
    )
  end
end
