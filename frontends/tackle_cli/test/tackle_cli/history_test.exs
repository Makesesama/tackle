defmodule Tackle.CLI.TUI.HistoryTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.History

  describe "record/2" do
    test "keeps prompts newest first and trims surrounding whitespace" do
      history =
        History.new()
        |> History.record("first")
        |> History.record("  second  ")

      assert history.entries == ["second", "first"]
    end

    test "ignores blank prompts" do
      history = History.record(History.new(), "   \n ")

      assert history.entries == []
    end

    test "does not repeat the newest entry" do
      history =
        History.new()
        |> History.record("same")
        |> History.record("same")

      assert history.entries == ["same"]
    end

    test "records a repeat of an older entry" do
      history =
        History.new()
        |> History.record("older")
        |> History.record("newer")
        |> History.record("older")

      assert history.entries == ["older", "newer", "older"]
    end

    test "caps the list and drops the oldest entry first" do
      history = Enum.reduce(1..150, History.new(), &History.record(&2, "prompt #{&1}"))

      assert length(history.entries) == 100
      assert hd(history.entries) == "prompt 150"
      assert List.last(history.entries) == "prompt 51"
    end

    test "ends browsing" do
      history = %History{entries: ["older"], index: 0, draft: "typing"}

      assert %History{index: nil, draft: nil} = History.record(history, "next")
    end
  end

  describe "previous/2 and next/1" do
    test "walk from the newest to the oldest and back to the draft" do
      history =
        History.new()
        |> History.record("oldest")
        |> History.record("middle")
        |> History.record("newest")

      assert {history, "newest"} = History.previous(history, "half-written")
      assert History.browsing?(history)

      assert {history, "middle"} = History.previous(history, "ignored")
      assert {history, "oldest"} = History.previous(history, "ignored")
      assert :none = History.previous(history, "ignored")

      assert {history, "middle"} = History.next(history)
      assert {history, "newest"} = History.next(history)
      assert {%History{index: nil}, "half-written"} = History.next(history)
    end

    test "steps to the newest entry without a captured draft only once" do
      history = History.new() |> History.record("only")

      assert {history, "only"} = History.previous(history, "")
      assert {_, ""} = History.next(history)
      assert :none = History.next(History.new())
    end

    test "previous/2 on an empty history changes nothing" do
      assert :none = History.previous(History.new(), "draft")
    end
  end

  describe "leave_browsing/1" do
    test "drops the position but keeps the entries" do
      history = %History{entries: ["a", "b"], index: 1, draft: "draft"}

      assert %History{entries: ["a", "b"], index: nil, draft: nil} =
               History.leave_browsing(history)
    end
  end
end
