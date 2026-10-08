defmodule Tackle.CLI.TUI.PastesTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.{MessageView, Pastes, State}
  alias Tackle.CLI.TUI.Pastes.Draft
  alias Tackle.CLI.Widgets.Input

  test "only long text is collapsed, and the label counts characters" do
    state = new_state()
    assert Pastes.long_text?(String.duplicate("x", 1_000))
    refute Pastes.long_text?(String.duplicate("x", 999))
    # Counting bytes would collapse this 999-character paste instead.
    refute Pastes.long_text?(String.duplicate("界", 999))

    text = String.duplicate("long line\n", 120)
    label = "[Pasted Content #{String.length(text)} chars]"
    state = Pastes.insert(state, :text, text)
    assert Input.get_value(state.input) == label
    assert Pastes.resolve(Pastes.draft(state), state) == {:ok, String.trim(text)}

    assert Pastes.collapse("look at #{String.trim_trailing(text)}", state) ==
             "look at #{label}"

    state = %{state | pending_prompt: "look at #{String.trim_trailing(text)}"}
    [entry] = MessageView.section_entries(state, :pending)
    assert entry.content == "look at #{label}"
    assert entry.source == state.pending_prompt
  end

  test "pastes of one size share a base label and are told apart by a suffix" do
    state = new_state()
    text = String.duplicate("x", 1_200)
    label = "[Pasted Content 1200 chars]"

    state = Pastes.insert(state, :text, text)
    state = Pastes.insert(state, :text, text <> "!")
    state = Pastes.insert(state, :text, text)

    assert Input.get_value(state.input) == "#{label} [Pasted Content 1201 chars] #{label} #2"
    assert Pastes.resolve(Pastes.draft(state), state) == {:ok, "#{text} #{text}! #{text}"}
  end

  test "a label removed from the draft is still spoken for" do
    state = new_state()
    text = String.duplicate("x", 1_200)
    state = Pastes.insert(state, :text, text)
    :ok = Input.set_value(state.input, "")
    state = Pastes.insert(state, :text, text)
    assert Input.get_value(state.input) == "[Pasted Content 1200 chars] #2"
    assert Pastes.resolve(Pastes.draft(state), state) == {:ok, text}

    state = Pastes.insert(state, :image, " inspect /tmp/image.png ")
    :ok = Input.set_value(state.input, "")
    state = Pastes.insert(state, :image, " inspect /tmp/other.png ")
    assert Input.get_value(state.input) == "[Image #2]"
    assert Pastes.resolve(Pastes.draft(state), state) == {:ok, "inspect /tmp/other.png"}
  end

  test "image instructions appear as numbered labels" do
    state = new_state()
    instruction = " Please use the read tool to inspect this image: /tmp/image.png "
    state = Pastes.insert(state, :image, instruction, source: "/tmp/image.png")

    assert Input.get_value(state.input) == "[Image #1]"
    assert Pastes.resolve(Pastes.draft(state), state) == {:ok, String.trim(instruction)}

    # A transcript preview names the file the label stands for.
    assert Pastes.collapse(String.trim(instruction), state) == "[Image #1] image.png"

    # A second instruction is numbered after it; without a file name its label
    # stands alone, as the composer shows it.
    other = " Please use the read tool to inspect this image: /tmp/shot.jpg "
    state = Pastes.insert(state, :image, other)
    assert Input.get_value(state.input) == "[Image #1] [Image #2]"

    assert {:ok, prompt} = Pastes.resolve(Pastes.draft(state), state)
    assert prompt == String.trim("#{instruction} #{other}")
    assert Pastes.collapse(String.trim(other), state) == "[Image #2]"
  end

  test "a label an edit left behind is not a paste" do
    state = new_state()

    # Nothing retained: this is text the user typed.
    :ok = Input.insert_str(state.input, "describe [Image #9]")
    assert Pastes.resolve(Pastes.draft(state), state) == {:ok, "describe [Image #9]"}

    text = String.duplicate("x", 1_200)
    :ok = Input.set_value(state.input, "")
    state = Pastes.insert(state, :text, text)
    :ok = Input.insert_str(state.input, " and [Image #9] and [Pasted Content 12 char")
    label = Input.get_value(state.input)

    # Only the label the editor still holds as an element expands; the
    # lookalikes reach the model exactly as they were typed.
    assert {:ok, prompt} = Pastes.resolve(Pastes.draft(state), state)

    assert prompt ==
             String.trim(text) <> " and [Image #9] and [Pasted Content 12 char"

    assert Pastes.collapse(String.trim(text), state) == "[Pasted Content 1200 chars]"
    assert label =~ "[Pasted Content 1200 chars] and [Image #9]"
  end

  test "an element the session cannot expand is refused" do
    state = new_state()

    # A label the editor holds but the session has no payload for: the shape a
    # restored draft would have if its payloads were gone.
    {:ok, [{9, 4, 14}]} = Input.restore(state.input, "see [Image #4]", [{9, 4, 14}])

    assert Pastes.resolve(Pastes.draft(state), state) ==
             {:error, {:missing_pastes, ["[Image #4]"]}}
  end

  test "a stale span is dropped from the restored draft, label and all" do
    state = new_state()
    label = "[Pasted Content 1200 chars]"
    :ok = Input.insert_str(state.input, "keep ")
    state = Pastes.insert(state, :text, String.duplicate("x", 1_200))
    assert Input.get_value(state.input) == "keep #{label}"

    # A snapshot whose span outlives the text it names: the editor attaches
    # nothing, and the draft must not fall back to sending the label as prose.
    stale = %Draft{text: "keep #{label}", spans: [{1, 5, byte_size(label) + 99}]}
    restored = Pastes.restore(state, stale)

    assert restored.notice == "Paste labels could not be restored · draft kept"
    assert Input.get_value(restored.input) == "keep "
    assert Pastes.resolve(Pastes.draft(restored), restored) == {:ok, "keep"}
  end

  test "collapse prefers one label when two pastes share their content" do
    state = new_state()
    instruction = " Please use the read tool to inspect this image: /tmp/image.png "
    state = Pastes.insert(state, :image, instruction, source: "/tmp/image.png")
    state = Pastes.insert(state, :image, instruction, source: "/tmp/image.png")
    assert Input.get_value(state.input) == "[Image #1] [Image #2]"

    # One content maps to one label: the first payload that carried it.
    assert Pastes.collapse(String.trim(instruction), state) == "[Image #1] image.png"
  end

  test "a draft carries its labels through normalize, merge, and restore" do
    state = new_state()
    first = String.duplicate("x", 1_200)
    second = String.duplicate("y", 1_300)

    state = Pastes.insert(state, :text, first)
    :ok = Input.insert_str(state.input, " middle")
    live = Pastes.draft(state)
    label = "[Pasted Content 1200 chars]"
    assert live.text == "#{label} middle"
    assert live.spans == [{1, 0, byte_size(label)}]

    :ok = Input.set_value(state.input, "")
    state = Pastes.insert(state, :text, second)
    older = Pastes.draft(state)
    assert older.text == "[Pasted Content 1300 chars]"

    # A withdrawn queued message rejoins the live draft above it, and both
    # labels are still addressable.
    merged = Pastes.merge(older, live)
    assert merged.text == "[Pasted Content 1300 chars]\n#{label} middle"
    state = Pastes.restore(state, merged)
    assert Input.get_value(state.input) == merged.text
    assert Pastes.resolve(Pastes.draft(state), state) == {:ok, "#{second}\n#{first} middle"}
  end

  test "normalize trims around a label without cutting it" do
    label = "[Pasted Content 1200 chars]"
    draft = Draft.new("  #{label}  ", [{1, 2, 2 + byte_size(label)}])

    assert %Draft{text: ^label, spans: [{1, 0, span_end}]} = Pastes.normalize(draft)
    assert span_end == byte_size(label)

    # A draft that is only whitespace has nothing to record.
    assert Pastes.normalize(Draft.new("   ")) == nil
    assert Pastes.normalize(Draft.new("")) == nil
  end

  test "an expanded prompt past the limit is refused" do
    limit = Pastes.max_prompt_chars()
    state = Pastes.insert(new_state(), :text, String.duplicate("x", limit))

    assert Pastes.resolve(Pastes.draft(state), state) == {:ok, String.duplicate("x", limit)}

    :ok = Input.insert_str(state.input, "x")

    assert Pastes.resolve(Pastes.draft(state), state) ==
             {:error, {:prompt_too_long, limit + 1}}
  end

  defp new_state do
    input = Input.new()
    %State{input: input}
  end
end
