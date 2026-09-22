defmodule Tackle.CLI.Widgets.InputTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph}
  alias Tackle.CLI.Native
  alias Tackle.CLI.TUI.{Composer, State, Viewport}
  alias Tackle.CLI.Widgets.Input

  test "measurement, resize, and vertical editing use the same soft wraps" do
    input = Input.new()
    :ok = Input.insert_str(input, "abcdefgh")

    state = %State{
      input: input,
      agent_state: Tackle.Lib.State.new(),
      size: {6, 20},
      conversation: Viewport.new_conversation(6, 20)
    }

    state = state |> Viewport.update_draft() |> Viewport.relayout()
    assert state.draft_lines == 3

    :ok = Input.handle_key(input, "up", [], 4)
    :ok = Input.insert_str(input, "!")
    assert Input.get_value(input) == "abcd!efgh"

    resized = Viewport.resize(%{state | size: {20, 20}})
    assert resized.draft_lines == 1
    assert Input.get_value(input) == "abcd!efgh"
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
