defmodule Tackle.CLI.TUI.ToolViewTest do
  use ExUnit.Case, async: true

  alias ExRatatui.CellSession
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.Line
  alias Tackle.CLI.TUI.{MessageView, ToolView, WorkflowProgress}
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
    assert text =~ "1 replacement"
    details = entry |> MessageView.inspect_items(100) |> text()
    refute details =~ "replacement"
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

    # Consecutive exploring calls collapse into one group whose members keep
    # their distinct stable ids and outputs.
    [group] = entries
    assert group.id == "group:tool:one"

    assert Enum.map(group.tool_group, &{&1.id, &1.tool_output}) == [
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
    preview = text(ToolView.render(entry, 80))
    assert preview =~ "3 replacements · 1 omitted"
    refute preview =~ "third-new"
    assert preview =~ "+1 -1"
    refute preview =~ "local lines"
    assert details =~ "2 - before"
    assert details =~ "2 + after"
    refute details =~ "replacement"
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

  test "wrapped tool output keeps its gutter and bounded headers omit truncation hints" do
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

    assert text(ToolView.render(long, 30)) =~ "long/"
    refute text(ToolView.render(long, 30)) =~ "header clipped"
    refute text(ToolView.render(long, 30)) =~ "F4 details"

    for width <- [1, 4, 8, 30] do
      for {widget, _} <- ToolView.render(long, width), row <- widget.text do
        assert MessageView.display_width(plain(row)) <= width
      end
    end
  end

  test "diff rows paint fills with a number gutter and tint only changed tokens; controls remain data" do
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

    for {row, sign, color, fill, tint, token} <- [
          {3, "-", 174, 52, 88, "41"},
          {4, "+", 114, 22, 28, "42"}
        ] do
      line = Enum.filter(cells, &(&1.row == row))
      marker = Enum.find(line, &(&1.symbol == sign))
      assert marker.fg == {:indexed, color}
      assert marker.bg == {:indexed, fill}
      assert marker.modifiers == []

      emphasized = Enum.filter(line, &(&1.bg == {:indexed, tint}))
      assert Enum.map_join(emphasized, & &1.symbol) == token
      assert Enum.all?(line -- emphasized, &(&1.bg == {:indexed, fill}))
      assert Enum.find(line, &(&1.symbol == "l")).fg == :reset

      # The gutter is one cell wide for single-digit numbers and stays dim on
      # dark backgrounds; the fill reaches every cell of the row.
      gutter = Enum.find(line, &(&1.col == 4))
      assert gutter.symbol == "1"
      assert gutter.fg == {:indexed, 243}
      assert gutter.bg == {:indexed, fill}
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
      assert Enum.sum(Enum.map(items, &elem(&1, 1))) <= 22

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
    assert Enum.find(header, &(&1.symbol == "c")).modifiers == []
    assert Enum.find(header, &(&1.symbol == "c")).fg == {:indexed, 246}
    assert Enum.find(body, &(&1.symbol == "l")).col == 4
    assert Enum.find(body, &(&1.symbol == "l")).fg == {:indexed, 246}
    refute Enum.any?(body, &(&1.symbol in ["▌", "│"]))

    heading = header |> Enum.sort_by(& &1.col) |> Enum.map_join(& &1.symbol)
    assert heading =~ "  bash  cat a.ex"
    refute heading =~ "completed"
  end

  test "file paths retain bold emphasis while long commands stay muted" do
    for {name, args, bold?} <- [
          {"read", %{"path" => "lib/example.ex"}, true},
          {"write", %{"path" => "lib/example.ex"}, true},
          {"bash", %{"command" => String.duplicate("echo hello; ", 30)}, false}
        ] do
      [entry] =
        settled([Message.assistant(tool_calls: [%{id: "call", name: name, arguments: args}])])

      [{widget, _} | _] = ToolView.render(entry, 80)

      target =
        widget.text
        |> hd()
        |> Map.fetch!(:spans)
        |> Enum.find(
          &String.contains?(
            &1.content,
            if(bold?, do: "lib/example", else: if(name == "bash", do: "echo", else: "Enum"))
          )
        )

      assert :bold in target.style.modifiers == bold?
    end
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
    refute preview =~ "output clipped"
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

  test "completed background launch cards still show child activity, not stale activity above findings" do
    entry = %MessageView{
      kind: :tool,
      content: "subagent",
      tool_name: "subagent",
      tool_status: :completed,
      tool_arguments: %{"profile" => "scout", "background" => true},
      tool_output: "Started background subagent run-one.",
      subagent_work: "Reading lib/tackle.ex"
    }

    assert text(ToolView.render(entry, 100)) =~ "Now: Reading lib/tackle.ex"

    foreground = %{entry | tool_arguments: %{"profile" => "scout"}, tool_output: "# Findings"}
    refute text(ToolView.render(foreground, 100)) =~ "Now:"
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

  test "subagent assignments stay bounded but findings render in full at every width" do
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
          String.duplicate("- finding\n", 100) <> "\nFINAL FINDING"
        )
      ])

    for width <- [1, 4, 8, 30, 80] do
      items = ToolView.render(entry, width)
      metadata = ToolView.render(entry, width, :preview, render_result?: false)
      assert Enum.sum(Enum.map(metadata, &elem(&1, 1))) <= 8
      assert Enum.sum(Enum.map(items, &elem(&1, 1))) > 100
      refute text(items) =~ "evil"
      refute text(Enum.drop(items, length(metadata))) =~ "lines hidden"

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

  test "delegated findings share Markdown rendering inline and in details, retaining raw source" do
    answer =
      "# Findings\n\n**Important** and `inline`\n\n- First\n- Second\n\n```elixir\nIO.puts(:ok)\n```\n\nLast finding\e]52;c;evil\a"

    for name <- ["subagent", "subagent_wait", "subagent_status"] do
      args =
        if name == "subagent",
          do: %{"profile" => "scout", "prompt" => "Inspect"},
          else: %{"run_id" => "run-one"}

      output =
        if name == "subagent", do: answer, else: "Subagent run-one completed:\n\n" <> answer

      [entry] =
        settled([
          Message.assistant(tool_calls: [%{id: "findings", name: name, arguments: args}]),
          Message.tool_result("findings", name, output)
        ])

      for items <- [ToolView.render(entry, 80), MessageView.inspect_items(entry, 80)] do
        painted = text(items)
        assert painted =~ "Findings"
        assert painted =~ "Important"
        assert painted =~ "IO.puts(:ok)"
        assert painted =~ "Last finding"
        refute painted =~ "# Findings"
        refute painted =~ "**Important**"
        refute painted =~ "```"
        refute painted =~ "Subagent run-one completed:"
        refute painted =~ "evil"

        assert Enum.any?(items, fn {widget, _} ->
                 Enum.any?(widget.text, fn row ->
                   Enum.any?(
                     row.spans,
                     &(&1.content =~ "Important" and :bold in &1.style.modifiers)
                   )
                 end)
               end)
      end

      assert MessageView.full_text(entry) == output
      assert MessageView.search_text(entry) =~ "Last finding"
    end
  end

  test "background launch and running status are activity, not findings" do
    for {name, args, output} <- [
          {"subagent", %{"profile" => "scout", "background" => true},
           "Started background subagent run-one."},
          {"subagent_status", %{"run_id" => "run-one"}, "Subagent run-one is still running."}
        ] do
      [entry] =
        settled([
          Message.assistant(tool_calls: [%{id: "one", name: name, arguments: args}]),
          Message.tool_result("one", name, output)
        ])

      assert ToolView.markdown_output(entry) == nil
      assert text(ToolView.render(entry, 100)) =~ output
    end
  end

  describe "run_workflow cards" do
    @review_loop """
    -- Review loop
    local findings = tackle.await(tackle.spawn("scout", "Map the code paths."))
    local plan = tackle.await(tackle.spawn("planner", "Plan: " .. findings.text))
    local impl = tackle.await(tackle.spawn("worker", "Implement: " .. plan.text))
    local review = tackle.await(tackle.spawn("reviewer", "Review the change."))
    while not review.ok do
      impl = tackle.await(tackle.spawn("worker", "Fix: " .. review.text))
      review = tackle.await(tackle.spawn("reviewer", "Re-review."))
    end
    local answers = tackle.parallel(items, function(item)
      return "scout", "Check " .. item
    end)
    return review.text
    """

    test "saved workflow cards show the name without claiming a missing script" do
      for status <- [:requested, :running, :completed] do
        entry = workflow_entry(status, %{"workflow" => "review-loop"})
        output = text(ToolView.render(entry, 100))
        assert output =~ "workflow  review-loop"
        assert output =~ "Saved workflow · review-loop"
        refute output =~ "Script unavailable"
        refute output =~ "Lua workflow ·"
      end

      assert ToolView.title("run_workflow", %{"workflow" => "review-loop"}, :running) ==
               "run_workflow  review-loop"
    end

    test "a streamed saved name appears in the header" do
      entry = workflow_entry(:preparing, ~s({"workflow":"review-loop))
      assert text(ToolView.render(entry, 100)) =~ "workflow  review-loop"
    end

    test "malformed and empty saved names do not crash or hide the script" do
      for status <- [:preparing, :running, :completed, :failed], name <- [1, %{}, ""] do
        args = %{"workflow" => name, "script" => "return 1"}
        entry = workflow_entry(status, args)
        output = text(ToolView.render(entry, 100))
        if status in [:preparing, :running], do: assert(output =~ "return 1")
        if status in [:running, :completed], do: assert(output =~ "Lua workflow · 1 line")
        assert text(ToolView.render(entry, 100, :details)) =~ "return 1"
        refute output =~ "Saved workflow"
        assert ToolView.title("run_workflow", args, status) == "run_workflow"
      end

      for args <- [%{"workflow" => 1}, %{"workflow" => %{}}] do
        assert text(ToolView.render(workflow_entry(:running, args), 100)) =~ "workflow"
      end

      raw = ~s({"workflow":"","script":"return 1)
      output = text(ToolView.render(workflow_entry(:preparing, raw), 100))
      assert output =~ "return 1"
      assert output =~ "Script incoming (partial)"
      refute output =~ "Saved workflow"
    end

    test "a running workflow outlines its profiles and previews a bounded script" do
      entry = workflow_entry(:running, %{"script" => @review_loop}, elapsed_ms: 72_000)
      output = text(ToolView.render(entry, 100))

      assert output =~
               "● running  workflow  scout → planner → worker → reviewer · fan-out  1m 12s"

      assert output =~ "Lua workflow · 13 lines"
      assert output =~ ~s(local findings = tackle.await(tackle.spawn("scout")
      assert output =~ "Showing 10 of 13 lines"
      refute output =~ "return review.text"
      refute output =~ ~s("script")

      assert ToolView.title("run_workflow", %{"script" => @review_loop}, :running) ==
               "run_workflow  scout → planner → worker → reviewer · fan-out"
    end

    test "a completed workflow shows its result instead of the script" do
      [entry] =
        settled([
          workflow_call(%{"script" => @review_loop}),
          Message.tool_result("wf", "run_workflow", "Review passed.\nTwo notes remain.")
        ])

      output = text(ToolView.render(%{entry | tool_elapsed_ms: 95_000}, 100))
      assert output =~ "  workflow  scout → planner → worker → reviewer · fan-out  95s"
      assert output =~ "Lua workflow · 13 lines"
      assert output =~ "Review passed.\n    Two notes remain."
      refute output =~ "local findings"
      refute output =~ "completed"
      assert MessageView.full_text(entry) == "Review passed.\nTwo notes remain."
      assert MessageView.search_text(entry) =~ "Re-review."
    end

    test "a failed workflow shows the error and the script line it names" do
      [entry] =
        settled([
          workflow_call(%{"script" => @review_loop}),
          Message.tool_result(
            "wf",
            "run_workflow",
            "Error: the workflow failed at line 6: attempt to index a nil value"
          )
        ])

      output = text(ToolView.render(entry, 100))
      assert output =~ "✗ failed  workflow  scout"
      assert output =~ "the workflow failed at line 6: attempt to index a nil value"
      assert output =~ "6  while not review.ok do"
      refute output =~ "local findings"

      # An error without a line, or naming a line past the end, adds no source row.
      for error <- ["the workflow exceeded its deadline", "the workflow failed at line 99: x"] do
        [failed] =
          settled([
            workflow_call(%{"script" => @review_loop}),
            Message.tool_result("wf", "run_workflow", "Error: " <> error)
          ])

        rows = failed |> ToolView.render(100) |> text() |> String.split("\n")
        assert length(rows) == 2
      end
    end

    test "live progress replaces the script preview with a flow chart" do
      progress =
        Enum.reduce(
          [
            %{kind: :run_started, run_id: "a", profile: "scout", prompt: "Map the code paths."},
            %{kind: :run_finished, run_id: "a", status: :ok, ok: true},
            %{kind: :parallel_started, id: 1, count: 2, limit: 2},
            %{
              kind: :run_started,
              run_id: "b",
              profile: "reviewer",
              prompt: "Check one",
              parallel: %{id: 1, index: 1}
            }
          ],
          WorkflowProgress.new(),
          &WorkflowProgress.apply(&2, &1, 0)
        )

      entry =
        workflow_entry(:running, %{"script" => @review_loop},
          elapsed_ms: 4_000,
          workflow: progress
        )

      output = text(ToolView.render(entry, 100))
      assert output =~ "● running  workflow  scout → planner → worker → reviewer · fan-out  4s"
      assert output =~ "    ✓ scout  0s  Map the code paths.\n    │\n    ┬ parallel  0/2 done"
      assert output =~ "    ├ ● reviewer  0s  Check one\n    └ ○ 1 queued"
      refute output =~ "local findings"

      # Narrow terminals clip each node instead of wrapping the chart.
      narrow = entry |> ToolView.render(24) |> text() |> String.split("\n")
      assert Enum.all?(narrow, &(MessageView.display_width(&1) <= 24))
      assert Enum.any?(narrow, &(&1 =~ "┬ parallel"))

      failed =
        workflow_entry(:failed, %{"script" => @review_loop},
          error: "Error: the workflow failed at line 6: boom",
          workflow: WorkflowProgress.settle(progress, 0)
        )

      output = text(ToolView.render(failed, 100))
      assert output =~ "✓ scout → ◌ reviewer"
      assert output =~ "6  while not review.ok do"

      details = text(MessageView.inspect_items(entry, 100))
      assert details =~ "Progress\n    ✓ scout"
      assert details =~ " 1  -- Review loop"

      saved = %{entry | tool_arguments: %{"workflow" => "review-loop"}}
      saved_output = text(ToolView.render(saved, 100))
      assert saved_output =~ "workflow  review-loop"
      assert saved_output =~ "┬ parallel  0/2 done"
      refute saved_output =~ "Script unavailable"
      assert text(MessageView.inspect_items(saved, 100)) =~ "Progress\n    ✓ scout"
    end

    test "details number every script line and keep the result" do
      [entry] =
        settled([
          workflow_call(%{"script" => @review_loop}),
          Message.tool_result("wf", "run_workflow", "final answer")
        ])

      details = text(MessageView.inspect_items(entry, 120))
      assert details =~ " 1  -- Review loop"
      assert details =~ "13  return review.text"
      refute details =~ "14  "
      assert details =~ "Result\n    final answer"
    end

    test "streamed input previews the partial script without the JSON envelope" do
      raw = ~S|{"script":"local a = tackle.spawn(\"scout\", \"x\")\nlocal b = tack|
      entry = workflow_entry(:preparing, raw)
      output = text(ToolView.render(entry, 100))

      assert output =~ "◐ preparing  workflow  scout"
      assert output =~ "Script incoming (partial)"
      assert output =~ "local b = tack"
      refute output =~ ~s({"script")

      empty = text(ToolView.render(workflow_entry(:preparing, ~S|{"scr|), 100))
      assert empty =~ "preparing  workflow"
      assert empty =~ "Script incoming"
    end

    test "previews stay within the card width and never paint control sequences" do
      script =
        ~s(local r = tackle.spawn("scout\e]52;c;evil\a", ") <>
          String.duplicate("界 trace ", 300) <> ~s("\)\nreturn r)

      entry = workflow_entry(:running, %{"script" => script})

      for width <- [1, 4, 8, 30, 80] do
        items = ToolView.render(entry, width)
        refute text(items) =~ "evil"

        for {widget, _} <- items, row <- widget.text do
          assert MessageView.display_width(plain(row)) <= width
        end
      end

      missing = text(ToolView.render(workflow_entry(:running, %{}), 80))
      assert missing =~ "running  workflow"
      assert missing =~ "Script unavailable"
    end
  end

  test "a fourteen-line insertion stays complete and metadata does not spend code rows" do
    new = Enum.map_join(1..14, "\n", &"added #{&1}")
    entry = file_entry("edit", %{path: "a.ex", edits: [%{oldText: "old", newText: new}]})
    preview = text(ToolView.render(entry, 80))

    assert preview =~ "+14 -1"
    assert preview =~ "1 - old"
    for index <- 1..14, do: assert(preview =~ "#{index} + added #{index}")
    refute preview =~ "Showing"
    refute preview =~ "hidden"
  end

  test "writes have sixteen code rows, an honest line summary, and contiguous content" do
    content = Enum.map_join(1..84, "\n", &"source #{&1}")
    entry = file_entry("write", %{path: "a.ex", content: content})
    preview = text(ToolView.render(entry, 80))

    for index <- 1..16, do: assert(preview =~ "    source #{index}\n")
    assert preview =~ "Showing 16 of 84 lines"
    refute preview =~ "source 17"
    refute preview =~ "source 84"
    assert text(MessageView.inspect_items(entry, 80)) =~ "source 84"

    # Wrapping, not source-line count, spends the budget. No half second line.
    wrapped = file_entry("write", %{path: "a", content: "abcdefghijkl\nsecond"})
    preview = text(ToolView.render(wrapped, 12, :preview, code_rows: 2))
    assert preview =~ "    abcdefgh\n    ijkl"
    refute preview =~ "second"

    assert Enum.sum(Enum.map(ToolView.render(wrapped, 12, :preview, code_rows: 2), &elem(&1, 1))) ==
             6
  end

  test "complete small hunks are preferred to fragments of a larger hunk" do
    old = Enum.map_join(1..12, "\n", &"old #{&1}") <> "\nc1\nc2\nc3\nc4\nc5\nsmall old"
    new = String.replace(old, ~r/old \d+/, "big new") |> String.replace("small old", "small new")
    entry = file_entry("edit", %{path: "a", edits: [%{oldText: old, newText: new}]})
    preview = text(ToolView.render(entry, 80, :preview, code_rows: 4))

    assert preview =~ "small old"
    assert preview =~ "small new"
    refute preview =~ "big new"
    assert preview =~ "intervening lines omitted"
    assert preview =~ "Showing 3 of 31 lines"
  end

  test "oversized lines stay bounded and say that the visible line is partial" do
    entry = file_entry("write", %{path: "safe", content: String.duplicate("界", 20_000)})

    for width <- [1, 4, 8, 30, 80] do
      items = ToolView.render(entry, width, :preview, code_rows: 3)
      assert Enum.sum(Enum.map(items, &elem(&1, 1))) <= 7

      for {widget, _} <- items, row <- widget.text do
        # At one column a wide glyph itself cannot fit; wrapping follows the
        # existing MessageView behavior rather than splitting the grapheme.
        assert MessageView.display_width(plain(row)) <= max(width, 2)
      end
    end

    assert text(ToolView.render(entry, 80, :preview, code_rows: 3)) =~ "line continues in details"
    assert MessageView.search_text(entry) =~ String.duplicate("界", 20_000)
  end

  test "zero-width prefixes and wide graphemes cannot exceed the visual code budget" do
    for content <- ["\u200B界", "\u0301界", "界界界", "🙂ab🙂"] do
      entry = file_entry("write", %{path: "a", content: content})
      items = ToolView.render(entry, 1, :preview, code_rows: 1)
      assert Enum.sum(Enum.map(items, &elem(&1, 1))) == 5
    end
  end

  test "oversized before/after previews and long-line batches retain bounded paint" do
    old = String.duplicate("old\n", 2_000)
    new = String.duplicate(String.duplicate("x", 1_000) <> "\n", 2_000)
    entry = file_entry("edit", %{path: "a", edits: [%{oldText: old, newText: new}]})
    items = ToolView.render(entry, 80, :preview, code_rows: 4)
    assert Enum.sum(Enum.map(items, &elem(&1, 1))) <= 12
    assert byte_size(text(items)) < 2_000
    assert text(items) =~ "+2001 -2001"
    assert text(items) =~ "Showing"
  end

  test "incoming content uses the file budget and failed writes keep compact diagnostics" do
    [incoming] =
      MessageView.section_entries(
        %{
          tool_activity: [
            %{
              id: "w",
              name: "write",
              status: :preparing,
              arguments: "{\"path\":\"a\",\"content\":\"one\\ntwo\\nthree\\nfour"
            }
          ]
        },
        :tools
      )

    preview = text(ToolView.render(incoming, 80, :preview, code_rows: 3))
    assert preview =~ "Content incoming (partial)"
    assert preview =~ "three"
    refute preview =~ "four"
    assert preview =~ "Showing 3 of 4 lines"

    failed = %{
      file_entry("write", %{path: "a", content: "submitted"})
      | tool_status: :failed,
        tool_output: "Error: permission denied"
    }

    preview = text(ToolView.render(failed, 80))
    assert preview =~ "Error: permission denied"
    refute preview =~ "submitted"
  end

  defp file_entry(name, args) do
    [entry] = settled([Message.assistant(tool_calls: [%{id: name, name: name, arguments: args}])])
    entry
  end

  defp workflow_call(args),
    do: Message.assistant(tool_calls: [%{id: "wf", name: "run_workflow", arguments: args}])

  defp workflow_entry(status, arguments, extra \\ []) do
    tool =
      Map.merge(
        %{id: "wf", name: "run_workflow", status: status, arguments: arguments},
        Map.new(extra)
      )

    [entry] = MessageView.section_entries(%{tool_activity: [tool]}, :tools)
    entry
  end

  describe "command watchdog" do
    test "a running bash call the watchdog tracks shows the watched marker" do
      watched = live_tool(%{"command" => "while true; do echo tick; sleep 1; done"}, true)
      assert watched.tool_watched?
      assert text(ToolView.render(watched, 100)) =~ "◉ running  bash  while true"

      unwatched = live_tool(%{"command" => "make"}, false)
      refute unwatched.tool_watched?
      assert text(ToolView.render(unwatched, 100)) =~ "● running  bash  make"

      # An explicit timeout means the watchdog leaves the call alone.
      timed = live_tool(%{"command" => "make", "timeout" => 30}, true)
      refute timed.tool_watched?
      assert text(ToolView.render(timed, 100)) =~ "● running  bash  make"
    end

    test "a call the watchdog stopped shows the stopped marker, also from history" do
      message =
        "Error: tick\ntick\nCommand stopped by watchdog after 13s: likely infinite loop " <>
          "(p=0.93). If this is expected to run long, re-run it with an explicit timeout " <>
          "or in the background."

      [stopped] =
        settled([
          Message.assistant(
            tool_calls: [%{id: "w", name: "bash", arguments: %{"command" => "yes"}}]
          ),
          Message.tool_result("w", "bash", message)
        ])

      assert stopped.tool_status == :failed
      output = text(ToolView.render(stopped, 100))
      assert output =~ "⊘ stopped  bash  yes"
      refute output =~ "failed"

      [failed] =
        settled([
          Message.assistant(
            tool_calls: [%{id: "f", name: "bash", arguments: %{"command" => "false"}}]
          ),
          Message.tool_result("f", "bash", "Error: Command exited with code 1")
        ])

      assert text(ToolView.render(failed, 100)) =~ "✗ failed  bash  false"
    end
  end

  defp live_tool(arguments, watchdog?) do
    tool = %{kind: :tool, id: "live", name: "bash", arguments: arguments, status: :running}

    [entry] =
      MessageView.section_entries(
        %{
          stream: %{timeline: [tool]},
          thinking_expanded?: false,
          compactions: [],
          watchdog?: watchdog?
        },
        :turn
      )

    entry
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
