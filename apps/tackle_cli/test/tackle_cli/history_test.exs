defmodule Tackle.CLI.TUI.HistoryTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.History
  alias Tackle.CLI.TUI.Pastes.Draft

  describe "record/2" do
    test "keeps prompts newest first and keeps each draft's labels" do
      history =
        History.new()
        |> History.record(draft("first"))
        |> History.record(%Draft{text: "second", spans: [{1, 0, 6}]})

      assert texts(history) == ["second", "first"]
      assert hd(history.entries).spans == [{1, 0, 6}]
    end

    test "ignores blank drafts" do
      assert History.record(History.new(), Draft.new("   \n ")).entries == []
      assert History.record(History.new(), nil).entries == []
    end

    test "does not repeat the newest entry" do
      history =
        History.new()
        |> History.record(draft("same"))
        |> History.record(draft("same"))

      assert texts(history) == ["same"]
    end

    test "records a repeat of an older entry" do
      history =
        History.new()
        |> History.record(draft("older"))
        |> History.record(draft("newer"))
        |> History.record(draft("older"))

      assert texts(history) == ["older", "newer", "older"]
    end

    test "caps the list and drops the oldest entry first" do
      history = Enum.reduce(1..150, History.new(), &History.record(&2, draft("prompt #{&1}")))

      assert Enum.count_until(history.entries, 101) == 100
      assert hd(texts(history)) == "prompt 150"
      assert List.last(texts(history)) == "prompt 51"
    end

    test "ends browsing" do
      history = %History{entries: [draft("older")], index: 0, draft: draft("typing")}

      assert %History{index: nil, draft: nil} = History.record(history, draft("next"))
    end
  end

  describe "previous/2 and next/1" do
    test "walk from the newest to the oldest and back to the draft" do
      history =
        History.new()
        |> History.record(draft("oldest"))
        |> History.record(draft("middle"))
        |> History.record(draft("newest"))

      assert {history, recalled} = History.previous(history, draft("half-written"))
      assert recalled.text == "newest"
      assert History.browsing?(history)

      assert {history, recalled} = History.previous(history, draft("ignored"))
      assert recalled.text == "middle"
      assert {history, recalled} = History.previous(history, draft("ignored"))
      assert recalled.text == "oldest"
      assert :none = History.previous(history, draft("ignored"))

      assert {history, recalled} = History.next(history)
      assert recalled.text == "middle"
      assert {history, recalled} = History.next(history)
      assert recalled.text == "newest"

      assert {%History{index: nil}, restored} = History.next(history)
      assert restored.text == "half-written"
    end

    test "steps to the newest entry without a captured draft only once" do
      history = History.new() |> History.record(draft("only"))

      assert {history, recalled} = History.previous(history, Draft.new())
      assert recalled.text == "only"

      assert {_, restored} = History.next(history)
      assert restored.text == ""
      assert :none = History.next(History.new())
    end

    test "previous/2 on an empty history changes nothing" do
      assert :none = History.previous(History.new(), draft("draft"))
    end
  end

  describe "leave_browsing/1" do
    test "drops the position but keeps the entries" do
      history = %History{entries: [draft("a"), draft("b")], index: 1, draft: draft("draft")}

      assert %History{entries: [%Draft{text: "a"}, %Draft{text: "b"}], index: nil, draft: nil} =
               History.leave_browsing(history)
    end
  end

  defp draft(text), do: Draft.new(text)

  defp texts(%History{entries: entries}), do: Enum.map(entries, & &1.text)
end
