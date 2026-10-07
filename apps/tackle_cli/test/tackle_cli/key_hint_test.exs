defmodule Tackle.CLI.TUI.KeyHintTest do
  @moduledoc "Uniform hint spans and whole-hint width selection."

  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.{KeyHint, Theme}

  describe "spans/1" do
    test "renders a bold key token followed by a muted label" do
      [key, label] = KeyHint.spans({"esc", "interrupt"})

      assert key.content == "esc"
      assert key.style.modifiers == [:bold]
      assert label.content == " interrupt"
      assert label.style == Theme.style(:muted)
    end

    test "joins a hint row with muted separators" do
      [key, _label, separator, second_key, second_label] =
        KeyHint.row_spans([{"esc", "interrupt"}, {"?", "help"}])

      assert key.content == "esc"
      assert separator.content == " · "
      assert separator.style == Theme.style(:subtle)
      assert second_key.content == "?"
      assert second_label.content == " help"
    end
  end

  describe "row_width/1" do
    test "counts hints and the separators between them" do
      assert KeyHint.row_width([]) == 0
      assert KeyHint.row_width([{"esc", "interrupt"}]) == 13
      assert KeyHint.row_width([{"esc", "interrupt"}, {"?", "help"}]) == 13 + 3 + 6
    end
  end

  describe "first_fitting/2" do
    test "keeps the fullest row that fits" do
      candidates = [[{"esc", "interrupt"}, {"?", "help"}], [{"esc", "interrupt"}], []]

      assert KeyHint.first_fitting(candidates, 80) == hd(candidates)
      assert KeyHint.first_fitting(candidates, 22) == hd(candidates)
    end

    test "drops a hint whole rather than truncating it" do
      candidates = [[{"esc", "interrupt"}, {"?", "help"}], [{"esc", "interrupt"}], []]

      assert KeyHint.first_fitting(candidates, 21) == [{"esc", "interrupt"}]
      assert KeyHint.first_fitting(candidates, 12) == []
    end
  end
end
