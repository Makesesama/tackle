defmodule Tackle.CLI.WorkflowProgressTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.{WorkflowProgress, WorkflowView}
  alias Tackle.Lib.Event

  defp apply_all(events, now \\ 0) do
    Enum.reduce(events, WorkflowProgress.new(), &WorkflowProgress.apply(&2, &1, now))
  end

  defp started(id, profile, prompt, parallel \\ nil),
    do: %{kind: :run_started, run_id: id, profile: profile, prompt: prompt, parallel: parallel}

  defp finished(id, ok? \\ true, status \\ :ok),
    do: %{kind: :run_finished, run_id: id, profile: nil, status: status, ok: ok?}

  defp child(id, event), do: %{kind: :run_event, run_id: id, profile: "scout", event: event}

  defp text(rows), do: Enum.map(rows, fn row -> Enum.map_join(row.spans, & &1.content) end)

  describe "projection" do
    test "sequential runs become one stage each with outcomes and profiles kept" do
      model =
        apply_all([
          started("a", "scout", "map"),
          finished("a"),
          started("b", "worker", "fix"),
          finished("b", false, :timeout)
        ])

      assert [%{kind: :runs, runs: ["a"]}, %{kind: :runs, runs: ["b"]}] = model.stages
      assert %{status: :completed, profile: "scout"} = model.runs["a"]
      assert %{status: :failed, outcome: :timeout, profile: "worker"} = model.runs["b"]
    end

    test "overlapping standalone runs share a concurrent stage" do
      model = apply_all([started("a", "r", "x"), started("b", "r", "y")])
      assert [%{kind: :runs, runs: ["a", "b"]}] = model.stages
    end

    test "child events before the start create the run, which is placed once on start" do
      model =
        apply_all([
          child("a", Event.new(:tool_start, %{name: "read", arguments: %{"path" => "lib/x.ex"}})),
          started("a", "scout", "map")
        ])

      assert [%{kind: :runs, runs: ["a"]}] = model.stages
      assert %{profile: "scout", prompt: "map", now: "read lib/x.ex"} = model.runs["a"]
    end

    test "repeated child deltas leave the model identical so the frontend can skip a redraw" do
      model = apply_all([started("a", "scout", "map"), child("a", Event.new(:message_delta))])
      again = WorkflowProgress.apply(model, child("a", Event.new(:message_delta)), 0)

      assert model.runs["a"].now == "responding"
      assert again === model
    end

    test "a parallel batch is one stage holding every item in place" do
      model =
        apply_all([
          %{kind: :parallel_started, id: 7, count: 3, limit: 2},
          started("a", "rev", "one", %{id: 7, index: 1}),
          %{
            kind: :item_failed,
            parallel: %{id: 7, index: 2},
            status: "spawn_error",
            text: "no"
          },
          started("c", "rev", "three", %{id: 7, index: 3}),
          %{kind: :parallel_finished, id: 7}
        ])

      assert [%{kind: :parallel, id: 7, count: 3, limit: 2, items: items}] = model.stages
      assert items == %{1 => {:run, "a"}, 2 => {:failed, "spawn_error", "no"}, 3 => {:run, "c"}}
    end

    test "a batch item whose start was not seen still gets a stage" do
      model = apply_all([started("a", "rev", "one", %{id: 9, index: 2})])
      assert [%{kind: :parallel, id: 9, count: nil, items: %{2 => {:run, "a"}}}] = model.stages
      assert [_ | _] = WorkflowView.rows(model, 60, :preview)
    end

    test "settling ends unawaited runs and ignores late events" do
      model = apply_all([started("a", "scout", "map"), started("b", "w", "x"), finished("b")])
      settled = WorkflowProgress.settle(model, 5_000)

      assert %{status: :ended, elapsed_ms: 5_000} = settled.runs["a"]
      assert %{status: :completed} = settled.runs["b"]
      assert WorkflowProgress.apply(settled, started("c", "late", "x"), 6_000) === settled
      assert WorkflowProgress.apply(settled, finished("a"), 6_000) === settled
    end

    test "clocks advance in whole seconds and stop when a run finishes" do
      model = apply_all([started("a", "scout", "map")], 0)
      assert WorkflowProgress.refresh(model, 999) === model
      assert WorkflowProgress.refresh(model, 2_500).runs["a"].elapsed_ms == 2_000

      done = WorkflowProgress.apply(model, finished("a"), 3_200)
      assert done.runs["a"].elapsed_ms == 3_000
      assert WorkflowProgress.refresh(done, 9_000) === done
    end

    test "narration replaces the activity of a running run until it expires" do
      read = Event.new(:tool_start, %{name: "read", arguments: %{"path" => "a.ex"}})
      model = apply_all([started("a", "scout", "map"), child("a", read)], 0)

      narrated = WorkflowProgress.narrate(model, "a", "mapping the session code", 1_000)
      assert narrated.runs["a"].narration == "mapping the session code"
      assert narrated.runs["a"].now == "read a.ex"

      # The same line only renews its age.
      renewed = WorkflowProgress.narrate(narrated, "a", "mapping the session code", 2_000)
      assert renewed.runs["a"].narrated_at_ms == 2_000

      # Live activity keeps updating underneath.
      grep = Event.new(:tool_start, %{name: "grep", arguments: %{"command" => "rg x"}})
      updated = WorkflowProgress.apply(renewed, child("a", grep), 3_000)
      assert updated.runs["a"].now == "grep rg x"
      assert updated.runs["a"].narration == "mapping the session code"

      kept = WorkflowProgress.refresh(updated, 16_999)
      assert kept.runs["a"].narration == "mapping the session code"

      expired = WorkflowProgress.refresh(updated, 17_000)
      refute Map.has_key?(expired.runs["a"], :narration)
      assert expired.runs["a"].now == "grep rg x"
    end

    test "narration of unknown, finished, or settled runs is ignored" do
      model = apply_all([started("a", "scout", "map"), started("b", "w", "x"), finished("b")])

      assert WorkflowProgress.narrate(model, "missing", "hello", 0) === model
      assert WorkflowProgress.narrate(model, "b", "hello", 0) === model
      assert WorkflowProgress.narrate(model, "a", "", 0) === model

      narrated = WorkflowProgress.narrate(model, "a", "mapping", 0)
      done = WorkflowProgress.apply(narrated, finished("a"), 1_000)
      refute Map.has_key?(done.runs["a"], :narration)

      settled = WorkflowProgress.settle(narrated, 1_000)
      refute Map.has_key?(settled.runs["a"], :narration)
      assert WorkflowProgress.narrate(settled, "a", "late", 2_000) === settled
    end

    test "logs and stages are bounded; old stages leave with their runs" do
      events =
        Enum.flat_map(1..205, fn n ->
          id = "r#{n}"
          [started(id, "w", "step #{n}"), finished(id), %{kind: :log, message: "log #{n}"}]
        end)

      model = apply_all(events)

      assert length(model.stages) == 200
      assert model.omitted == 5
      refute Map.has_key?(model.runs, "r1")
      assert Map.has_key?(model.runs, "r205")
      assert length(model.logs) == 20
      assert List.last(model.logs) == "log 205"
    end
  end

  describe "view" do
    test "draws a flow chart with branches, queued items, and the latest log" do
      model =
        apply_all([
          started("a", "scout", "Map the code\nmore detail"),
          finished("a"),
          %{kind: :parallel_started, id: 1, count: 3, limit: 2},
          started("b", "reviewer", "Review one", %{id: 1, index: 1}),
          finished("b"),
          started("c", "reviewer", "Review two", %{id: 1, index: 2}),
          child("c", Event.new(:tool_start, %{name: "read", arguments: %{"path" => "a.ex"}})),
          %{kind: :log, message: "reviewing"}
        ])

      assert text(WorkflowView.rows(model, 80, :preview)) == [
               "✓ scout  0s  Map the code",
               "│",
               "┬ parallel  1/3 done · limit 2",
               "├ ✓ reviewer  0s  Review one",
               "├ ● reviewer  0s  Review two · read a.ex",
               "└ ○ 1 queued",
               "▸ reviewing"
             ]
    end

    test "a fresh narration is drawn in place of the activity" do
      read = Event.new(:tool_start, %{name: "read", arguments: %{"path" => "a.ex"}})
      model = apply_all([started("a", "scout", "Map the code"), child("a", read)])

      assert text(WorkflowView.rows(model, 80, :preview)) == [
               "● scout  0s  Map the code · read a.ex"
             ]

      narrated = WorkflowProgress.narrate(model, "a", "mapping where titles live", 0)

      assert text(WorkflowView.rows(narrated, 80, :preview)) == [
               "● scout  0s  Map the code · mapping where titles live"
             ]
    end

    test "concurrent runs and failed items are explicit" do
      model =
        apply_all([
          started("a", "r", "x"),
          started("b", "r", "y"),
          finished("a", false, :error),
          %{kind: :parallel_started, id: 2, count: 1, limit: 1},
          %{kind: :item_failed, parallel: %{id: 2, index: 1}, status: "capacity", text: "busy"}
        ])

      assert text(WorkflowView.rows(model, 80, :details)) == [
               "┬ concurrent  0/2 done · 1 failed",
               "├ ✗ r  0s  error  x",
               "└ ● r  0s  y",
               "│",
               "┬ parallel  0/1 done · 1 failed · limit 1",
               "└ ✗ item 1  capacity"
             ]
    end

    test "the preview keeps the newest stages within its budget" do
      model =
        apply_all(
          Enum.flat_map(1..10, fn n -> [started("r#{n}", "w", "step #{n}"), finished("r#{n}")] end)
        )

      rows = text(WorkflowView.rows(model, 80, :preview, 6))
      assert length(rows) <= 6
      assert hd(rows) == "⋯ 7 earlier steps"
      assert length(rows) == 6
      assert List.last(rows) =~ "step 10"
      assert length(text(WorkflowView.rows(model, 80, :details))) == 19
    end

    test "a large batch lists what needs attention and counts the rest" do
      events =
        [%{kind: :parallel_started, id: 1, count: 30, limit: 4}] ++
          Enum.flat_map(1..20, fn n ->
            started = started("r#{n}", "rev", "item #{n}", %{id: 1, index: n})
            if n <= 18, do: [started, finished("r#{n}")], else: [started]
          end)

      rows = text(WorkflowView.rows(apply_all(events), 80, :preview))

      assert rows == [
               "┬ parallel  18/30 done · limit 4",
               "├ ● rev  0s  item 19",
               "├ ● rev  0s  item 20",
               "├ ✓ 18 done",
               "└ ○ 10 queued"
             ]
    end

    test "rows are clipped to the display width, including wide characters" do
      model = apply_all([started("a", "scout", String.duplicate("漢", 40))])

      for width <- [8, 20, 33] do
        for row <- WorkflowView.rows(model, width, :details) do
          line = Enum.map_join(row.spans, & &1.content)
          assert Tackle.CLI.TUI.MessageView.display_width(line) <= width
        end
      end
    end

    test "the chain summarises each stage in one line" do
      model =
        apply_all([
          started("a", "scout", "map"),
          finished("a"),
          %{kind: :parallel_started, id: 1, count: 2, limit: 2},
          started("b", "rev", "1", %{id: 1, index: 1}),
          finished("b"),
          started("c", "rev", "2", %{id: 1, index: 2}),
          finished("c", false, :error),
          started("d", "worker", "fix")
        ])

      assert WorkflowView.chain(model) == "✓ scout → ✗ rev ×2 → ● worker"
    end
  end
end
