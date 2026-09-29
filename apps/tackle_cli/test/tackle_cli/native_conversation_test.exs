defmodule Tackle.CLI.Widgets.ConversationTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias Tackle.CLI.Native
  alias Tackle.CLI.TUI.{Conversation, MessageView, Theme, Viewport}
  alias Tackle.CLI.TUI.State.Stream
  alias Tackle.CLI.Widgets.Conversation, as: Widget
  alias Tackle.CLI.Widgets.Input
  alias Tackle.Lib.{Message, State}

  test "all entry types paint in chronological order through a native snapshot" do
    messages = [
      Message.user("question"),
      Message.assistant(
        thinking: "reasoning",
        content: "**answer**",
        tool_calls: [
          %{id: "read", name: "read", arguments: %{"path" => "file.ex"}}
        ]
      ),
      Message.tool_result("read", "read", "tool-output")
    ]

    model =
      Conversation.new(%Rect{width: 80, height: 30}) |> Conversation.refresh(projection(messages))

    text = paint(model)
    assert text =~ "question"
    refute text =~ "reasoning"
    assert text =~ "answer"
    refute text =~ "**answer**"
    assert text =~ "file.ex"
    refute text =~ "tool-output"
    refute text =~ "F4 details"
    assert List.last(Conversation.entries(model)).tool_output == "tool-output"

    assert Enum.map(Conversation.entries(model), & &1.kind) == [
             :user,
             :thinking,
             :assistant,
             :tool
           ]
  end

  test "native message gutters align wrapped prose and preserve plain prompt source" do
    source = "  **raw**\nnext\n"

    model =
      Conversation.new(%Rect{width: 10, height: 12})
      |> Conversation.refresh(
        projection([Message.user(source), Message.assistant(content: "**answer**")])
      )
      |> Conversation.scroll_to(:start)

    rows = String.split(paint(model), "\n")
    assert Enum.take(rows, 4) == ["›    **r  ", "   aw**   ", "   next   ", "          "]
    assert Enum.any?(rows, &String.starts_with?(&1, "●  answe"))
    assert MessageView.source(Conversation.entry(model, "message:0:user")) == source

    tiny = Conversation.resize(model, %Rect{width: 1, height: 12})
    refute paint(tiny) =~ "›"
    assert paint(tiny) =~ "*"
  end

  test "tail replacement and selection reuse settled cells and leave old scenes intact" do
    state = projection([Message.assistant(content: "# settled")])
    state = %{state | stream: %Stream{timeline: [%{kind: :assistant, content: "old tail"}]}}
    old = Conversation.new(%Rect{width: 30, height: 10}) |> Conversation.refresh(state)
    updated = %{state | stream: %Stream{timeline: [%{kind: :assistant, content: "new tail"}]}}
    new = Conversation.refresh(old, updated, [:turn])
    assert old.sections.settled.groups == new.sections.settled.groups
    refute old.sections.turn.groups == new.sections.turn.groups
    assert paint(old) =~ "old tail"
    refute paint(old) =~ "new tail"
    assert paint(new) =~ "new tail"

    selected = Conversation.refresh(new, Map.put(updated, :selected_entry, "message:0:assistant"))
    assert new.sections.settled.groups == selected.sections.settled.groups
    [{%Paragraph{text: rows}, _}] = Widget.render(Conversation.widget(selected), selected.rect)
    assert Enum.all?(hd(rows).spans, &(&1.style.bg == Theme.style(:selection_surface).bg))
  end

  test "width changes invalidate cells without losing the reading anchor or raw source" do
    source = "# title\n\n" <> String.duplicate("long response ", 40)
    state = projection([Message.assistant(content: source), Message.user("after")])

    wide =
      Conversation.new(%Rect{width: 80, height: 4})
      |> Conversation.refresh(state)
      |> Conversation.scroll_to(:start)

    narrow = Conversation.resize(wide, %Rect{width: 15, height: 4})

    assert narrow.anchor == wide.anchor
    refute narrow.follow?
    assert narrow.content_height > wide.content_height
    refute narrow.sections.settled.groups == wide.sections.settled.groups
    assert Conversation.text(narrow) =~ source
    assert paint(narrow) =~ "title"
  end

  test "Elixir fences highlight both settled and streaming assistant code without showing fences" do
    for source <- [
          "```elixir\nIO.puts(\"hello\")\n```",
          "```elixir\nIO.puts(\"hello\")"
        ] do
      entry = %MessageView{kind: :assistant, content: source}
      cells = Widget.cell(entry, 36)
      {scene, height} = Widget.assemble(cells, 36)

      {:ok, rows} =
        Native.conversation_render(scene, 36, height, 0, [], Widget.style(%ExRatatui.Style{}))

      painted = Enum.map_join(rows, "\n", fn row -> Enum.map_join(row, &elem(&1, 0)) end)

      assert painted =~ "elixir"
      assert painted =~ "IO.puts(\"hello\")"
      refute painted =~ "```"

      assert Enum.any?(List.flatten(rows), fn {text, fg, _bg, _under, _modifiers} ->
               text == "IO" and match?({_, _, _}, fg)
             end)

      # Every cell of the snippet, including indentation, padding and trailing
      # whitespace, carries the same surface rather than the highlighter's bg.
      code_bg = Widget.style(Theme.style(:code_surface)) |> elem(1)

      assert Enum.all?(List.flatten(rows), fn {_text, _fg, bg, _under, _modifiers} ->
               bg == code_bg
             end)

      assert MessageView.source(entry) == source
    end
  end

  test "shell and Erlang fences share the code surface in settled and streaming messages" do
    for {language, snippet} <- [{"sh", "echo hello"}, {"erlang", "hello() -> ok."}],
        source <- ["```#{language}\n#{snippet}\n```", "```#{language}\n#{snippet}"] do
      cells = Widget.cell(%MessageView{kind: :assistant, content: source}, 36)
      {scene, height} = Widget.assemble(cells, 36)

      {:ok, rows} =
        Native.conversation_render(scene, 36, height, 0, [], Widget.style(%ExRatatui.Style{}))

      painted = Enum.map_join(rows, "\n", fn row -> Enum.map_join(row, &elem(&1, 0)) end)
      assert painted =~ language
      assert painted =~ snippet
      refute painted =~ "```"

      assert Enum.any?(List.flatten(rows), fn {text, fg, _bg, _under, _modifiers} ->
               text in ["echo", "hello"] and match?({_, _, _}, fg)
             end)

      code_bg = Widget.style(Theme.style(:code_surface)) |> elem(1)

      assert Enum.all?(List.flatten(rows), fn {_text, _fg, bg, _under, _modifiers} ->
               bg == code_bg
             end)
    end
  end

  test "every fenced language uses the same code surface, including unknown and unlabelled code" do
    for {language, snippet} <- [
          {"python", "print(1)"},
          {"rust", "fn main() {}"},
          {"json", "{\"ok\": true}"},
          {"made-up-language", "raw code"},
          {"", "plain code"}
        ],
        source <- ["```#{language}\n#{snippet}\n```", "```#{language}\n#{snippet}"] do
      cells = Widget.cell(%MessageView{kind: :assistant, content: source}, 40)
      {scene, height} = Widget.assemble(cells, 40)

      {:ok, rows} =
        Native.conversation_render(scene, 40, height, 0, [], Widget.style(%ExRatatui.Style{}))

      painted = Enum.map_join(rows, "\n", fn row -> Enum.map_join(row, &elem(&1, 0)) end)
      assert painted =~ snippet
      refute painted =~ "```"

      code_bg = Widget.style(Theme.style(:code_surface)) |> elem(1)

      assert Enum.all?(List.flatten(rows), fn {_text, _fg, bg, _under, _modifiers} ->
               bg == code_bg
             end)
    end
  end

  test "Elixir code keeps indentation and wraps with the message gutter" do
    source = "before\n\n```ex\n    IO.puts(\"hello\")\n```\n\nafter"
    cells = Widget.cell(%MessageView{kind: :assistant, content: source}, 12)
    {scene, height} = Widget.assemble(cells, 12)

    {:ok, rows} =
      Native.conversation_render(scene, 12, height, 0, [], Widget.style(%ExRatatui.Style{}))

    painted = Enum.map(rows, fn row -> Enum.map_join(row, &elem(&1, 0)) end)

    assert length(cells) == 3
    assert Enum.any?(painted, &String.starts_with?(&1, "    elixir"))
    assert Enum.any?(painted, &String.starts_with?(&1, "       IO."))
    assert Enum.any?(painted, &String.starts_with?(&1, "   after"))
    assert Enum.all?(tl(painted), &String.starts_with?(&1, "   "))
    refute Enum.join(painted) =~ "```"
  end

  test "native paint sanitizes direct callers, bounds buffers and rejects mixed widths" do
    style = Widget.style(%ExRatatui.Style{})
    source = "safe\e]52;c;secret\a\e[31m red\e[0m\tend\u009b31m!"
    {cell, _} = Native.conversation_markdown(source, 30, style)
    {native, _} = Native.conversation_new([cell], 30)
    {:ok, rows} = Native.conversation_render(native, 30, 2, 0, [], style)
    text = for row <- rows, {text, _, _, _, _} <- row, into: "", do: text
    assert text =~ "safe red"
    refute text =~ "secret"
    refute text =~ "\e"
    assert {:ok, []} = Native.conversation_render(native, 0, 0, 0, [], style)
    assert {:error, :invalid_size} = Native.conversation_render(native, 257, 256, 0, [], style)

    assert_raise ArgumentError, fn ->
      Native.conversation_render(native, 20, 2, 0, [], style)
    end

    assert_raise ArgumentError, fn -> Native.conversation_new([cell], 20) end
    assert_raise ArgumentError, fn -> Native.conversation_markdown(<<255>>, 20, style) end

    assert_raise ArgumentError, fn ->
      Native.conversation_rows([{[], {nil, nil, nil, 32}}], 20)
    end
  end

  test "live reasoning expands and collapses without changing source or draft" do
    input = Input.new()
    :ok = Input.set_value(input, "keep draft")

    state = %Tackle.CLI.TUI.State{
      input: input,
      agent_state: State.new(),
      size: {80, 24},
      conversation: Conversation.new(%Rect{width: 80, height: 18}),
      stream: %Stream{timeline: [%{kind: :thinking, content: "first\nsecond\nthird"}]}
    }

    state = Viewport.refresh(state)
    refute paint(state.conversation) =~ "third"
    {:noreply, expanded} = Viewport.toggle_thinking(state)
    assert paint(expanded.conversation) =~ "third"
    {:noreply, collapsed} = Viewport.toggle_thinking(expanded)
    refute paint(collapsed.conversation) =~ "third"
    assert Conversation.text(collapsed.conversation) =~ "third"
    assert Input.get_value(input) == "keep draft"
  end

  test "copy and search retain controls removed by paint" do
    source = "hello\e[31m red\e[0m"

    model =
      Conversation.new(%Rect{width: 40, height: 4})
      |> Conversation.refresh(projection([Message.assistant(content: source)]))

    assert [%{entry: entry}] = Conversation.search(model, "red")
    assert MessageView.source(entry) == source
    refute paint(model) =~ "\e"
  end

  defp paint(model) do
    [{%Paragraph{text: rows}, _}] = Widget.render(Conversation.widget(model), model.rect)
    Enum.map_join(rows, "\n", fn row -> Enum.map_join(row.spans, & &1.content) end)
  end

  test "unchanged and selection-only refreshes retain the whole snapshot, including welcome" do
    for messages <- [[], [Message.assistant(content: "# settled")]] do
      state = projection(messages)
      old = Conversation.new(%Rect{width: 30, height: 10}) |> Conversation.refresh(state)
      same = Conversation.refresh(old, state)
      assert same.native == old.native
      assert :erts_debug.same(same.items, old.items)
      assert :erts_debug.same(same.layouts, old.layouts)

      selected = Conversation.refresh(old, Map.put(state, :selected_entry, "message:0:assistant"))
      assert selected.native == old.native
      assert :erts_debug.same(selected.items, old.items)
    end
  end

  test "growing prose reuses completed fence cells without retaining obsolete tail versions" do
    source = "Intro\n\n```elixir\nIO.puts(:ok)\n```\n\nTail"
    state = %{projection([]) | stream: %Stream{timeline: [%{kind: :assistant, content: source}]}}
    old = Conversation.new(%Rect{width: 30, height: 16}) |> Conversation.refresh(state)

    changed = %{
      state
      | stream: %Stream{timeline: [%{kind: :assistant, content: source <> " extended"}]}
    }

    new = Conversation.refresh(old, changed, [:turn])
    [before] = old.sections.turn.groups
    [after_items] = new.sections.turn.groups
    assert Enum.take(before, 2) == Enum.take(after_items, 2)
    refute List.last(before) == List.last(after_items)
    assert map_size(new.sections.turn.cells["streaming:response"]) == 3
    refute paint(old) =~ "extended"
    assert paint(new) =~ "extended"

    fresh = Conversation.new(new.rect) |> Conversation.refresh(changed)
    assert paint(new) == paint(fresh)
    assert new.content_height == fresh.content_height
  end

  test "segment cache invalidates width, style, language and first-segment marker" do
    entry = %MessageView{kind: :assistant, content: "```elixir\nIO.puts(:ok)\n```"}
    {[old], cache} = Widget.cached_cell(entry, 40, %{})
    {[same], _} = Widget.cached_cell(entry, 40, cache)
    assert same == old
    {[narrow], _} = Widget.cached_cell(entry, 20, cache)
    refute narrow == old
    {[styled], _} = Widget.cached_cell(%{entry | style: Theme.style(:muted)}, 40, cache)
    refute styled == old

    {[language], _} =
      Widget.cached_cell(%{entry | content: "```shell\nIO.puts(:ok)\n```"}, 40, cache)

    refute language == old

    {[_prose, moved], _} =
      Widget.cached_cell(%{entry | content: "before\n" <> entry.content}, 40, cache)

    refute moved == old
  end

  test "cached streaming segmentation and Markdown match fresh snapshots after every append" do
    sources = [
      ["title", "\n---", "\n\n[ref][id]", "\n\n[id]: https://example.com"],
      ["intro\n\n`", "``elixir", "\nIO.puts(\"a", "\")", "\n`", "``", "\n\n**after", "**"],
      ["~~~shell\necho hi", "\n~~~~", "\n\ntext", "\n```", "\nmore"]
    ]

    for deltas <- sources do
      Enum.reduce(deltas, {Conversation.new(%Rect{width: 24, height: 20}), ""}, fn delta,
                                                                                   {old, source} ->
        source = source <> delta

        state = %{
          projection([])
          | stream: %Stream{timeline: [%{kind: :assistant, content: source}]}
        }

        new = Conversation.refresh(old, state, [:turn])
        fresh = Conversation.new(new.rect) |> Conversation.refresh(state)
        assert new.content_height == fresh.content_height
        assert paint(new) == paint(fresh)
        {new, source}
      end)
    end
  end

  test "section composition matches flat paint across empty sections and transitions" do
    state = projection([Message.user("settled")])

    states = [
      %{
        state
        | pending_prompt: "pending",
          stream: %Stream{timeline: [%{kind: :assistant, content: "tail"}]},
          error: "failure"
      },
      %{state | pending_prompt: "pending"},
      %{projection([]) | stream: %Stream{timeline: [%{kind: :assistant, content: "only tail"}]}},
      projection([]),
      %{projection([]) | error: "only error"}
    ]

    Enum.reduce(states, Conversation.new(%Rect{width: 20, height: 3}), fn state, old ->
      new = Conversation.refresh(old, state)
      {flat, height} = Widget.assemble(new.items, new.width)
      assert height == new.content_height

      for offset <- 0..height do
        assert paint(%{new | scroll_offset: offset}) ==
                 paint(%{new | native: flat, scroll_offset: offset})

        scrolled = Conversation.scroll_to(new, :start) |> Conversation.scroll(offset)

        assert {scrolled.visible_items, scrolled.visible_offset} ==
                 Conversation.slice(new.items, scrolled.scroll_offset, new.viewport_height)
      end

      new
    end)
  end

  test "native section replacement rejects invalid index and widths" do
    {cell, _} = Native.conversation_rows([], 20)
    {other, _} = Native.conversation_rows([], 10)
    {native, 0} = Native.conversation_sections([[cell], []], 20)
    assert_raise ArgumentError, fn -> Native.conversation_replace(native, 2, []) end
    assert_raise ArgumentError, fn -> Native.conversation_replace(native, 0, [other]) end
    assert_raise ArgumentError, fn -> Native.conversation_sections([[other]], 20) end
  end

  test "interleaved fragments with the same id select only their actual cells" do
    state = %{
      projection([])
      | stream: %Stream{
          timeline: [
            %{kind: :assistant, content: "first", id: "shared"},
            %{kind: :thinking, content: "between", id: "thinking"},
            %{kind: :assistant, content: "last", id: "shared"}
          ]
        }
    }

    model =
      Conversation.new(%Rect{width: 30, height: 12})
      |> Conversation.refresh(Map.put(state, :selected_entry, "shared"))

    widget = Conversation.widget(model)
    assert Enum.map(widget.selected, &Enum.at(model.item_ids, &1)) == ["shared", "shared"]
    assert widget.selected == [0, 4]
    assert Conversation.scroll_to_entry(model, "shared").anchor == %{id: "shared", offset: 0}
  end

  defp projection(messages) do
    %{
      agent_state: %State{messages: messages},
      pending_prompt: nil,
      stream: %Stream{},
      thinking_expanded?: false,
      error: nil
    }
  end
end
