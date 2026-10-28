defmodule Tackle.CLI.ReviewRulesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Tackle.CLI.ReviewRules
  alias Tackle.Review.Rules

  setup do
    root = Path.join(System.tmp_dir!(), "tackle-cli-rules-#{System.unique_integer([:positive])}")
    cwd = Path.join(root, "repo")
    home = Path.join(root, "tackle-home")
    File.mkdir_p!(Path.join(cwd, ".git"))
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      cwd: cwd,
      home: home,
      project: Path.join(cwd, ".tackle/review/rules"),
      opts: [cwd: cwd, env: %{"TACKLE_HOME" => home, "HOME" => root}]
    }
  end

  defp put(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp run(opts) do
    {status, output} = with_io(fn -> ReviewRules.run(opts) end)
    {status, output}
  end

  test "exits 0 and lists the rules when every file loads", ctx do
    put(Path.join(ctx.project, "off.md"), "---\nid: injection\nstatus: suppressed\n---\n")

    assert {0, output} = run(ctx.opts)
    assert output =~ "Review rules: #{length(Rules.builtin_ids()) - 1} active, 1 suppressed;"
    assert output =~ "- injection: suppressed, project, replaces the built-in rule"
    assert output =~ "- project: #{ctx.project}"
  end

  test "exits 1 and names the files that do not load", ctx do
    put(Path.join(ctx.project, "bad.md"), "---\nid: bad\ncategory: style\n---\nx\n")

    assert {1, output} = run(ctx.opts)
    assert output =~ "1 problem."
    assert output =~ "#{Path.join(ctx.project, "bad.md")}: category must be one of"
  end

  test "applies review.default_rules from the user and project configuration", ctx do
    put(Path.join(ctx.home, "config.json"), ~s({"review": {"default_rules": ["injection"]}}))

    assert {0, output} = run(ctx.opts)
    assert output =~ "Review rules: 1 active; no problems."
    assert output =~ "Built-in rules left out by review.default_rules: boundary-condition"

    put(
      Path.join(ctx.cwd, ".tackle/config.json"),
      ~s({"review": {"default_rules": ["injection", "secret-exposure"]}})
    )

    assert {0, output} = run(ctx.opts)
    assert output =~ "Review rules: 2 active; no problems."
  end

  test "exits 2 when the configuration is invalid", ctx do
    put(Path.join(ctx.home, "config.json"), ~s({"review": {"default_rules": ["nope"]}}))

    stderr =
      capture_io(:stderr, fn ->
        assert {2, ""} = run(ctx.opts)
      end)

    assert stderr =~ "review.default_rules names unknown built-in rules: nope"
  end
end
