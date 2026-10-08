defmodule Tackle.CLI.TUI.PastesTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.{MessageView, Pastes, State}
  alias Tackle.CLI.Widgets.Input

  test "only long text is collapsed, and the label counts characters" do
    input = Input.new()
    state = %State{input: input}
    assert Pastes.long_text?(String.duplicate("x", 1_000))
    refute Pastes.long_text?(String.duplicate("x", 999))
    # Counting bytes would collapse this 999-character paste instead.
    refute Pastes.long_text?(String.duplicate("界", 999))

    text = String.duplicate("long line\n", 120)
    label = "[Pasted Content #{String.length(text)} chars]"
    state = Pastes.insert(state, :text, text)
    assert Input.get_value(input) == label
    assert Pastes.resolve("look at #{label}", state) == {:ok, "look at #{String.trim(text)}"}

    assert Pastes.collapse("look at #{String.trim_trailing(text)}", state) ==
             "look at #{label}"

    state = %{state | pending_prompt: "look at #{String.trim_trailing(text)}"}
    [entry] = MessageView.section_entries(state, :pending)
    assert entry.content == "look at #{label}"
    assert entry.source == state.pending_prompt
  end

  test "pastes of one size share a base label and are told apart by a suffix" do
    input = Input.new()
    state = %State{input: input}
    text = String.duplicate("x", 1_200)
    label = "[Pasted Content 1200 chars]"

    state = Pastes.insert(state, :text, text)
    state = Pastes.insert(state, :text, text <> "!")
    state = Pastes.insert(state, :text, text)

    assert Input.get_value(input) == "#{label} [Pasted Content 1201 chars] #{label} #2"
    assert Pastes.resolve(Input.get_value(input), state) == {:ok, "#{text} #{text}! #{text}"}
  end

  test "a label removed from the draft is still spoken for" do
    input = Input.new()
    state = %State{input: input}
    text = String.duplicate("x", 1_200)
    state = Pastes.insert(state, :text, text)
    :ok = Input.set_value(input, "")
    state = Pastes.insert(state, :text, text)
    assert Input.get_value(input) == "[Pasted Content 1200 chars] #2"
    assert Pastes.resolve(Input.get_value(input), state) == {:ok, text}

    state = Pastes.insert(state, :image, " inspect /tmp/image.png ")
    :ok = Input.set_value(input, "")
    state = Pastes.insert(state, :image, " inspect /tmp/other.png ")
    assert Input.get_value(input) == "[Image #2]"
    assert Pastes.resolve(Input.get_value(input), state) == {:ok, "inspect /tmp/other.png"}
  end

  test "image instructions appear as numbered labels" do
    input = Input.new()
    state = %State{input: input}
    instruction = " Please use the read tool to inspect this image: /tmp/image.png "
    state = Pastes.insert(state, :image, instruction)

    assert Input.get_value(input) == "[Image #1]"
    assert Pastes.resolve("[Image #1]", state) == {:ok, String.trim(instruction)}
    assert Pastes.collapse(String.trim(instruction), state) == "[Image #1]"

    state = Pastes.insert(state, :image, instruction)
    assert Input.get_value(input) == "[Image #1] [Image #2]"

    assert {:ok, prompt} = Pastes.resolve(Input.get_value(input), state)
    assert prompt == String.trim("#{instruction} #{instruction}")
  end

  test "a label without retained content is refused instead of sent" do
    input = Input.new()
    state = %State{input: input}

    assert Pastes.resolve("[Image #9] describe it", state) ==
             {:error, {:unresolved_pastes, ["[Image #9]"]}}

    assert Pastes.resolve("describe [Image #", state) ==
             {:error, {:unresolved_pastes, ["[Image #"]}}

    text = String.duplicate("x", 1_200)
    state = Pastes.insert(state, :text, text)
    # An edit truncated the label, so nothing can be expanded in its place.
    assert Pastes.resolve("[Pasted Content 1200 char", state) ==
             {:error, {:unresolved_pastes, ["[Pasted Content 1200 char"]}}

    # Deleting the opening bracket leaves the label recognisable.
    assert Pastes.resolve("describe Image #1]", state) ==
             {:error, {:unresolved_pastes, ["Image #1]"]}}

    assert Pastes.resolve("describe Pasted Content 1200 chars]", state) ==
             {:error, {:unresolved_pastes, ["Pasted Content 1200 chars]"]}}

    assert Pastes.resolve("[Pasted Content 1200 chars]", state) == {:ok, text}
  end

  test "a same-size label with no content of its own is refused whole" do
    input = Input.new()
    state = %State{input: input}
    state = Pastes.insert(state, :text, String.duplicate("x", 1_200))

    # Only the base label is retained, so the `#2` variant must not be sent as
    # its own text, and must not be mistaken for the base label either.
    assert Pastes.resolve("[Pasted Content 1200 chars] #2", state) ==
             {:error, {:unresolved_pastes, ["[Pasted Content 1200 chars] #2"]}}
  end

  test "a suffix left behind by an edit is refused" do
    input = Input.new()
    state = %State{input: input}
    text = String.duplicate("x", 1_200)
    state = Pastes.insert(state, :text, text)
    state = Pastes.insert(state, :text, text)
    assert Input.get_value(input) == "[Pasted Content 1200 chars] [Pasted Content 1200 chars] #2"

    # A backspace removed the `2`, so the second paste is no longer addressable.
    assert Pastes.resolve("[Pasted Content 1200 chars] [Pasted Content 1200 chars] #", state) ==
             {:error, {:unresolved_pastes, ["[Pasted Content 1200 chars] #"]}}
  end

  test "only the labels with no content are reported" do
    input = Input.new()
    state = %State{input: input}
    state = Pastes.insert(state, :image, " inspect /tmp/image.png ")

    assert Pastes.resolve("[Image #1] explain [Image #9]", state) ==
             {:error, {:unresolved_pastes, ["[Image #9]"]}}
  end

  test "prose that only mentions pasting is sent as written" do
    input = Input.new()
    state = %State{input: input}

    assert Pastes.resolve("see [Image tool docs] then [1]", state) ==
             {:ok, "see [Image tool docs] then [1]"}

    # A label is recognised by its count and brackets, so the phrases alone,
    # and a bare reference like this one, stay literal.
    assert Pastes.resolve("see Image #1 for the layout", state) ==
             {:ok, "see Image #1 for the layout"}

    assert Pastes.resolve("the composer shows [Pasted Content", state) ==
             {:ok, "the composer shows [Pasted Content"}
  end

  test "an expanded prompt past the limit is refused" do
    limit = Pastes.max_prompt_chars()
    input = Input.new()
    state = Pastes.insert(%State{input: input}, :text, String.duplicate("x", limit))
    label = Input.get_value(input)

    assert Pastes.resolve(label, state) == {:ok, String.duplicate("x", limit)}
    assert Pastes.resolve(label <> "x", state) == {:error, {:prompt_too_long, limit + 1}}
  end
end
