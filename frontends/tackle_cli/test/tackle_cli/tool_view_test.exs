defmodule Tackle.CLI.TUI.ToolViewTest do
  use ExUnit.Case, async: true

  alias ExRatatui.CellSession
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.Line
  alias Tackle.CLI.TUI.{MessageView, ToolView}
  alias Tackle.Lib.{Message, State}

  test "call and result form one card, preserving arguments and full output" do
    args = %{"path" => "lib/parser.ex", "edits" => [%{"oldText" => "old", "newText" => "new"}]}

    [entry] =
      settled([
        Message.assistant(tool_calls: [%{id: "edit-1", name: "edit", arguments: args}]),
        Message.tool_result("edit-1", "edit", "Successfully replaced 1 block(s).")
      ])

    assert entry.id == "tool:edit-1"
    assert entry.tool_arguments == args
    assert entry.tool_status == :completed
    assert MessageView.full_text(entry) == "Successfully replaced 1 block(s)."
    assert MessageView.search_text(entry) =~ "oldText"

    text = entry |> ToolView.render(80) |> text()
    assert text =~ "✓ edit  lib/parser.ex"
    assert text =~ "completed"
    assert text =~ "Replacement preview"
    assert entry |> MessageView.inspect_items(100) |> text() =~ "not a verified file diff"
    assert text =~ "1 │ -  old"
    assert text =~ "1 │ +  new"
    refute text =~ "oldText"
    refute text =~ "Successfully replaced"
  end

  test "requested and failed edits never claim an applied diff" do
    call = %{
      id: "e",
      name: "edit",
      arguments: %{"path" => "a", "edits" => [%{"oldText" => "a", "newText" => "b"}]}
    }

    [pending] = settled([Message.assistant(tool_calls: [call])])
    assert pending.tool_status == :requested
    assert text(ToolView.render(pending, 80)) =~ "requested"
    refute text(ToolView.render(pending, 80)) =~ "✓"

    [failed] =
      settled([
        Message.assistant(tool_calls: [call]),
        Message.tool_result("e", "edit", "Error: Could not find oldText")
      ])

    assert failed.tool_status == :failed
    output = text(ToolView.render(failed, 80))
    assert output =~ "failed"
    assert output =~ "Error: Could not find oldText"
    refute output =~ "applied"
    refute output =~ "✓"
  end

  test "multiple calls of the same tool keep distinct stable live and settled ids" do
    live = %{
      tool_activity: [
        %{id: "one", name: "read", arguments: %{"path" => "one"}, status: :running},
        %{id: "two", name: "read", arguments: %{"path" => "two"}, status: :running}
      ]
    }

    assert Enum.map(MessageView.section_entries(live, :tools), & &1.id) == [
             "tool:one",
             "tool:two"
           ]

    entries =
      settled([
        Message.assistant(
          tool_calls: [
            %{id: "one", name: "read", arguments: %{"path" => "one"}},
            %{id: "two", name: "read", arguments: %{"path" => "two"}}
          ]
        ),
        Message.tool_result("two", "read", "two result"),
        Message.tool_result("one", "read", "one result")
      ])

    assert Enum.map(entries, &{&1.id, &1.tool_output}) == [
             {"tool:one", "one result"},
             {"tool:two", "two result"}
           ]
  end

  test "unmatched tool results remain visible and unknown tools have a fallback" do
    [entry] = settled([Message.tool_result("external", "custom", "plugin result")])
    assert text(ToolView.render(entry, 80)) =~ "plugin result"

    [pending] =
      settled([
        Message.assistant(
          tool_calls: [
            %{id: "custom", name: "custom", arguments: %{"query" => "hello"}}
          ]
        )
      ])

    assert text(ToolView.render(pending, 80)) =~ "hello"
    assert text(MessageView.inspect_items(pending, 80)) =~ "Arguments:"
  end

  test "replacement numbers are local, context unchanged, full details retain every hunk" do
    args = %{
      "path" => "parser.ex",
      "edits" => [
        %{"oldText" => "context\nbefore\nend", "newText" => "context\nafter\nend"},
        %{"oldText" => "second-old", "newText" => "second-new"},
        %{"oldText" => "third-old", "newText" => "third-new"}
      ]
    }

    [entry] =
      settled([Message.assistant(tool_calls: [%{id: "edit", name: "edit", arguments: args}])])

    details = text(MessageView.inspect_items(entry, 80))
    assert details =~ "+1 -1 · relative lines"
    assert details =~ "2 │ -  before"
    assert details =~ "2 │ +  after"
    assert details =~ "replacement 3"
    assert details =~ "third-new"
  end

  test "write previews never pretend an overwrite is a new-file diff" do
    [entry] =
      settled([
        Message.assistant(
          tool_calls: [
            %{
              id: "write",
              name: "write",
              arguments: %{"path" => "file.ex", "content" => "hello\nworld"}
            }
          ]
        )
      ])

    output = text(ToolView.render(entry, 80))
    assert output =~ "prior file not compared"
    assert output =~ "hello"
    refute output =~ "new file"
  end

  test "inline payload stays bounded after wrapping; inspector and copy retain the tail" do
    output = String.duplicate("x", 20_000) <> "\nLAST DIAGNOSTIC"
    [entry] = settled([Message.tool_result("large", "bash", output)])

    for width <- [1, 8, 40, 80, 120] do
      items = ToolView.render(entry, width)
      assert Enum.sum(Enum.map(items, &elem(&1, 1))) <= 8
      assert byte_size(text(items)) < 2000
      terminal = ExRatatui.init_test_terminal(width, 12)
      widget = %ExRatatui.Widgets.WidgetList{items: items}
      assert :ok = ExRatatui.draw(terminal, [{widget, %Rect{width: width, height: 12}}])
    end

    assert MessageView.full_text(entry) == output
    assert text(MessageView.inspect_items(entry, 80)) =~ "LAST DIAGNOSTIC"
  end

  test "diff markers have actual native red/green cells and controls remain data" do
    [entry] =
      settled([
        Message.assistant(
          tool_calls: [
            %{
              id: "e",
              name: "edit",
              arguments: %{
                "path" => "safe\e]52;c;evil\a.ex",
                "edits" => [
                  %{"oldText" => "before", "newText" => "after"}
                ]
              }
            }
          ]
        )
      ])

    items = ToolView.render(entry, 100)
    refute text(items) =~ "evil"
    assert entry.tool_arguments["path"] =~ "evil"
    session = CellSession.new(100, 12)

    assert :ok =
             CellSession.draw(session, [
               {%ExRatatui.Widgets.WidgetList{items: items}, %Rect{width: 100, height: 12}}
             ])

    %{cells: cells} = CellSession.take_cells(session)
    assert Enum.any?(cells, &(&1.symbol == "-" and &1.fg == :red))
    assert Enum.any?(cells, &(&1.symbol == "+" and &1.fg == :green))
    assert Enum.any?(cells, &(&1.bg == {:indexed, 52}))
    assert Enum.any?(cells, &(&1.bg == {:indexed, 22}))
  end

  test "tool cards paint a raised header band, a surface body band, and a status rail" do
    [entry] =
      settled([
        Message.assistant(tool_calls: [%{id: "r", name: "read", arguments: %{"path" => "a.ex"}}]),
        Message.tool_result("r", "read", "line one")
      ])

    items = ToolView.render(entry, 40)
    session = CellSession.new(40, 12)

    assert :ok =
             CellSession.draw(session, [
               {%ExRatatui.Widgets.WidgetList{items: items}, %Rect{width: 40, height: 12}}
             ])

    %{cells: cells} = CellSession.take_cells(session)
    header = Enum.filter(cells, &(&1.row == 0))
    body = Enum.filter(cells, &(&1.row == 1))

    assert Enum.all?(header, &(&1.bg == {:indexed, 237}))
    assert Enum.all?(body, &(&1.bg == {:indexed, 235}))
    assert Enum.any?(body, &(&1.symbol == "▌"))

    right = header |> Enum.sort_by(& &1.col) |> Enum.map_join(& &1.symbol)
    assert right =~ "completed"
  end

  defp settled(messages),
    do:
      MessageView.section_entries(
        %{agent_state: %State{messages: messages}, thinking_expanded?: false},
        :settled
      )

  defp text(items) do
    Enum.map_join(items, "\n", fn {widget, _height} -> widget |> Map.fetch!(:text) |> plain() end)
  end

  defp plain(text) when is_binary(text), do: text
  defp plain(%Line{spans: spans}), do: Enum.map_join(spans, "", & &1.content)
  defp plain(lines) when is_list(lines), do: Enum.map_join(lines, "\n", &plain/1)
end
