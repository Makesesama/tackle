defmodule Tackle.Review.RulesTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.Rules
  alias Tackle.Review.Rules.Rule

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

  describe "load/2" do
    test "builtin/1 returns the embedded rules without reading any files" do
      assert %{rules: rules, warnings: []} = Rules.builtin()
      assert Enum.map(rules, & &1.id) == Rules.builtin_ids()
      assert Enum.all?(rules, &(&1.source == :builtin))

      assert %{rules: [%{id: "injection"}], warnings: []} = Rules.builtin(["injection"])
      assert %{rules: []} = Rules.builtin([])
      # Unknown ids select nothing, as in discovery.
      assert %{rules: []} = Rules.builtin(["no-such-rule"])
    end

    test "merges sources by precedence and keeps the first id within a source" do
      sources = [
        {:user, [{"/u/a.md", {:ok, rule("shared", severity: "low")}}]},
        {:project,
         [
           {"/p/a.md", {:ok, rule("shared", severity: "high")}},
           {"/p/b.md", {:ok, rule("shared", severity: "blocker")}},
           {"/p/notes.txt", {:ok, "not a rule"}}
         ]}
      ]

      assert %{rules: [%Rule{id: "shared", severity: :high, source: :project}], warnings: [w]} =
               Rules.load(sources, builtin: false)

      assert w == %{path: "/p/b.md", message: "rule id shared is already defined in /p/a.md"}
    end

    test "turns read errors into warnings and applies the size limit" do
      sources = [
        {:project,
         [
           {"/p", {:error, "could not list rule directory (eacces)"}},
           {"/p/big.md", {:ok, rule("big", body: String.duplicate("x", 200))}},
           {"/p/ok.md", {:ok, rule("ok")}}
         ]}
      ]

      assert %{rules: [%Rule{id: "ok"}], warnings: [listing, size]} =
               Rules.load(sources, builtin: false, max_rule_bytes: 100)

      assert listing == %{path: "/p", message: "could not list rule directory (eacces)"}
      assert size.path == "/p/big.md"
      assert size.message =~ "the limit is 100"
    end

    test "selects built-in rules, embedded or the host's own" do
      ids = fn discovery -> Enum.map(discovery.rules, &{&1.id, &1.source}) end
      project = {:project, [{"/p/inj.md", {:ok, rule("injection", severity: "low")}}]}

      assert ids.(Rules.load([project], builtin_rules: ["secret-exposure"])) == [
               {"injection", :project},
               {"secret-exposure", :builtin}
             ]

      host_builtin = {:builtin, [{"/b/a.md", {:ok, rule("a")}}, {"/b/b.md", {:ok, rule("b")}}]}

      assert ids.(Rules.load([host_builtin], builtin: false, builtin_rules: ["b"])) == [
               {"b", :builtin}
             ]
    end
  end

  describe "read_tree/3" do
    alias Tackle.Review.Test.GitRepo

    test "reads the project's rule files at a revision, not from the working tree" do
      dir = GitRepo.init("rules")
      GitRepo.write(dir, %{".tackle/review/rules/a.md" => rule("base-rule"), "lib/a.ex" => ""})
      base = GitRepo.commit(dir, "base")

      GitRepo.write(dir, %{
        ".tackle/review/rules/a.md" => rule("head-rule"),
        ".tackle/review/rules/readme.txt" => "ignored"
      })

      GitRepo.commit(dir, "head")
      GitRepo.write(dir, %{".tackle/review/rules/a.md" => rule("uncommitted")})

      assert {:ok, [{".tackle/review/rules/a.md", {:ok, contents}}]} = Rules.read_tree(dir, base)

      assert %{rules: [%Rule{id: "base-rule"}]} =
               Rules.load([{:project, [{".tackle/review/rules/a.md", {:ok, contents}}]}],
                 builtin: false
               )

      assert {:ok, [{_path, {:ok, head}}]} = Rules.read_tree(dir, "HEAD")
      assert head =~ "id: head-rule"
    end

    test "reports large files and unknown revisions" do
      dir = GitRepo.init("rules")

      GitRepo.write(dir, %{
        ".tackle/review/rules/big.md" => rule("big", body: String.duplicate("x", 3_000))
      })

      GitRepo.commit(dir, "base")

      assert {:ok, [{_path, {:error, message}}]} =
               Rules.read_tree(dir, "HEAD", max_rule_bytes: 100)

      assert message == "file is larger than #{Rules.max_file_bytes(max_rule_bytes: 100)} bytes"
      assert Rules.max_file_bytes(max_rule_bytes: 100) == 1_124
      assert Rules.max_file_bytes() == 5_120

      # A revision without rule files has none.
      GitRepo.write(dir, %{"lib/a.ex" => ""})
      File.rm_rf!(Path.join(dir, ".tackle"))
      GitRepo.commit(dir, "no rules")
      assert {:ok, []} = Rules.read_tree(dir, "HEAD")

      assert {:error, {:unknown_revision, "nope"}} = Rules.read_tree(dir, "nope")
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
        {"[{lib,test}/**/*.ex]", ["{lib,test}/**/*.ex"]},
        {"lib/**, test/*.{ex,exs}", ["lib/**", "test/*.{ex,exs}"]}
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
        {rule("x", extra: [~s(applies_to: ["lib/**" test/**])]),
         ~s(applies_to must be a list of globs, got: "[\\"lib/**\\" test/**]")},
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
