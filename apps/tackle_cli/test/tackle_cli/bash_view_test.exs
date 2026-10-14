defmodule Tackle.CLI.TUI.BashViewTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.{BashView, Theme}

  test "split_cwd peels only a leading cd that precedes the command" do
    assert BashView.split_cwd("cd apps/x && mix test") == {"apps/x", "mix test"}
    assert BashView.split_cwd("cd apps/x; mix test") == {"apps/x", "mix test"}
    assert BashView.split_cwd("  cd \"a b\" &&  ls -la") == {"a b", "ls -la"}
    assert BashView.split_cwd("cd a && cd b && ls") == {"a", "cd b && ls"}
    assert BashView.split_cwd("cd a && ") == {nil, "cd a && "}
    assert BashView.split_cwd("cd a || ls") == {nil, "cd a || ls"}
    assert BashView.split_cwd("echo cd a && ls") == {nil, "echo cd a && ls"}
  end

  test "absolute directories read relative to the working directory" do
    cwd = File.cwd!()
    assert BashView.split_cwd("cd #{cwd}/lib/x; ls") == {"lib/x", "ls"}
    # The current directory adds nothing: every command already runs there.
    assert BashView.split_cwd("cd #{cwd} && ls") == {nil, "ls"}
    assert BashView.split_cwd("cd /elsewhere && ls") == {"/elsewhere", "ls"}

    if home = System.user_home() do
      unless String.starts_with?(cwd, home <> "/elsewhere") do
        assert BashView.split_cwd("cd #{home}/elsewhere && ls") == {"~/elsewhere", "ls"}
      end
    end
  end

  test "shell spans use theme tones by token role" do
    line = ~s(FOO=1 grep -n "a b" lib --color=never | head -2; echo 'x' 2>&1 > out)
    spans = BashView.shell_spans(line)

    assert Enum.map_join(spans, & &1.content) == line
    tone = fn text -> Enum.find(spans, &(String.trim(&1.content) == text)).style end

    assert tone.("FOO=1") == Theme.style(:muted)
    assert tone.("grep") == Theme.style(:accent_soft)
    assert tone.("head") == Theme.style(:accent_soft)
    assert tone.("echo") == Theme.style(:accent_soft)
    assert tone.("lib") == Theme.style(:text)
    assert tone.("-n") == Theme.style(:muted)
    assert tone.("\"a b\"") == Theme.style(:muted)
    assert tone.("--color=never") == Theme.style(:muted)
    assert tone.("|") == Theme.style(:subtle)
    assert tone.(";") == Theme.style(:subtle)
    # A redirection is not a command boundary: `1` and `out` are arguments.
    assert tone.(">&") == Theme.style(:subtle)
    assert tone.("1") == Theme.style(:text)
    assert tone.("out") == Theme.style(:text)
    assert BashView.shell_spans("") == []
  end

  test "heredoc bodies stay plain text through their terminator" do
    command = "python3 - <<'EOF'\nimport os; print(1)\nEOF\nmix test | tail -2"

    [first, body, terminator, rest] = BashView.line_spans(command)

    assert hd(first).style == Theme.style(:accent_soft)
    assert [%{content: "import os; print(1)", style: style}] = body
    assert style == Theme.style(:text)
    assert [%{content: "EOF"}] = terminator
    assert hd(rest).content == "mix"
    assert hd(rest).style == Theme.style(:accent_soft)

    assert length(BashView.line_spans("ls\n")) == 1
  end

  test "dedent strips only the indentation every shown line shares" do
    assert BashView.dedent(["    a", "      b"], ["    c"]) == {["a", "  b"], ["c"]}
    assert BashView.dedent(["\t\ta"], ["\tb"]) == {["\ta"], ["b"]}
    assert BashView.dedent(["  a", "b"], []) == {["  a", "b"], []}
    # Mixed tabs and spaces share only their common prefix.
    assert BashView.dedent(["\t a"], [" \tb"]) == {["\t a"], [" \tb"]}
    assert BashView.dedent([], []) == {[], []}
  end

  test "outcome lifts the exit code and the error prefix out of the output" do
    assert BashView.outcome("Error: boom\n\nCommand exited with code 3") == {"boom", 3}
    assert BashView.outcome("Error: Command exited with code 1") == {"", 1}

    assert BashView.outcome("Error: tick\nCommand stopped by watchdog") ==
             {"tick\nCommand stopped by watchdog", nil}

    assert BashView.outcome(nil) == {"", nil}
  end

  test "elapsed shows tenths for short settled calls and whole seconds otherwise" do
    assert BashView.elapsed(412, :completed) == "0.4s"
    assert BashView.elapsed(9_960, :failed) == "9.9s"
    assert BashView.elapsed(12_400, :completed) == "12s"
    assert BashView.elapsed(3_400, :running) == "3s"
    assert BashView.elapsed(65_000, :completed) == "1m 5s"
  end
end
