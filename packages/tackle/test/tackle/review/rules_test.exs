defmodule Tackle.Review.RulesTest do
  use ExUnit.Case, async: true

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

  defp parse!(contents) do
    assert {:ok, rule} = Rules.parse(contents, "/rules/x.md", :project)
    rule
  end

  defp parse_error(contents) do
    assert {:error, message} = Rules.parse(contents, "/rules/x.md", :project)
    message
  end

  defp unreadable(key),
    do: "#{key} has no readable value; close lists with ] and quote values that start with [ or {"

  defp by_id(rules), do: Map.new(rules, &{&1.id, &1})

  describe "built-in rules" do
    test "are embedded, so discovery needs no priv directory", %{opts: opts, root: root} do
      # Release and escript builds may lack `priv/`; nothing may depend on it.
      refute File.exists?(Application.app_dir(:tackle, "priv/review/rules"))

      assert Enum.map(Rules.builtin_files(), &elem(&1, 0)) ==
               @builtin_rules |> Map.keys() |> Enum.map(&(&1 <> ".md")) |> Enum.sort()

      opts = Keyword.merge(Keyword.delete(opts, :builtin_dir), env: %{"TACKLE_HOME" => root})
      assert %{rules: rules, warnings: []} = Rules.discover(opts)
      assert Enum.map(rules, & &1.id) == @builtin_rules |> Map.keys() |> Enum.sort()

      for rule <- rules do
        assert rule.path == "builtin:review/rules/#{rule.id}.md"
        refute File.exists?(rule.path)
      end
    end

    test "are overridden by user and project rules", %{opts: opts, project: project} do
      put(project, "off.md", "---\nid: injection\nstatus: suppressed\n---\n")
      put(project, "nil.md", rule("missing-nil-check", severity: "low"))

      rules = opts |> Keyword.delete(:builtin_dir) |> Rules.discover() |> Map.fetch!(:rules)

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
        opts |> Keyword.put(:builtin_rules, keep) |> Rules.discover() |> Map.fetch!(:rules)
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
      assert %{rules: rules, warnings: []} = Rules.discover(opts)

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

      assert %{rules: rules, warnings: []} = Rules.discover(opts)
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
      assert Rules.discover(ctx.opts).rules == []

      put(ctx.project, "parent.md", rule("parent"))
      child = Path.join(ctx.cwd, "lib/deep")
      File.mkdir_p!(child)
      child_opts = Keyword.put(ctx.opts, :cwd, child)
      assert [%Rule{id: "parent"}] = Rules.discover(child_opts).rules

      put(Path.join(child, ".tackle/review/rules"), "child.md", rule("child"))
      assert [%Rule{id: "child"}] = Rules.discover(child_opts).rules
    end

    test "reads flat Markdown files only", %{opts: opts, project: project} do
      put(project, "notes.txt", rule("text"))
      put(Path.join(project, "nested"), "nested.md", rule("nested"))
      put(project, "kept.md", rule("kept"))
      assert %{rules: [%Rule{id: "kept"}], warnings: []} = Rules.discover(opts)
    end

    test "skips invalid files with warnings", %{opts: opts, project: project} do
      put(project, "a-ok.md", rule("ok"))
      put(project, "b-duplicate.md", rule("ok"))
      put(project, "c-invalid.md", "---\nid: Not Valid\n---\nBody")
      put(project, "d-binary.md", <<0xFF, 0xFE>>)
      put(project, "e-large.md", rule("large", body: String.duplicate("x", 101)))

      assert %{rules: [%Rule{id: "ok"} = ok], warnings: warnings} =
               Rules.discover(Keyword.put(opts, :max_rule_bytes, 100))

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
               Rules.discover(Keyword.put(opts, :builtin_dir, missing))

      assert warning.path == missing
      assert warning.message =~ "could not list rule directory"

      assert %{rules: [], warnings: []} = Rules.discover(Keyword.put(opts, :builtin_dir, nil))
    end

    test "does not follow workspace symlinks to host files under a jail", ctx do
      secret = Path.join(ctx.home, "secret.md")
      put(ctx.home, "secret.md", rule("secret"))
      File.mkdir_p!(ctx.project)
      File.ln_s!(secret, Path.join(ctx.project, "leak.md"))

      assert Rules.discover(ctx.opts).rules |> Enum.map(& &1.id) == ["secret"]

      opts = Keyword.put(ctx.opts, :executor, FakeJail.new(ctx.cwd))
      assert Rules.discover(opts).rules == []
    end

    test "rejects invalid size options", %{opts: opts} do
      assert_raise ArgumentError, ~r/:max_rule_bytes must be a positive integer/, fn ->
        Rules.discover(Keyword.put(opts, :max_rule_bytes, 0))
      end
    end
  end

  describe "parse/3" do
    test "reads all fields and defaults applies_to and status" do
      assert %Rule{
               id: "x",
               category: :security,
               severity: :blocker,
               status: :active,
               applies_to: ["**/*"],
               body: "Check x.",
               path: "/rules/x.md",
               source: :project
             } = parse!(rule("x", category: "security", severity: "blocker"))
    end

    test "accepts the documented format with comments" do
      contents = """
      ---
      # A project rule.
      id: elixir-result-tuples
      category: correctness        # correctness | security | ...
      severity: medium             # blocker | high | medium | low
      applies_to: ["lib/**/*.ex"]  # globs
      status: active               # active | suppressed | retired
      ---
      Expected failures return result tuples.

      ## Bad
          raise "not found"  # a comment in the body stays
      """

      rule = parse!(contents)
      assert {rule.category, rule.severity, rule.status} == {:correctness, :medium, :active}
      assert rule.applies_to == ["lib/**/*.ex"]
      assert rule.body =~ "# a comment in the body stays"
    end

    test "parses flow, block, and scalar applies_to lists" do
      cases = [
        {~s(["lib/**/*.{ex,exs}", "test/**"]), ["lib/**/*.{ex,exs}", "test/**"]},
        {"['lib/**/*.{ex,exs}', 'src/#main.c']", ["lib/**/*.{ex,exs}", "src/#main.c"]},
        {"[lib/**, test/**]", ["lib/**", "test/**"]},
        {"\n  - \"lib/**\"\n  - test/**", ["lib/**", "test/**"]},
        {"lib/**/*.ex", ["lib/**/*.ex"]},
        {~s("{lib,test}/**/*.ex"), ["{lib,test}/**/*.ex"]},
        {"[{lib,test}/**/*.ex]", ["{lib,test}/**/*.ex"]}
      ]

      for {value, expected} <- cases do
        assert parse!(rule("x", extra: ["applies_to: " <> value])).applies_to == expected
      end
    end

    test "only active rules need a category, a severity, and a body" do
      assert parse_error("---\nid: x\nseverity: low\n---\nBody") ==
               "category is required for an active rule"

      assert parse_error("---\nid: x\ncategory: testing\n---\nBody") ==
               "severity is required for an active rule"

      assert parse_error(rule("x", body: "")) == "an active rule needs a body"

      for {status, atom} <- [{"suppressed", :suppressed}, {"retired", :retired}] do
        assert %Rule{status: ^atom, category: nil, severity: nil, body: ""} =
                 parse!("---\nid: x\nstatus: #{status}\n---\n")
      end

      assert %Rule{status: :suppressed, category: :testing} =
               parse!(rule("x", category: "testing", body: "", extra: ["status: suppressed"]))
    end

    test "reports invalid fields" do
      cases = [
        {"---\ncategory: testing\nseverity: low\n---\nBody", "id is required"},
        {"No front matter.", "id is required"},
        {"---\nid: x\n", "malformed front matter (unterminated frontmatter)"},
        {rule("x", extra: ["owner: me"]), "unknown front matter fields: owner"},
        {rule("x", category: "style"),
         ~s(category must be one of correctness, security, performance, maintainability, readability, testing, got: "style")},
        {rule("x", severity: "critical"),
         ~s(severity must be one of blocker, high, medium, low, got: "critical")},
        {rule("x", extra: ["status: draft"]),
         ~s(status must be one of active, suppressed, retired, got: "draft")},
        {rule("x", extra: ["applies_to: []"]), "applies_to must list at least one glob"},
        {rule("x", extra: ["applies_to: [1, 2]"]), "applies_to must contain only globs"},
        {rule("x", extra: ["applies_to: [\"lib/{a\"]"]), ~s(invalid glob "lib/{a": unbalanced {)},
        {rule("x", extra: ["applies_to: true"]), "applies_to must be a list of globs, got: true"},
        {rule("x", extra: ["applies_to: {lib,test}/**/*.ex"]), unreadable("applies_to")},
        {rule("x", extra: ["applies_to: [lib/**"]), unreadable("applies_to")},
        {rule("x", extra: ["applies_to: [lib/** # all of lib"]), unreadable("applies_to")},
        {rule("x", extra: ["applies_to: null"]), unreadable("applies_to")},
        {rule("x", extra: ["status: [suppressed"]), unreadable("status")},
        {"---\nid: x\ncategory: {testing\nstatus: suppressed\n---\n", unreadable("category")}
      ]

      for {contents, message} <- cases do
        assert parse_error(contents) == message, "for #{inspect(contents)}"
      end
    end
  end

  describe "resolve/3" do
    defp code_unit(path, old_path \\ nil),
      do: %{id: path <> "#1", kind: :code, path: path, old_path: old_path || path}

    defp rules(specs) do
      for {id, opts} <- specs do
        {source, opts} = Keyword.pop(opts, :source, :project)
        {:ok, rule} = Rules.parse(rule(id, opts), "/rules/#{id}.md", source)
        rule
      end
    end

    test "selects active rules whose globs match the unit's path or old path" do
      rules =
        rules([
          {"lib", extra: ["applies_to: [\"lib/**\"]"]},
          {"tests", extra: ["applies_to: [\"test/**\"]"]},
          {"off", extra: ["status: suppressed"]},
          {"gone", extra: ["status: retired"]},
          {"all", []}
        ])

      ids = &(Rules.resolve(rules, &1).rules |> Enum.map(fn rule -> rule.id end))
      assert ids.(code_unit("lib/a.ex")) == ["all", "lib"]
      assert ids.(code_unit("test/a_test.exs")) == ["all", "tests"]
      assert ids.(code_unit("src/a.ex", "lib/a.ex")) == ["all", "lib"]
      assert ids.(code_unit("README.md")) == ["all"]
    end

    test "the change-level unit matches any of the change's paths" do
      rules =
        rules([{"lib", extra: ["applies_to: lib/**"]}, {"web", extra: ["applies_to: web/**"]}])

      unit = %{id: "change", kind: :change, path: nil}

      assert %{rules: [%Rule{id: "lib"}]} =
               Rules.resolve(rules, unit, paths: ["lib/a.ex", "README.md"])

      assert %{rules: []} = Rules.resolve(rules, unit, paths: [])

      assert_raise ArgumentError, ~r/requires the :paths option/, fn ->
        Rules.resolve(rules, unit)
      end
    end

    test "orders by severity, then source, then id" do
      rules =
        rules([
          {"b-low", severity: "low", source: :project},
          {"a-high-builtin", severity: "high", source: :builtin},
          {"c-high-user", severity: "high", source: :user},
          {"z-high-project", severity: "high", source: :project},
          {"blocker", severity: "blocker", source: :builtin}
        ])

      assert Rules.resolve(rules, code_unit("a.ex")).rules |> Enum.map(& &1.id) ==
               ["blocker", "z-high-project", "c-high-user", "a-high-builtin", "b-low"]
    end

    test "caps the rule bytes per unit and warns about dropped rules" do
      rules =
        rules([
          {"first", severity: "blocker", body: String.duplicate("a", 60)},
          {"second", severity: "high", body: String.duplicate("b", 50)},
          {"third", severity: "low", body: String.duplicate("c", 40)}
        ])

      unit = code_unit("lib/a.ex")
      result = Rules.resolve(rules, unit, max_unit_bytes: 100)

      assert Enum.map(result.rules, & &1.id) == ["first", "third"]
      assert Enum.map(result.dropped, & &1.id) == ["second"]

      assert [%{path: "/rules/second.md", message: message}] = result.warnings

      assert message ==
               "rule second was not applied to lib/a.ex#1: the unit's rules exceed 100 bytes"

      assert %{rules: [_, _, _], dropped: [], warnings: []} = Rules.resolve(rules, unit)
    end

    test "rejects invalid size options" do
      assert_raise ArgumentError, ~r/:max_unit_bytes must be a positive integer/, fn ->
        Rules.resolve([], code_unit("a.ex"), max_unit_bytes: -1)
      end
    end
  end
end
