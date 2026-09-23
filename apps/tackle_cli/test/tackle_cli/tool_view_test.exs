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
    assert text =~ "  edit  lib/parser.ex"
    refute text =~ "completed"
    refute text =~ "Replacement preview"
    details = entry |> MessageView.inspect_items(100) |> text()
    refute details =~ "Replacement preview"
    assert details =~ "Submitted text (not a verified file diff)"
    assert text =~ "1 - old"
    refute text =~ "@@"
    refute text =~ "│"
    assert text =~ "1 + new"
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
    refute output =~ "Replacement"
    refute output =~ "1 - a"
    refute output =~ "1 + b"

    details = text(MessageView.inspect_items(failed, 100))
    assert details =~ "Error: Could not find oldText"
    assert details =~ "oldText"
    refute details =~ "Replacement preview"
    assert MessageView.search_text(failed) =~ "newText"
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
    assert details =~ "+1 -1"
    refute details =~ "relative lines"
    refute text(ToolView.render(entry, 80)) =~ "local lines"
    assert details =~ "2 - before"
    assert details =~ "2 + after"
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

  test "wrapped tool output keeps its gutter and bounded headers signal truncation" do
    [entry] = settled([Message.tool_result("r", "custom", "abcdefghijklmnop")])
    rows = ToolView.render(entry, 12) |> Enum.flat_map(fn {widget, _} -> widget.text end)
    assert Enum.map(tl(rows), &plain/1) == ["    abcdefgh", "    ijklmnop"]

    [long] =
      settled([
        Message.assistant(
          tool_calls: [
            %{id: "r", name: "read", arguments: %{"path" => String.duplicate("long/", 20)}}
          ]
        )
      ])

    assert text(ToolView.render(long, 30)) =~ "header clipped"
    refute text(ToolView.render(long, 30)) =~ "F4 details"

    for width <- [1, 4, 8, 30] do
      for {widget, _} <- ToolView.render(long, width), row <- widget.text do
        assert MessageView.display_width(plain(row)) <= width
      end
    end
  end

  test "diffs keep neutral rows and tint only changed tokens; controls remain data" do
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
                  %{"oldText" => "let total = 41", "newText" => "let total = 42"}
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

    for {row, sign, color, tint, token} <- [
          {2, "-", 174, 52, "41"},
          {3, "+", 114, 22, "42"}
        ] do
      line = Enum.filter(cells, &(&1.row == row))
      marker = Enum.find(line, &(&1.symbol == sign))
      assert marker.fg == {:indexed, color}
      assert marker.bg == :reset
      assert marker.modifiers == []

      emphasized = Enum.filter(line, &(&1.bg == {:indexed, tint}))
      assert Enum.map_join(emphasized, & &1.symbol) == token
      assert Enum.all?(line -- emphasized, &(&1.bg == :reset))
      assert Enum.find(line, &(&1.symbol == "l")).fg == :reset
      assert Enum.find(line, &(&1.col == 4)).fg == {:indexed, 243}
    end
  end

  test "minimal diff previews stay bounded on narrow terminals and retain full details" do
    old = "context\nlet total = 41\n" <> String.duplicate("tail ", 40)
    new = String.replace(old, "41", "42")

    [entry] =
      settled([
        Message.assistant(
          tool_calls: [
            %{
              id: "e",
              name: "edit",
              arguments: %{"path" => "a.ex", "edits" => [%{"oldText" => old, "newText" => new}]}
            }
          ]
        )
      ])

    for width <- [1, 4, 8, 30, 80] do
      items = ToolView.render(entry, width)
      assert Enum.sum(Enum.map(items, &elem(&1, 1))) <= 8

      for {widget, _} <- items, row <- widget.text do
        assert MessageView.display_width(plain(row)) <= width
      end
    end

    details = MessageView.inspect_items(entry, 240)
    assert text(details) =~ String.duplicate("tail ", 40)
    context = for {widget, _} <- details, row <- widget.text, plain(row) =~ "context", do: row
    assert [row] = context
    assert row.style.bg == nil
    assert Enum.all?(row.spans, &is_nil(&1.style.bg))
  end

  test "tool cards use a borderless tool-first header and indented muted output" do
    [entry] =
      settled([
        Message.assistant(
          tool_calls: [%{id: "r", name: "bash", arguments: %{"command" => "cat a.ex"}}]
        ),
        Message.tool_result("r", "bash", "line one")
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

    assert Enum.all?(header ++ body, &(&1.bg == :reset))
    assert Enum.find(header, &(&1.symbol == "c")).modifiers == [:bold]
    assert Enum.find(body, &(&1.symbol == "l")).col == 4
    assert Enum.find(body, &(&1.symbol == "l")).fg == {:indexed, 246}
    refute Enum.any?(body, &(&1.symbol in ["▌", "│"]))

    heading = header |> Enum.sort_by(& &1.col) |> Enum.map_join(& &1.symbol)
    assert heading =~ "  bash  cat a.ex"
    refute heading =~ "completed"
  end

  test "successful reads collapse to a header without losing source or arguments" do
    output = "first line\n" <> String.duplicate("source\n", 100) <> "last line"
    args = %{"path" => "lib/example.ex", "offset" => 20, "limit" => 100}

    [entry] =
      settled([
        Message.assistant(tool_calls: [%{id: "r", name: "read", arguments: args}]),
        Message.tool_result("r", "read", output)
      ])

    assert text(ToolView.render(entry, 80)) == "  read  lib/example.ex"
    assert MessageView.full_text(entry) == output
    assert MessageView.search_text(entry) =~ "last line"
    details = text(MessageView.inspect_items(entry, 100))
    assert details =~ "first line"
    assert details =~ "last line"
    assert details =~ "\"offset\":20"

    [failed] = settled([Message.tool_result("r", "read", "Error: permission denied")])
    assert text(ToolView.render(failed, 80)) =~ "Error: permission denied"
  end

  test "bash keeps two tail lines, clips wide output and preserves complete details" do
    output = "build started\n\n" <> String.duplicate("界", 100) <> "\n42 tests passed\n"
    [entry] = settled([Message.tool_result("b", "bash", output)])

    for width <- [1, 4, 8, 30, 80] do
      items = ToolView.render(entry, width)
      assert Enum.sum(Enum.map(items, &elem(&1, 1))) <= 5

      for {widget, _} <- items, row <- widget.text do
        assert MessageView.display_width(plain(row)) <= width
      end
    end

    preview = text(ToolView.render(entry, 80))
    assert preview =~ "42 tests passed"
    assert preview =~ "…"
    refute preview =~ "F4 details"
    refute preview =~ "build started"
    refute preview =~ "lines hidden"
    assert MessageView.full_text(entry) == output
    assert text(MessageView.inspect_items(entry, 80)) =~ "build started"

    [empty] = settled([Message.tool_result("b", "bash", "\n\n")])
    assert text(ToolView.render(empty, 80)) == "  bash"
  end

  test "subagents show profile, assignment, explicit outcomes and retained findings" do
    args = %{
      "profile" => "scout",
      "prompt" => "Trace recovery\nand cite files",
      "timeout_ms" => 5_000
    }

    call = Message.assistant(tool_calls: [%{id: "explore", name: "subagent", arguments: args}])
    [requested] = settled([call])
    assert text(ToolView.render(requested, 80)) =~ "requested  subagent  scout"
    assert text(ToolView.render(requested, 80)) =~ "Task: Trace recovery and cite files"
    refute text(ToolView.render(requested, 80)) =~ "timeout_ms"

    [completed] =
      settled([call, Message.tool_result("explore", "subagent", "lib/recovery.ex:42: findings")])

    assert completed.id == requested.id
    assert text(ToolView.render(completed, 80)) =~ "  subagent  scout"
    assert text(ToolView.render(completed, 80)) =~ "lib/recovery.ex:42"
    assert MessageView.search_text(completed) =~ "Trace recovery"
    assert MessageView.full_text(completed) == "lib/recovery.ex:42: findings"
    assert text(MessageView.inspect_items(completed, 100)) =~ "timeout_ms"
    assert text(MessageView.inspect_items(completed, 100)) =~ "cite files"
    assert completed.tool_elapsed_ms == nil

    for reason <- [
          "subagent timed out",
          "subagent was cancelled",
          "unknown subagent profile: missing"
        ] do
      [failed] = settled([call, Message.tool_result("explore", "subagent", "Error: " <> reason)])
      output = text(ToolView.render(failed, 100))
      assert output =~ "failed  subagent  scout"
      assert output =~ reason
      refute output =~ "✓"
    end
  end

  test "live subagent work is visible inline and retained in details" do
    [entry] =
      MessageView.section_entries(
        %{
          tool_activity: [
            %{
              id: "explore",
              name: "subagent",
              status: :running,
              arguments: %{profile: "scout", prompt: "Inspect files"},
              subagent_work: "Reading lib/tackle.ex",
              subagent_output: "opened config\nreading source"
            }
          ]
        },
        :tools
      )

    assert text(ToolView.render(entry, 100)) =~ "Now: Reading lib/tackle.ex"
    assert text(MessageView.inspect_items(entry, 100)) =~ "opened config"
    assert MessageView.full_text(entry) == "opened config\nreading source"
    assert MessageView.search_text(entry) =~ "reading source"
  end

  test "live subagent elapsed time renders without inventing historical durations" do
    [entry] =
      MessageView.section_entries(
        %{
          tool_activity: [
            %{
              id: "explore",
              name: "subagent",
              status: :running,
              arguments: %{profile: "scout", prompt: "Inspect files"},
              model: "openai-codex/gpt-5.5",
              elapsed_ms: 65_900
            }
          ]
        },
        :tools
      )

    assert entry.tool_elapsed_ms == 65_900

    assert text(ToolView.render(entry, 100)) =~
             "running  subagent  scout  openai-codex/gpt-5.5  1m 5s"

    assert text(ToolView.render(%{entry | tool_elapsed_ms: 999}, 100)) =~
             "openai-codex/gpt-5.5  0s"

    assert text(ToolView.render(%{entry | tool_elapsed_ms: nil}, 100)) =~
             "subagent  scout  openai-codex/gpt-5.5\n"

    assert text(ToolView.render(%{entry | tool_status: :completed, tool_elapsed_ms: 65_900}, 100)) =~
             "scout  openai-codex/gpt-5.5  65s"

    refute text(ToolView.render(%{entry | tool_status: :completed, tool_elapsed_ms: 65_900}, 100)) =~
             "completed"
  end

  test "subagent previews are bounded, sanitized, and retain full assignments in details" do
    args = %{
      "profile" => "scout\e]52;c;evil\a",
      "prompt" => String.duplicate("界 trace ", 500) <> "FINAL TASK"
    }

    [entry] =
      settled([
        Message.assistant(tool_calls: [%{id: "explore", name: "subagent", arguments: args}]),
        Message.tool_result(
          "explore",
          "subagent",
          String.duplicate("finding\n", 100) <> "FINAL FINDING"
        )
      ])

    for width <- [1, 4, 8, 30, 80] do
      items = ToolView.render(entry, width)
      assert Enum.sum(Enum.map(items, &elem(&1, 1))) <= 8
      refute text(items) =~ "evil"

      for {widget, _} <- items, row <- widget.text do
        assert MessageView.display_width(plain(row)) <= width
      end
    end

    assert text(MessageView.inspect_items(entry, 100)) =~ "FINAL TASK"
    assert MessageView.search_text(entry) =~ "FINAL TASK"
    assert MessageView.full_text(entry) =~ "FINAL FINDING"
    assert entry.tool_arguments == args

    [missing] = settled([Message.tool_result("orphan", "subagent", "retained findings")])
    assert text(ToolView.render(missing, 100)) =~ "unknown profile"
    assert text(ToolView.render(missing, 100)) =~ "Task unavailable"
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
