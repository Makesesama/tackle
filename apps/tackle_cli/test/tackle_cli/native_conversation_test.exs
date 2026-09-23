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
    assert Enum.take(rows, 4) == ["›   **raw ", "  **      ", "  next    ", "          "]
    assert Enum.any?(rows, &String.starts_with?(&1, "● answer"))
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

      assert painted =~ "● IO.puts(\"hello\")"
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

  test "Elixir code keeps indentation and wraps with the message gutter" do
    source = "before\n\n```ex\n    IO.puts(\"hello\")\n```\n\nafter"
    cells = Widget.cell(%MessageView{kind: :assistant, content: source}, 12)
    {scene, height} = Widget.assemble(cells, 12)

    {:ok, rows} =
      Native.conversation_render(scene, 12, height, 0, [], Widget.style(%ExRatatui.Style{}))

    painted = Enum.map(rows, fn row -> Enum.map_join(row, &elem(&1, 0)) end)

    assert length(cells) == 3
    assert Enum.any?(painted, &String.starts_with?(&1, "      IO.pu"))
    assert Enum.any?(painted, &String.starts_with?(&1, "  after"))
    assert Enum.all?(tl(painted), &String.starts_with?(&1, "  "))
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
