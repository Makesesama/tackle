defmodule Tackle.CLI.Widgets.InputTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph}
  alias Tackle.CLI.Native
  alias ExRatatui.Event.Key
  alias Tackle.CLI.TUI.{Composer, Dashboard, Layout, State, Theme, View, Viewport}
  alias Tackle.CLI.Widgets.Input

  test "measurement, resize, and vertical editing use the same soft wraps" do
    input = Input.new()
    :ok = Input.insert_str(input, "abcdefgh")

    state = %State{
      input: input,
      agent_state: Tackle.Lib.State.new(),
      size: {8, 20},
      conversation: Viewport.new_conversation(8, 20)
    }

    state = state |> Viewport.update_draft() |> Viewport.relayout()
    assert state.draft_lines == 3

    {:noreply, state} = Composer.key(state, %Key{code: "up", modifiers: []})
    :ok = Input.insert_str(input, "!")
    assert Input.get_value(input) == "abcd!efgh"

    resized = Viewport.resize(%{state | size: {20, 20}})
    assert resized.draft_lines == 1
    assert Input.get_value(input) == "abcd!efgh"
  end

  test "dashboard wraps at its painted width and keeps the next line visible" do
    for width <- [40, 80, 100] do
      state = %State{
        input: Input.new(),
        agent_state: Tackle.Lib.State.new(),
        size: {width, 24},
        list_recent_sessions: fn -> {:ok, []} end,
        conversation: Viewport.new_conversation(width, 24)
      }

      content_width = Dashboard.content_width(state)
      assert content_width == min(width - 4, 80) - 4

      # One row at the terminal width would have clipped this wrap on the dashboard.
      :ok = Input.set_value(state.input, String.duplicate("x", content_width + 1))
      state = state |> Viewport.update_draft() |> Viewport.relayout()
      assert Dashboard.show?(state)
      assert state.draft_lines == 2
      {widget, rect} = composer(state)
      assert rect.height == 4
      assert [{%Block{}, ^rect}, {%Paragraph{}, inner}] = Input.render(widget, rect)
      assert inner.width == content_width
      assert inner.height == 2

      terminal = ExRatatui.init_test_terminal(width, 24)
      :ok = ExRatatui.draw(terminal, View.scene(state, nil))
      rows = terminal |> ExRatatui.get_buffer_content() |> String.split("\n")
      assert Enum.at(rows, inner.y) =~ String.duplicate("x", content_width)
      assert Enum.at(rows, inner.y + 1) =~ "x"

      # Explicit newlines grow the dashboard too; it leaves the landing surface
      # only when there is no longer room for the mark and recent sessions.
      {:noreply, state} = Composer.insert_newline(state)
      assert Input.get_value(state.input) == String.duplicate("x", content_width + 1) <> "\n"
      assert state.draft_lines == 3
      assert Dashboard.show?(state)
      assert {%Input{}, %Rect{height: 5}} = composer(state)

      {:noreply, state} = Composer.insert_newline(state)
      assert state.draft_lines == 4
      refute Dashboard.show?(state)
      assert {%Input{}, %Rect{width: ^width}} = composer(state)
    end
  end

  test "dashboard vertical navigation uses the displayed wrap width" do
    width = 100

    state = %State{
      input: Input.new(),
      agent_state: Tackle.Lib.State.new(),
      size: {width, 24},
      list_recent_sessions: fn -> {:ok, []} end,
      conversation: Viewport.new_conversation(width, 24)
    }

    content_width = Dashboard.content_width(state)
    :ok = Input.set_value(state.input, String.duplicate("x", content_width + 5))
    state = state |> Viewport.update_draft() |> Viewport.relayout()
    assert Dashboard.show?(state)
    {:noreply, state} = Composer.key(state, %Key{code: "up", modifiers: []})
    :ok = Input.insert_str(state.input, "!")

    assert Input.get_value(state.input) ==
             String.duplicate("x", 5) <> "!" <> String.duplicate("x", content_width)
  end

  test "the input bar paints a padded rounded box and dims when focus leaves" do
    state = input_state(30, 12)
    {widget, rect} = composer(state)

    assert widget.block.border_style == Theme.style(:accent_soft)
    assert [{%Block{}, ^rect}, {%Paragraph{}, inner}] = Input.render(widget, rect)
    assert inner.width == Layout.composer_content_width(30, 12)
    assert inner.x == 2
    assert inner.height == 1

    terminal = ExRatatui.init_test_terminal(30, 12)
    :ok = ExRatatui.draw(terminal, [{widget, rect}])
    rows = terminal |> ExRatatui.get_buffer_content() |> String.split("\n")
    assert Enum.at(rows, rect.y) =~ "╭"
    assert Enum.at(rows, rect.y) =~ "Message"
    assert Enum.at(rows, rect.y + 1) =~ "│ What would you like to"
    assert Enum.at(rows, rect.y + 2) =~ "╰"
    assert Enum.at(rows, rect.y + 2) =~ "╯"

    {unfocused, _} = composer(%{state | focus: :subagents})
    assert unfocused.block.border_style == Theme.style(:subtle)
    refute unfocused.focused
  end

  test "tiny terminals drop input chrome without losing the editable row" do
    for {width, height} <- [{1, 5}, {4, 8}, {20, 2}, {20, 3}] do
      state = input_state(width, height)
      :ok = Input.set_value(state.input, "x")
      state = state |> Viewport.update_draft() |> Viewport.relayout()
      {widget, rect} = composer(state)

      assert widget.block == nil
      assert rect.height >= 1
      assert rect.y + rect.height <= height
      assert Layout.composer_content_width(width, height) == width
      assert state.draft_lines == Input.rows(state.input, width)

      terminal = ExRatatui.init_test_terminal(width, height)
      :ok = ExRatatui.draw(terminal, [{widget, rect}])
      assert ExRatatui.get_buffer_content(terminal) =~ "x"
    end
  end

  defp input_state(width, height) do
    %State{
      input: Input.new(),
      agent_state: Tackle.Lib.State.new(),
      size: {width, height},
      conversation: Viewport.new_conversation(width, height)
    }
  end

  defp composer(state) do
    state
    |> View.scene(nil)
    |> Enum.find(fn {widget, _rect} -> match?(%Input{}, widget) end)
  end

  test "paste and grapheme edits are undoable; replacing the draft clears history" do
    input = Input.new()
    state = %State{input: input, conversation: Viewport.new_conversation(80, 24)}
    Composer.paste(state, "界é👩‍💻\r\nnext")
    assert Input.get_value(input) == "界é👩‍💻\nnext"
    :ok = Input.handle_key(input, "u", ["ctrl"], 20)
    assert Input.get_value(input) == ""
    :ok = Input.handle_key(input, "r", ["ctrl"], 20)
    :ok = Input.handle_key(input, "home", [], 20)
    :ok = Input.handle_key(input, "left", [], 20)
    :ok = Input.handle_key(input, "backspace", [], 20)
    assert Input.get_value(input) == "界é\nnext"
    :ok = Input.set_value(input, "")
    :ok = Input.handle_key(input, "u", ["ctrl"], 20)
    assert Input.get_value(input) == ""
  end

  test "painting scrolls to the insertion cell, clips wide glyphs, and hides unfocused caret" do
    input = Input.new()
    :ok = Input.set_value(input, "abcd")
    assert {:ok, rows} = Native.input_render(input, 4, 1, "", true)
    assert [{" ", nil, nil, nil, 64}, {"   ", nil, nil, nil, 0}] = hd(rows)

    assert {:ok, [[{"    ", nil, nil, nil, 0}]]} =
             Native.input_render(input, 4, 1, "", false)

    :ok = Input.set_value(input, "界")
    :ok = Input.handle_key(input, "home", [], 1)
    assert {:ok, [[{"�", nil, nil, nil, 64}]]} = Native.input_render(input, 1, 1, "", true)
    assert Input.get_value(input) == "界"
    assert {:ok, []} = Native.input_render(input, 0, 0, "", true)
  end

  test "controls are display-only replacements and placeholder paint is sanitized" do
    input = Input.new()
    source = "x\t\e[31m"
    :ok = Input.set_value(input, source)
    assert {:ok, rows} = Native.input_render(input, 20, 1, "", false)
    painted = for row <- rows, {text, _, _, _, _} <- row, into: "", do: text
    assert painted =~ "x �[31m"
    refute painted =~ "\e"
    assert Input.get_value(input) == source

    :ok = Input.set_value(input, "")

    widget = %Input{
      state: input,
      placeholder: "\e[31mPrompt\e[0m",
      block: %Block{borders: [:all]}
    }

    rect = %Rect{x: 5, y: 7, width: 20, height: 3}

    assert [{%Block{}, ^rect}, {%Paragraph{text: lines}, inner}] =
             ExRatatui.Widget.render(widget, rect)

    assert inner == %Rect{x: 6, y: 8, width: 18, height: 1}
    assert Enum.map_join(hd(lines).spans, & &1.content) =~ "Prompt"
  end

  test "unknown chords are inert and word deletion preserves the remaining source" do
    input = Input.new()
    :ok = Input.set_value(input, "one two  ")
    :ok = Input.handle_key(input, "g", ["alt"], 20)
    :ok = Input.handle_key(input, "x", ["ctrl", "shift"], 20)
    assert Input.get_value(input) == "one two  "
    :ok = Input.handle_key(input, "w", ["ctrl"], 20)
    assert Input.get_value(input) == "one "
  end

  test "emacs word navigation uses grapheme-safe whitespace boundaries" do
    input = Input.new()
    :ok = Input.set_value(input, "one  βéta\nthree  ")

    :ok = Input.handle_key(input, "b", ["alt"], 20)
    :ok = Input.insert_str(input, "|")
    assert Input.get_value(input) == "one  βéta\n|three  "

    :ok = Input.set_value(input, "one  βéta\nthree  ")
    :ok = Input.handle_key(input, "b", ["ctrl"], 20)
    :ok = Input.handle_key(input, "b", ["ctrl"], 20)
    :ok = Input.insert_str(input, "|")
    assert Input.get_value(input) == "one  |βéta\nthree  "

    :ok = Input.set_value(input, "one  βéta\nthree  ")
    Enum.each(1..3, fn _ -> :ok = Input.handle_key(input, "b", ["alt"], 20) end)
    :ok = Input.handle_key(input, "f", ["alt"], 20)
    :ok = Input.handle_key(input, "f", ["alt"], 20)
    :ok = Input.insert_str(input, "|")
    assert Input.get_value(input) == "one  βéta|\nthree  "

    :ok = Input.set_value(input, "one  βéta\nthree  ")
    Enum.each(1..3, fn _ -> :ok = Input.handle_key(input, "b", ["ctrl"], 20) end)
    :ok = Input.handle_key(input, "f", ["ctrl"], 20)
    :ok = Input.handle_key(input, "f", ["ctrl"], 20)
    :ok = Input.handle_key(input, "f", ["ctrl"], 20)
    :ok = Input.insert_str(input, "|")
    assert Input.get_value(input) == "one  βéta\nthree|  "
  end

  test "the native boundary rejects oversized areas and control-bearing placeholders" do
    input = Input.new()
    assert {:error, :invalid_size} = Native.input_render(input, 257, 256, "", true)
    assert_raise ArgumentError, fn -> Native.input_render(input, 1, 1, "\e", true) end
    assert_raise ArgumentError, fn -> Input.set_value(input, <<255>>) end
  end
end
