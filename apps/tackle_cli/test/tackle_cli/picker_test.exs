defmodule Tackle.CLI.TUI.PickerTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.Picker

  defp item(primary, opts \\ []) do
    %{
      id: primary,
      primary: primary,
      secondary: Keyword.get(opts, :secondary),
      marker: Keyword.get(opts, :marker),
      search: Keyword.get(opts, :search)
    }
  end

  defp labels(picker), do: Enum.map(Picker.filtered(picker), & &1.primary)

  describe "filtering" do
    test "an empty query keeps the authored order" do
      picker = Picker.new([item("c"), item("a"), item("b")])

      assert labels(picker) == ["c", "a", "b"]
    end

    test "a substring match outranks a scattered subsequence" do
      picker = Picker.new([item("xhigh"), item("high")])

      assert labels(Picker.insert(picker, "high")) == ["high", "xhigh"]
    end

    test "an earlier match within the same tier ranks first" do
      picker = Picker.new([item("beta-low"), item("low-beta")])

      assert labels(Picker.insert(picker, "low")) == ["low-beta", "beta-low"]
    end

    test "a query that is not a subsequence matches nothing" do
      picker = Picker.new([item("medium")])

      assert labels(Picker.insert(picker, "xyz")) == []
    end

    test "items match on their search text rather than what they print" do
      picker =
        Picker.new([
          item("gpt-5", secondary: "[openai]", search: "openai openai/gpt-5 gpt-5"),
          item("openai/gpt-5",
            secondary: "[openrouter]",
            search: "openrouter openrouter/openai/gpt-5 openai/gpt-5"
          )
        ])

      assert labels(Picker.insert(picker, "openai/gpt-5")) == ["gpt-5", "openai/gpt-5"]
      assert labels(Picker.insert(picker, "openrouter")) == ["openai/gpt-5"]
    end

    test "queries are case and whitespace insensitive" do
      picker = Picker.new([item("High")])

      assert labels(Picker.insert(picker, "  hIGh ")) == ["High"]
    end
  end

  describe "selection" do
    test "moving clamps at both ends instead of wrapping" do
      picker = Picker.new([item("a"), item("b")])

      assert Picker.selected(Picker.move(picker, -1)).primary == "a"
      assert Picker.selected(Picker.move(picker, 9)).primary == "b"
    end

    test "typing resets the selection to the best match" do
      picker = Picker.new([item("alpha"), item("beta")])
      picker = picker |> Picker.move(1) |> Picker.insert("a")

      assert picker.selected == 0
    end

    test "backspace removes one grapheme and ignores an empty query" do
      picker = Picker.new([item("ab")])

      assert Picker.backspace(picker).query == ""

      picker = picker |> Picker.insert("áb") |> Picker.backspace()
      assert picker.query == "á"
    end

    test "there is no selection when nothing matches" do
      picker = Picker.new([item("a")]) |> Picker.insert("zzz")

      assert Picker.selected(picker) == nil
    end
  end

  describe "rows" do
    test "renders the marker, the label, and the optional secondary text" do
      assert Picker.row(item("high", secondary: "Deep reasoning", marker: "✓")) ==
               "✓  high  Deep reasoning"

      assert Picker.row(item("high")) == "   high"
    end
  end
end
