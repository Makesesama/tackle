defmodule Tackle.CLI.TerminalTitleTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TerminalTitle

  describe "sanitize/2" do
    test "strips control characters and collapses whitespace" do
      assert TerminalTitle.sanitize(
               "  Project\t|\nWorking\x1b\x07\u{009D}\u{009C} |  Thread  ",
               :unicode
             ) == "Project | Working | Thread"
    end

    test "strips invisible and bidi formatting characters" do
      assert TerminalTitle.sanitize(
               "Pro\u{202E}j\u{2066}e\u{200F}c\u{061C}t\u{200B} \u{FEFF}T\u{2060}itle",
               :unicode
             ) == "Project Title"
    end

    test "truncates at 240 emitted codepoints" do
      sanitized = TerminalTitle.sanitize(String.duplicate("a", 250), :unicode)
      assert String.length(sanitized) == 240
    end

    test "truncation prefers a visible character over a pending space" do
      sanitized = TerminalTitle.sanitize(String.duplicate("a", 239) <> " b", :unicode)

      assert String.length(sanitized) == 240
      assert String.last(sanitized) == "b"
    end

    test "screen titles stay printable ASCII" do
      title = " ● ⠇ | ě[31m thread \u{202e}\x07| 日本語 ćafé  "

      assert TerminalTitle.sanitize(title, :screen) == "* | | ?[31m thread | ??? ?af?"
      assert TerminalTitle.sanitize(title, :unicode) == "● ⠇ | ě[31m thread | 日本語 ćafé"
      assert TerminalTitle.sanitize("日本語", :screen) == "???"
      assert TerminalTitle.sanitize("\x07\x1b\u{202E}\u{FEFF}", :screen) == ""
    end
  end

  test "osc0/1 frames the title as OSC 0 with a BEL terminator" do
    assert TerminalTitle.osc0("hello") == "\e]0;hello\a"
  end

  describe "clear/0 and write/1" do
    # ExUnit runs with stdout captured, so these exercise the non-terminal
    # branch. The terminal branch normalizes emit/1's {:ok, :applied} back to
    # :ok so the write/1 seam keeps a single success shape for clears; the
    # interactive shell's clear matches only :ok and would otherwise crash on
    # exit with a case_clause.
    test "clear/0 returns :ok, not emit/1's applied marker" do
      assert TerminalTitle.clear() == :ok
    end

    test "write/1 with nil clears and returns :ok" do
      assert TerminalTitle.write(nil) == :ok
    end
  end
end
