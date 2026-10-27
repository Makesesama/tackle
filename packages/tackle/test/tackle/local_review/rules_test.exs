defmodule Tackle.LocalReview.RulesTest do
  use ExUnit.Case, async: true

  alias Tackle.LocalReview.Rules, as: RuleDiscovery
  alias Tackle.Review.Rules
  alias Tackle.Review.Rules.Rule
  alias Tackle.Test.FakeJail

  @builtin_rules %{
    "unhandled-error" => {:correctness, :high},
    "missing-nil-check" => {:correctness, :high},
    "boundary-condition" => {:correctness, :medium},
    "broken-contract" => {:correctness, :high},
    "resource-leak" => {:correctness, :medium},
    "concurrency-hazard" => {:correctness, :high},
    "injection" => {:security, :blocker},
    "secret-exposure" => {:security, :blocker},
    "missing-test-for-behaviour-change" => {:testing, :low}
  }

  setup do
    root = Path.join(System.tmp_dir!(), "tackle-rules-#{System.unique_integer([:positive])}")
    cwd = Path.join(root, "project")
    home = Path.join(root, "home")
    builtin = Path.join(root, "builtin")
    File.mkdir_p!(Path.join(cwd, ".git"))
    File.mkdir_p!(builtin)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      cwd: cwd,
      home: home,
      builtin: builtin,
      user: Path.join(home, "review/rules"),
      project: Path.join(cwd, ".tackle/review/rules"),
      opts: [cwd: cwd, env: %{"TACKLE_HOME" => home}, builtin_dir: builtin]
    }
  end

  defp put(dir, name, contents) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), contents)
  end

  defp rule(id, opts \\ []) do
    front =
      [
        "id: #{id}",
        "category: #{Keyword.get(opts, :category, "correctness")}",
        "severity: #{Keyword.get(opts, :severity, "medium")}"
      ] ++ Keyword.get(opts, :extra, [])

    "---\n#{Enum.join(front, "\n")}\n---\n#{Keyword.get(opts, :body, "Check #{id}.")}\n"
  end

  defp by_id(rules), do: Map.new(rules, &{&1.id, &1})

  describe "built-in rules" do
    test "are embedded, so discovery needs no priv directory", %{opts: opts, root: root} do
      # Release and escript builds may lack `priv/`; nothing may depend on it.
      refute File.exists?(Application.app_dir(:tackle, "priv/review/rules"))

      assert Enum.map(Rules.builtin_files(), &elem(&1, 0)) ==
               @builtin_rules |> Map.keys() |> Enum.map(&(&1 <> ".md")) |> Enum.sort()

      opts = Keyword.merge(Keyword.delete(opts, :builtin_dir), env: %{"TACKLE_HOME" => root})
      assert %{rules: rules, warnings: []} = RuleDiscovery.discover(opts)
      assert Enum.map(rules, & &1.id) == @builtin_rules |> Map.keys() |> Enum.sort()

      for rule <- rules do
        assert rule.path == "builtin:review/rules/#{rule.id}.md"
        refute File.exists?(rule.path)
      end
    end

    test "are overridden by user and project rules", %{opts: opts, project: project} do
      put(project, "off.md", "---\nid: injection\nstatus: suppressed\n---\n")
      put(project, "nil.md", rule("missing-nil-check", severity: "low"))

      rules =
        opts |> Keyword.delete(:builtin_dir) |> RuleDiscovery.discover() |> Map.fetch!(:rules)

      assert %Rule{status: :suppressed, source: :project} = by_id(rules)["injection"]

      assert %Rule{severity: :low, source: :project} = by_id(rules)["missing-nil-check"]
      assert %Rule{source: :builtin} = by_id(rules)["secret-exposure"]
    end

    test "builtin_rules keeps only the listed built-in rules", %{
      opts: opts,
      project: project,
      root: root
    } do
      assert Rules.builtin_ids() == @builtin_rules |> Map.keys() |> Enum.sort()

      put(project, "own.md", rule("project-only"))
      put(project, "inj.md", rule("injection", severity: "low"))
      opts = Keyword.merge(Keyword.delete(opts, :builtin_dir), env: %{"TACKLE_HOME" => root})

      ids = fn keep ->
        opts
        |> Keyword.put(:builtin_rules, keep)
        |> RuleDiscovery.discover()
        |> Map.fetch!(:rules)
      end

      assert Enum.map(ids.(["secret-exposure"]), &{&1.id, &1.source}) == [
               {"injection", :project},
               {"project-only", :project},
               {"secret-exposure", :builtin}
             ]

      # User and project rules stay, even with an id of a dropped built-in rule.
      assert Enum.map(ids.([]), & &1.id) == ["injection", "project-only"]
      assert length(ids.(:all)) == map_size(@builtin_rules) + 1
    end

    test "ship the MVP set as active, language-agnostic rules with examples", %{
      opts: opts,
      root: root
    } do
      opts = Keyword.merge(Keyword.delete(opts, :builtin_dir), env: %{"TACKLE_HOME" => root})
      assert %{rules: rules, warnings: []} = RuleDiscovery.discover(opts)

      assert Map.new(rules, &{&1.id, {&1.category, &1.severity}}) == @builtin_rules

      for rule <- rules do
        assert rule.source == :builtin
        assert rule.status == :active
        assert rule.applies_to == ["**/*"]
        assert Path.basename(rule.path) == rule.id <> ".md"
        assert rule.body =~ ~r/^## Bad$/m
        assert rule.body =~ ~r/^## Good$/m
        assert byte_size(rule.body) <= 1_024
      end
    end
  end

  describe "discover/1" do
    test "later sources override earlier ones by id", %{opts: opts} = ctx do
      put(ctx.builtin, "a.md", rule("shared", severity: "low"))
      put(ctx.builtin, "b.md", rule("builtin-only"))
      put(ctx.user, "shared.md", rule("shared", severity: "medium"))
      put(ctx.user, "user-only.md", rule("user-only"))
      put(ctx.project, "other-name.md", rule("shared", severity: "high"))
      put(ctx.project, "builtin-off.md", "---\nid: builtin-only\nstatus: suppressed\n---\n")

      assert %{rules: rules, warnings: []} = RuleDiscovery.discover(opts)
      assert Enum.map(rules, & &1.id) == ["builtin-only", "shared", "user-only"]
      rules = by_id(rules)

      assert %Rule{source: :project, severity: :high} = rules["shared"]
      assert rules["shared"].path == Path.join(ctx.project, "other-name.md")
      assert %Rule{source: :user, status: :active} = rules["user-only"]

      assert %Rule{source: :project, status: :suppressed, category: nil, body: ""} =
               rules["builtin-only"]
    end

    test "uses the nearest project directory and stops at the Git root", ctx do
      put(Path.join(ctx.root, ".tackle/review/rules"), "outside.md", rule("outside"))
      assert RuleDiscovery.discover(ctx.opts).rules == []

      put(ctx.project, "parent.md", rule("parent"))
      child = Path.join(ctx.cwd, "lib/deep")
      File.mkdir_p!(child)
      child_opts = Keyword.put(ctx.opts, :cwd, child)
      assert [%Rule{id: "parent"}] = RuleDiscovery.discover(child_opts).rules

      put(Path.join(child, ".tackle/review/rules"), "child.md", rule("child"))
      assert [%Rule{id: "child"}] = RuleDiscovery.discover(child_opts).rules
    end

    test "never reads $TACKLE_HOME as the project directory", %{root: root, builtin: builtin} do
      # The default layout: $TACKLE_HOME is ~/.tackle and the working
      # directory is under ~, outside any Git repository.
      put(Path.join(root, ".tackle/review/rules"), "mine.md", rule("mine"))
      cwd = Path.join(root, "notes")
      File.mkdir_p!(cwd)
      env = %{"TACKLE_HOME" => Path.join(root, ".tackle"), "HOME" => root}

      assert %{rules: [%Rule{id: "mine", source: :user}], warnings: []} =
               RuleDiscovery.discover(cwd: cwd, env: env, builtin_dir: builtin)
    end

    test "without a Git root, does not climb above the working directory outside home", ctx do
      put(Path.join(ctx.root, ".tackle/review/rules"), "planted.md", rule("planted"))
      cwd = Path.join(ctx.root, "scratch")
      File.mkdir_p!(cwd)

      assert RuleDiscovery.discover(Keyword.put(ctx.opts, :cwd, cwd)).rules == []
    end

    test "reads flat Markdown files only", %{opts: opts, project: project} do
      put(project, "notes.txt", rule("text"))
      put(Path.join(project, "nested"), "nested.md", rule("nested"))
      put(project, "kept.md", rule("kept"))
      assert %{rules: [%Rule{id: "kept"}], warnings: []} = RuleDiscovery.discover(opts)
    end

    test "skips invalid files with warnings", %{opts: opts, project: project} do
      put(project, "a-ok.md", rule("ok"))
      put(project, "b-duplicate.md", rule("ok"))
      put(project, "c-invalid.md", "---\nid: Not Valid\n---\nBody")
      put(project, "d-binary.md", <<0xFF, 0xFE>>)
      put(project, "e-large.md", rule("large", body: String.duplicate("x", 101)))

      assert %{rules: [%Rule{id: "ok"} = ok], warnings: warnings} =
               RuleDiscovery.discover(Keyword.put(opts, :max_rule_bytes, 100))

      assert ok.path == Path.join(project, "a-ok.md")

      assert [
               {"b-duplicate.md", duplicate},
               {"c-invalid.md", "id must use lowercase letters, numbers, and single hyphens"},
               {"d-binary.md", "file is not valid UTF-8"},
               {"e-large.md", "rule body is 101 bytes; the limit is 100"}
             ] = Enum.map(warnings, &{Path.basename(&1.path), &1.message})

      assert duplicate =~ "rule id ok is already defined in"
    end

    test "warns when the built-in directory is missing", %{opts: opts, root: root} do
      missing = Path.join(root, "missing")

      assert %{rules: [], warnings: [warning]} =
               RuleDiscovery.discover(Keyword.put(opts, :builtin_dir, missing))

      assert warning.path == missing
      assert warning.message =~ "could not list rule directory"

      assert %{rules: [], warnings: []} =
               RuleDiscovery.discover(Keyword.put(opts, :builtin_dir, nil))
    end

    test "does not follow workspace symlinks to host files under a jail", ctx do
      secret = Path.join(ctx.home, "secret.md")
      put(ctx.home, "secret.md", rule("secret"))
      File.mkdir_p!(ctx.project)
      File.ln_s!(secret, Path.join(ctx.project, "leak.md"))

      assert RuleDiscovery.discover(ctx.opts).rules |> Enum.map(& &1.id) == ["secret"]

      opts = Keyword.put(ctx.opts, :executor, FakeJail.new(ctx.cwd))
      assert RuleDiscovery.discover(opts).rules == []
    end

    test "refuses oversized files without reading them whole", %{opts: opts, project: project} do
      put(project, "big.md", rule("big", body: :binary.copy("x", 600_000)))
      put(project, "ok.md", rule("ok"))
      opts = Keyword.merge(opts, max_rule_bytes: 100, executor: FakeJail.new(opts[:cwd], self()))

      assert %{rules: [%Rule{id: "ok"}], warnings: [warning]} = RuleDiscovery.discover(opts)
      assert warning.path == Path.join(project, "big.md")
      assert warning.message == "file is larger than 1124 bytes"
      path = warning.path
      assert_received {:fake_jail_read, ^path, 0, 1_125}
      refute_received {:fake_jail_read, ^path, _offset, _length}
    end

    test "rejects invalid size options", %{opts: opts} do
      assert_raise ArgumentError, ~r/:max_rule_bytes must be a positive integer/, fn ->
        RuleDiscovery.discover(Keyword.put(opts, :max_rule_bytes, 0))
      end
    end
  end
end
