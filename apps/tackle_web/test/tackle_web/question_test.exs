defmodule Tackle.Web.QuestionTest do
  use ExUnit.Case, async: true

  alias Tackle.Web.Anchor
  alias Tackle.Web.Question

  describe "prompt/2" do
    test "names the line a question is about before the question" do
      anchor = Anchor.new("lib/a.ex", :new, 12)

      assert Question.prompt(anchor, "Why?") ==
               "About lib/a.ex line 12 (the new side of the diff):\n\nWhy?"
    end

    test "names a range by its ends" do
      anchor = Anchor.new("lib/a.ex", :old, 12, 15)

      assert Question.prompt(anchor, "Why?") ==
               "About lib/a.ex lines 12-15 (the old side of the diff):\n\nWhy?"
    end

    test "names the whole review when no line was selected" do
      assert Question.prompt(:general, "What changed?") ==
               "About this review as a whole:\n\nWhat changed?"
    end

    test "trims the question" do
      assert Question.prompt(:general, "  spaced  ") ==
               "About this review as a whole:\n\nspaced"
    end

    test "asks the question unchanged when there is no anchor" do
      assert Question.prompt(nil, "  plain  ") == "plain"
    end
  end

  describe "body/1" do
    test "recovers the wording from a prompt about a line" do
      prompt = Question.prompt(Anchor.new("lib/a.ex", :new, 12), "Why?")

      assert Question.body(prompt) == "Why?"
    end

    test "recovers a question that has blank lines of its own" do
      prompt = Question.prompt(:general, "First.\n\nSecond.")

      assert Question.body(prompt) == "First.\n\nSecond."
    end

    test "leaves text that carries no location alone" do
      assert Question.body("Why?") == "Why?"
    end

    test "round-trips every anchor shape" do
      for anchor <- [
            :general,
            Anchor.new("lib/a.ex", :new, 3),
            Anchor.new("lib/a.ex", :old, 3, 9)
          ] do
        assert anchor |> Question.prompt("why?") |> Question.body() == "why?"
      end
    end
  end
end
