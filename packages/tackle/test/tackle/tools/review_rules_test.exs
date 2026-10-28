defmodule Tackle.Tools.ReviewRulesTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.Rules
  alias Tackle.Review.Settings, as: ReviewSettings
  alias Tackle.Skills.Skill
  alias Tackle.Test.FakeJail
  alias Tackle.Tools.ReviewRules

  setup do
    root = Path.join(System.tmp_dir!(), "tackle-rule-tool-#{System.unique_integer([:positive])}")
    cwd = Path.join(root, "project")
    home = Path.join(root, "home")
    File.mkdir_p!(Path.join(cwd, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      cwd: cwd,
      home: home,
      project: Path.join(cwd, ".tackle/review/rules"),
      context: %{cwd: cwd, tackle_home: home, user_home: nil}
    }
  end

  defp put(dir, name, contents) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), contents)
  end

  test "is a read-only tool without parameters" do
    assert ReviewRules.name() == "check_review_rules"
    assert ReviewRules.parameters_schema() == []
    assert ReviewRules.effect() == :read_only
    assert %Tackle.Lib.Tool.Registry{} = Tackle.Lib.Tool.Registry.new([ReviewRules])
  end

  test "reports the rules and problems of the agent's working directory", ctx do
    put(ctx.project, "off.md", "---\nid: injection\nstatus: suppressed\n---\n")
    put(ctx.project, "bad.md", "---\nid: bad\nseverity: low\n---\nBody\n")
    child = Path.join(ctx.cwd, "lib")
    File.mkdir_p!(child)

    assert {:ok, text} = ReviewRules.run(%{}, %{ctx.context | cwd: child})
    assert text =~ "; 1 problem."
    assert text =~ "#{Path.join(ctx.project, "bad.md")}: category is required for an active rule"
    assert text =~ "- injection: suppressed, project, replaces the built-in rule"
    assert text =~ "- user: #{Path.join(ctx.home, "review/rules")} (does not exist)"
    assert text =~ "- project: #{ctx.project}"
  end

  test "applies the session's built-in rule selection", ctx do
    settings = %ReviewSettings{default_rules: ["secret-exposure"]}

    assert {:ok, text} = ReviewRules.run(%{}, Map.put(ctx.context, :review_settings, settings))
    assert text =~ "Review rules: 1 active; no problems."
    assert text =~ "- secret-exposure: blocker security, built-in"
    assert text =~ "Built-in rules left out by review.default_rules: boundary-condition"

    assert {:ok, all} = ReviewRules.run(%{}, ctx.context)
    assert all =~ "Review rules: #{length(Rules.builtin_ids())} active; no problems."
    refute all =~ "default_rules"
  end

  test "reads the project's rules through the session executor", ctx do
    secret = Path.join(ctx.home, "secret.md")
    put(ctx.home, "secret.md", "---\nid: secret\ncategory: security\nseverity: low\n---\nx\n")
    File.mkdir_p!(ctx.project)
    File.ln_s!(secret, Path.join(ctx.project, "leak.md"))

    assert {:ok, local} = ReviewRules.run(%{}, ctx.context)
    assert local =~ "- secret: low security, project"

    assert {:ok, jailed} =
             ReviewRules.run(%{}, Map.put(ctx.context, :executor, FakeJail.new(ctx.cwd)))

    refute jailed =~ "- secret:"
  end

  describe "skill_markdown/0" do
    test "is a built-in skill offered with the tool" do
      assert {:ok, %Skill{name: "tackle-review-rules", source: :builtin} = skill} =
               Tackle.Skills.builtin(ReviewRules.skill_markdown(),
                 requires_tools: [ReviewRules.name()]
               )

      assert skill.requires_tools == ["check_review_rules"]
      assert skill.content =~ "check_review_rules"
    end

    test "its example rules load" do
      examples =
        ~r/^```markdown\n(.*?)^```$/ms
        |> Regex.scan(ReviewRules.skill_markdown(), capture: :all_but_first)
        |> List.flatten()

      assert [full, suppressed] = examples

      assert {:ok, %Rules.Rule{id: "result-tuples", status: :active} = rule} =
               Rules.parse(full, "example.md", :project)

      assert rule.applies_to == ["lib/**/*.ex"]
      assert rule.body =~ ~r/^## Bad$/m
      assert rule.body =~ ~r/^## Good$/m

      assert {:ok, %Rules.Rule{id: "missing-nil-check", status: :suppressed}} =
               Rules.parse(suppressed, "off.md", :project)
    end

    test "lists every built-in rule id" do
      [_all, listed] =
        Regex.run(~r/The\s+built-in ids are:(.*?)\.\s/s, ReviewRules.skill_markdown())

      ids = ~r/`([a-z0-9-]+)`/ |> Regex.scan(listed, capture: :all_but_first) |> List.flatten()
      assert ids == Rules.builtin_ids()
    end
  end
end
