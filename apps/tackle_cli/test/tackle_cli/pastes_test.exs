defmodule Tackle.CLI.TUI.PastesTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.{MessageView, Pastes, State}
  alias Tackle.CLI.Widgets.Input

  test "only long text is collapsed; expansion and transcript retain full source" do
    input = Input.new()
    state = %State{input: input}
    assert Pastes.long_text?(String.duplicate("x", 1_000))
    refute Pastes.long_text?(String.duplicate("x", 999))

    text = String.duplicate("long line\n", 120)
    state = Pastes.insert(state, :text, text)
    assert Input.get_value(input) == "[text-1]"
    assert Pastes.expand("look at [text-1]", state) == "look at #{text}"

    preview = Pastes.collapse("look at #{String.trim_trailing(text)}", state)
    assert preview == "look at [text-1]"
    state = %{state | pending_prompt: "look at #{String.trim_trailing(text)}"}
    [entry] = MessageView.section_entries(state, :pending)
    assert entry.content == "look at [text-1]"
    assert entry.source == state.pending_prompt
  end

  test "image path instructions show only numbered tokens in transcript" do
    input = Input.new()
    state = %State{input: input}
    instruction = " Please use the read tool to inspect this image: /tmp/image.png "
    state = Pastes.insert(state, :image, instruction)
    assert Input.get_value(input) == "[image-1]"
    assert Pastes.expand("[image-1]", state) == instruction
    assert Pastes.collapse(String.trim(instruction), state) == "[image-1]"
  end
end
