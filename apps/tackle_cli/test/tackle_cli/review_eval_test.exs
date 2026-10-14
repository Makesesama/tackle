defmodule Tackle.Bench.ReviewEvalTest do
  # The runner changes the working directory and application environment.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Tackle.Bench.ReviewEval.{Case, Report, Runner, Score, Variant}
  alias Tackle.Review.{Finding, Result}
  alias Tackle.Runtime.AgentSpec

  @git_env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_AUTHOR_NAME", "Review"},
    {"GIT_AUTHOR_EMAIL", "review@example.com"},
    {"GIT_COMMITTER_NAME", "Review"},
    {"GIT_COMMITTER_EMAIL", "review@example.com"}
  ]

  defmodule Adapter do
    @moduledoc false
    # Scripted provider: the detector reports the unguarded access on
    # lib/a.ex line 3, the verifier confirms it, the scorer answers 0.9.
    # Every call is reported to the test with its stage, system prompt, and
    # tool names.

    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "review-eval"

    @impl true
    def models, do: ["fake"]

    @impl true
    def model_info(_model), do: %{context_window: 100_000, max_output_tokens: 1_000}

    @impl true
    def generate(schema, opts) do
      messages = Keyword.get(opts, :messages, [])
      system = Keyword.get(opts, :system, "")
      answered? = Enum.any?(messages, &(&1.role == :tool))
      prompt = Enum.find_value(messages, "", &(&1.role == :user && &1.content))
      stage = stage(schema, system)
      tools = opts |> Keyword.get(:tools, []) |> Enum.map(&tool_name/1)

      text = Enum.map_join(messages, "\n", &inspect(&1.content))

      send(
        Application.fetch_env!(:tackle_cli, :review_eval_test_pid),
        {:llm, stage, system, tools, text}
      )

      data =
        case {stage, answered?} do
          {:scorer, _answered?} -> %{"scores" => [%{"id" => "C1", "confidence" => 0.9}]}
          {_stage, true} -> %{"content" => "done", "tool_calls" => []}
          {:detector, false} -> report(prompt)
          {:verifier, false} -> verdict()
          {:root, false} -> %{"content" => "unused", "tool_calls" => []}
        end

      {:ok,
       %{
         data: data,
         usage: %{input_tokens: 10, cache_read_tokens: 4, output_tokens: 5},
         model: "fake"
       }}
    end

    defp tool_name(%{name: name}), do: name
    defp tool_name(%{"name" => name}), do: name
    defp tool_name(other), do: inspect(other)

    defp stage(schema, _system) when schema != nil, do: :scorer

    defp stage(nil, system) do
      cond do
        system =~ "## Review detector assignment" -> :detector
        system =~ "## Review verifier assignment" -> :verifier
        true -> :root
      end
    end

    defp report(prompt) do
      findings =
        if prompt =~ ~s(<unit id="lib/a.ex#1">) do
          [
            %{
              "title" => "Guard against a missing key",
              "category" => "correctness",
              "severity" => "high",
              "blocking" => true,
              "confidence" => 0.8,
              "rule_id" => nil,
              "location" => %{
                "path" => "lib/a.ex",
                "side" => "new",
                "start_line" => 3,
                "end_line" => 3
              },
              "trigger" => "g/1 is called with a map without :key",
              "body" => "map.key raises KeyError for such maps.",
              "suggestion" => nil
            }
          ]
        else
          []
        end

      tool_call("report_findings", %{"findings" => findings})
    end

    defp verdict do
      tool_call("report_verdict", %{
        "finding" => "F1",
        "verdict" => "confirmed",
        "evidence" => "lib/a.ex:3 reads map.key without a check."
      })
    end

    defp tool_call(name, arguments) do
      %{
        "content" => nil,
        "tool_calls" => [
          %{
            "id" => "call-#{System.unique_integer([:positive])}",
            "name" => name,
            "arguments" => arguments
          }
        ]
      }
    end
  end

  setup do
    base =
      Path.join(System.tmp_dir!(), "tackle-review-eval-#{System.unique_integer([:positive])}")

    repo = Path.join(base, "repo")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(base) end)

    git(repo, ["init", "-q", "-b", "main"])
    write(repo, "AGENTS.md", "Project guidance: AGENTS-MARKER\n")
    write(repo, "lib/a.ex", "defmodule A do\n  def f(x), do: x\nend\n")
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-q", "--no-verify", "-m", "initial"])

    write(
      repo,
      "lib/a.ex",
      "defmodule A do\n  def f(x), do: x\n  def g(map), do: Map.get(map, :key)\nend\n"
    )

    git(repo, ["commit", "-q", "--no-verify", "-am", "add g"])
    commit = repo |> git(["rev-parse", "HEAD"]) |> String.trim()
    # A later fix and a tag that a checkout of `commit` must not lead to.
    write(repo, "lib/a.ex", "defmodule A do\n  def f(x), do: x\nend\n")
    git(repo, ["commit", "-q", "--no-verify", "-am", "FUTURE-FIX remove g"])
    git(repo, ["tag", "v-future"])

    kase = %Case{
      id: "seed-key",
      commit: commit,
      edits: [%{path: "lib/a.ex", find: "Map.get(map, :key)", replace: "map.key"}],
      issues: [
        %{
          id: "unguarded",
          path: "lib/a.ex",
          anchor: "do: map.key",
          lines: 1,
          also: [],
          keywords: [],
          description: nil
        }
      ]
    }

    {:ok, base: base, repo: repo, commit: commit, case: kase}
  end

  describe "Case.parse/1 and load_dir/1" do
    test "parses a case with defaults" do
      assert {:ok, %Case{} = kase} =
               Case.parse(%{
                 "id" => "c",
                 "commit" => "abc",
                 "issues" => [
                   %{"id" => "i", "path" => "a.ex", "anchor" => "x", "keywords" => ["KeyError"]}
                 ]
               })

      assert kase.base == nil
      assert kase.edits == []
      assert [%{lines: 1, keywords: ["keyerror"]}] = kase.issues
    end

    test "rejects invalid cases" do
      assert {:error, {:invalid_case, "id must be lowercase letters" <> _}} =
               Case.parse(%{"id" => "../x", "commit" => "a", "issues" => []})

      assert {:error, {:invalid_case, "issues is missing"}} =
               Case.parse(%{"id" => "c", "commit" => "a"})

      assert {:error, {:invalid_case, "issues must not be empty"}} =
               Case.parse(%{"id" => "c", "commit" => "a", "issues" => []})

      assert {:error, {:invalid_case, "replace is missing"}} =
               Case.parse(%{
                 "id" => "c",
                 "commit" => "a",
                 "edits" => [%{"path" => "a", "find" => "b"}],
                 "issues" => [%{"id" => "i", "path" => "a", "anchor" => "x"}]
               })

      assert {:error, {:invalid_case, "lines must be a positive integer"}} =
               Case.parse(%{
                 "id" => "c",
                 "commit" => "a",
                 "issues" => [%{"id" => "i", "path" => "a", "anchor" => "x", "lines" => 0}]
               })
    end

    test "loads a directory and refuses duplicate ids", %{base: base} do
      dir = Path.join(base, "cases")
      File.mkdir_p!(dir)
      json = ~s({"id": "c", "commit": "a", "issues": [{"id": "i", "path": "a", "anchor": "x"}]})
      File.write!(Path.join(dir, "one.json"), json)
      assert {:ok, [%Case{id: "c", source: source}]} = Case.load_dir(dir)
      assert source == Path.join(dir, "one.json")

      File.write!(Path.join(dir, "two.json"), json)
      assert {:error, {:duplicate_case, "c"}} = Case.load_dir(dir)

      File.write!(Path.join(dir, "bad.json"), "{")
      assert {:error, {:invalid_case, _path, "invalid JSON: " <> _}} = Case.load_dir(dir)

      assert {:error, {:no_cases, _dir}} = Case.load_dir(Path.join(base, "empty"))
    end

    test "the shipped cases are valid" do
      assert {:ok, [_ | _] = cases} =
               Case.load_dir(Path.expand("../../bench/review_eval/cases", __DIR__))

      assert Enum.all?(cases, &(&1.issues != []))
    end
  end

  describe "Case.locate_in/2" do
    defp place(anchor, lines \\ 1), do: %{path: "a.ex", anchor: anchor, lines: lines}

    test "locates single- and multi-line anchors" do
      text = "one\ntwo\nthree\nfour\n"

      assert {:ok, %{path: "a.ex", start_line: 2, end_line: 2}} =
               Case.locate_in(place("wo"), text)

      assert {:ok, %{start_line: 2, end_line: 3}} = Case.locate_in(place("two\nthr", 2), text)
      assert {:ok, %{start_line: 4, end_line: 5}} = Case.locate_in(place("four", 9), text)
    end

    test "requires exactly one occurrence" do
      assert {:error, {:anchor_not_found, "five"}} = Case.locate_in(place("five"), "one\n")
      assert {:error, {:anchor_ambiguous, "o"}} = Case.locate_in(place("o"), "one\ntwo\n")
    end
  end

  describe "Case.prepare/3" do
    test "seeds the commit in a scratch clone and locates the issues", ctx do
      workdir = Path.join(ctx.base, "work")
      assert {:ok, prepared} = Case.prepare(ctx.case, ctx.repo, workdir)

      assert prepared.worktree == Path.join(workdir, Case.checkout_name(ctx.case))
      assert File.read!(Path.join(prepared.worktree, "lib/a.ex")) =~ "do: map.key"

      assert [%{id: "unguarded", locations: [%{path: "lib/a.ex", start_line: 3, end_line: 3}]}] =
               prepared.issues

      assert prepared.base_sha == String.trim(git(ctx.repo, ["rev-parse", "#{ctx.commit}~1"]))
      refute prepared.head_sha == ctx.commit
      assert prepared.range == "#{prepared.base_sha}..#{prepared.head_sha}"
      # The repository itself is untouched.
      assert git(ctx.repo, ["status", "--porcelain"]) == ""

      assert :ok = Case.cleanup(prepared)
      refute File.exists?(prepared.worktree)
    end

    test "leaves nothing in the checkout that names the seed or leads to later commits", ctx do
      assert {:ok, prepared} = Case.prepare(ctx.case, ctx.repo, Path.join(ctx.base, "work"))
      checkout = prepared.worktree

      refute checkout =~ ctx.case.id
      # The seed is amended into the case's commit, keeping its message.
      assert git(checkout, ["log", "--format=%s", "#{prepared.range}"]) == "add g\n"
      assert git(checkout, ["show", "--format=", "HEAD"]) =~ "+  def g(map), do: map.key"
      # No branch, tag, remote, or reflog leads to the later fix.
      refute git(checkout, ["log", "--all", "--format=%s"]) =~ "FUTURE-FIX"
      assert git(checkout, ["for-each-ref"]) == ""
      assert git(checkout, ["remote"]) == ""
      refute git(checkout, ["reflog", "--all"]) =~ "FUTURE-FIX"
    end

    test "reset undoes changes a run made to the checkout", ctx do
      assert {:ok, prepared} = Case.prepare(ctx.case, ctx.repo, Path.join(ctx.base, "work"))
      File.write!(Path.join(prepared.worktree, "lib/a.ex"), "changed")
      File.write!(Path.join(prepared.worktree, "stray.txt"), "x")

      assert :ok = Case.reset(prepared)
      assert File.read!(Path.join(prepared.worktree, "lib/a.ex")) =~ "do: map.key"
      refute File.exists?(Path.join(prepared.worktree, "stray.txt"))
    end

    test "locates the other places an issue may be reported at", ctx do
      [issue] = ctx.case.issues

      kase = %{
        ctx.case
        | issues: [%{issue | also: [%{path: "lib/a.ex", anchor: "def f(x)", lines: 1}]}]
      }

      assert {:ok, prepared} = Case.prepare(kase, ctx.repo, Path.join(ctx.base, "work"))
      assert [%{locations: [%{start_line: 3}, %{start_line: 2}]}] = prepared.issues

      bad = %{
        ctx.case
        | issues: [%{issue | also: [%{path: "lib/a.ex", anchor: "nope", lines: 1}]}]
      }

      assert {:error,
              {:prepare_failed, "seed-key", {:anchor_not_found, "unguarded", "lib/a.ex", "nope"}}} =
               Case.prepare(bad, ctx.repo, Path.join(ctx.base, "work"))
    end

    test "refuses to replace a directory it did not create", ctx do
      workdir = Path.join(ctx.base, "work")
      foreign = Path.join(workdir, Case.checkout_name(ctx.case))
      File.mkdir_p!(foreign)
      File.write!(Path.join(foreign, "keep.txt"), "mine")

      assert {:error, {:prepare_failed, "seed-key", {:not_a_checkout, ^foreign}}} =
               Case.prepare(ctx.case, ctx.repo, workdir)

      assert File.read!(Path.join(foreign, "keep.txt")) == "mine"
    end

    test "fails on an edit that does not apply and leaves nothing behind", ctx do
      workdir = Path.join(ctx.base, "work")
      kase = %{ctx.case | edits: [%{path: "lib/a.ex", find: "absent", replace: "x"}]}

      assert {:error, {:prepare_failed, "seed-key", {:edit_not_found, "lib/a.ex", "absent"}}} =
               Case.prepare(kase, ctx.repo, workdir)

      refute File.exists?(Path.join(workdir, Case.checkout_name(kase)))
    end

    test "fails on an unknown commit", ctx do
      kase = %{ctx.case | commit: String.duplicate("0", 40)}

      assert {:error, {:prepare_failed, "seed-key", {:unknown_revision, _rev}}} =
               Case.prepare(kase, ctx.repo, Path.join(ctx.base, "work"))
    end
  end

  describe "Score" do
    defp finding(path, side, first, last, text \\ "Guard against a missing key") do
      %Finding{
        title: text,
        category: :correctness,
        severity: :high,
        blocking: true,
        confidence: 0.8,
        location: %{path: path, side: side, start_line: first, end_line: last},
        trigger: "t",
        body: "b"
      }
    end

    defp located(id, first, last, keywords \\ []),
      do: %{
        id: id,
        locations: [%{path: "a.ex", start_line: first, end_line: last}],
        keywords: keywords
      }

    test "a testing finding never matches a bug" do
      issue = located("i", 10, 10)
      refute Score.matches?(%{finding("a.ex", :new, 10, 10) | category: :testing}, issue, 3)
    end

    test "matches any of an issue's locations" do
      issue = %{
        id: "i",
        keywords: [],
        locations: [
          %{path: "a.ex", start_line: 10, end_line: 10},
          %{path: "b.ex", start_line: 50, end_line: 51}
        ]
      }

      assert Score.matches?(finding("b.ex", :new, 51, 51), issue, 0)
      refute Score.matches?(finding("b.ex", :new, 10, 10), issue, 0)
    end

    test "matches by file, new side, and overlap within the slack" do
      issue = located("i", 10, 11)
      assert Score.matches?(finding("a.ex", :new, 13, 14), issue, 3)
      assert Score.matches?(finding("a.ex", :new, 4, 7), issue, 3)
      refute Score.matches?(finding("a.ex", :new, 15, 16), issue, 3)
      refute Score.matches?(finding("a.ex", :old, 10, 10), issue, 3)
      refute Score.matches?(finding("b.ex", :new, 10, 10), issue, 3)
    end

    test "requires one keyword when the issue has keywords" do
      issue = located("i", 10, 10, ["keyerror", "nil"])
      assert Score.matches?(finding("a.ex", :new, 10, 10, "Raises KeyError"), issue, 0)
      refute Score.matches?(finding("a.ex", :new, 10, 10, "Rename"), issue, 0)
    end

    test "attributes each issue to the first stage that has a match" do
      result = %Result{
        blocking: [finding("a.ex", :new, 1, 1), finding("a.ex", :new, 50, 50)],
        optional: [],
        rejected: [%{finding: finding("a.ex", :new, 20, 20), evidence: "no"}],
        dropped: [%{finding: finding("a.ex", :new, 30, 30), reason: :below_threshold}],
        summary: %{}
      }

      issues = [
        located("shown", 1, 1),
        located("rejected", 20, 20),
        located("dropped", 30, 30),
        located("missed", 40, 40)
      ]

      score = Score.score(result, issues, slack: 0)

      assert score.per_issue == [
               %{id: "shown", outcome: :shown},
               %{id: "rejected", outcome: :rejected},
               %{id: "dropped", outcome: {:dropped, :below_threshold}},
               %{id: "missed", outcome: :missed}
             ]

      assert %{issues: 4, found: 1, detected: 3, shown: 2, extra: 1} = score
    end
  end

  describe "Variant" do
    defp spec(tools \\ [Tackle.Tools.Read, Tackle.Tools.Bash, Tackle.Tools.ReportFindings]) do
      %AgentSpec{
        name: "review-detector",
        config: %Tackle.Config{
          providers: [],
          model_ref: "review-eval/fake",
          llm: nil,
          tools: tools,
          system_prompt: "full prompt",
          max_iterations: 40,
          context: %{cwd: "/work"}
        }
      }
    end

    test "the defaults exist and selection keeps order" do
      variants = Variant.builtin()
      assert {:ok, selected} = Variant.select(variants, Variant.default_names())
      assert Enum.map(selected, & &1.name) == Variant.default_names()

      assert {:error, {:unknown_variants, ["nope"]}} =
               Variant.select(variants, ["baseline", "nope"])

      refute Enum.any?(variants, &(&1.name == "cheap-detector"))

      assert %Variant{review_opts: [models: %{detector: "p/m"}]} =
               Enum.find(Variant.builtin(cheap_model: "p/m"), &(&1.name == "cheap-detector"))
    end

    test "applies step limits, tool filters, and lean prompts" do
      assert {:ok, %AgentSpec{config: config}} =
               Variant.apply_stage(spec(), :detector, %{
                 max_iterations: 3,
                 tools: ["report_findings"],
                 prompt: {:lean, "## Assignment"}
               })

      assert config.max_iterations == 3
      assert config.tools == [Tackle.Tools.ReportFindings]
      assert config.system_prompt == "## Assignment\n\nCurrent working directory: /work"

      assert {:ok, %AgentSpec{config: config}} =
               Variant.apply_stage(spec(), :detector, %{prompt: {:lean, :builtin}})

      assert config.system_prompt =~ "## Review detector assignment"
      refute config.system_prompt =~ "full prompt"

      assert {:ok, %AgentSpec{config: unchanged}} = Variant.apply_stage(spec(), :verifier, %{})
      assert unchanged == spec().config
    end

    test "builds the AGENTS.md prompt without skills" do
      build = fn opts ->
        send(self(), {:build, opts})
        {:ok, "built"}
      end

      assert {:ok, %AgentSpec{config: %{system_prompt: "built"}}} =
               Variant.apply_stage(spec(), :verifier, %{prompt: {:agents, :builtin}},
                 build_system_prompt: build,
                 home: "/home"
               )

      assert_received {:build, opts}
      assert opts[:base] =~ "## Review verifier assignment"
      assert opts[:cwd] == "/work"
      assert opts[:home] == "/home"
      assert opts[:skills] == []
    end

    test "resolves profile resolvers and describes the stages" do
      profiles = %{
        "review-detector" => fn -> {:ok, spec()} end,
        "review-verifier" => %{spec() | name: "review-verifier"},
        "other" => :untouched
      }

      variant = Enum.find(Variant.builtin(), &(&1.name == "single-call"))
      assert {:ok, applied, stats} = Variant.profiles(variant, profiles)

      assert %AgentSpec{config: %{tools: [Tackle.Tools.ReportFindings]}} =
               applied["review-detector"]

      assert applied["other"] == :untouched
      assert stats.detector.tools == ["report_findings"]
      assert stats.detector.max_iterations == 3
      assert stats.verifier.max_iterations == 40

      assert {:error,
              {:variant_failed, "single-call", :detector, {:missing_profile, "review-detector"}}} =
               Variant.profiles(variant, Map.delete(profiles, "review-detector"))
    end
  end

  describe "Report" do
    defp record(variant, kase, found, tokens, status \\ "ok") do
      %{
        "variant" => variant,
        "case" => kase,
        "status" => status,
        "issues" => 1,
        "review_ms" => 2_000,
        "score" => %{"issues" => 1, "found" => found, "detected" => found, "extra" => 1},
        "usage" => %{
          "input_tokens" => tokens,
          "cache_read_tokens" => tokens,
          "output_tokens" => 10
        },
        "stages" => %{"detector" => %{"runs" => 2}, "verifier" => %{"runs" => 1}},
        "failed_units" => 0,
        "incomplete_units" => 0
      }
    end

    test "summarizes per variant and renders tables relative to the baseline" do
      records = [
        record("baseline", "c1", 1, 1_000),
        record("baseline", "c2", 0, 3_000),
        record("lean", "c1", 1, 500),
        record("lean", "c2", 1, 500),
        Map.merge(record("lean", "c3", 0, 0), %{"status" => "error", "error" => "boom"})
      ]

      [baseline, lean] = Report.summarize(records)

      assert %{variant: "baseline", runs: 2, errors: 0, found: 1, issues: 2, recall: 0.5} =
               baseline

      assert baseline.prompt_tokens == 4_000.0
      # The failed run counts its issue as missed.
      assert %{variant: "lean", runs: 3, errors: 1, found: 2, issues: 3} = lean
      assert_in_delta lean.recall, 2 / 3, 0.001
      assert lean.prompt_tokens == 1_000.0

      table = Report.table([baseline, lean])
      assert table =~ "| baseline | 2 | 0 | 1/2 (50%) |"
      assert table =~ "| lean | 3 | 1 | 2/3 (67%) |"
      assert table =~ "1.0k (25%)"

      cases = Report.case_table(records)
      assert cases =~ "| case | baseline | lean |"
      assert cases =~ "| c2 | 0/1 | 1/1 |"
      assert cases =~ "| c3 | – | 0/1 (1 err) |"
    end
  end

  describe "Runner" do
    setup ctx do
      home = Path.join(ctx.base, "home")
      File.mkdir_p!(home)
      previous_home = System.get_env("TACKLE_HOME")
      previous_adapters = Application.get_env(:tackle, :adapters)
      System.put_env("TACKLE_HOME", home)
      Application.put_env(:tackle, :adapters, [Adapter])
      Application.put_env(:tackle_cli, :review_eval_test_pid, self())

      on_exit(fn ->
        if previous_home,
          do: System.put_env("TACKLE_HOME", previous_home),
          else: System.delete_env("TACKLE_HOME")

        if previous_adapters,
          do: Application.put_env(:tackle, :adapters, previous_adapters),
          else: Application.delete_env(:tackle, :adapters)

        Application.delete_env(:tackle_cli, :review_eval_test_pid)
      end)

      :ok
    end

    test "check describes the prepared cases without a model", ctx do
      workdir = Path.join(ctx.base, "work")

      assert {:ok, [description]} =
               Runner.check(
                 cases: [ctx.case],
                 repo: ctx.repo,
                 workdir: workdir,
                 log: fn _ -> :ok end
               )

      assert %{case: "seed-key", files: 1, uncovered: [], issues: ["unguarded lib/a.ex:3-3"]} =
               description

      refute File.exists?(Path.join(workdir, Case.checkout_name(ctx.case)))
      refute_received {:llm, _stage, _system, _tools, _text}
    end

    test "check reports issues that are not on changed lines", ctx do
      kase = %{ctx.case | issues: [%{hd(ctx.case.issues) | id: "context", anchor: "def f(x)"}]}

      assert {:ok, [%{uncovered: ["context"]}]} =
               Runner.check(
                 cases: [kase],
                 repo: ctx.repo,
                 workdir: Path.join(ctx.base, "work"),
                 log: fn _ -> :ok end
               )
    end

    test "reviews each case with each variant and records the results", ctx do
      out = Path.join(ctx.base, "results.jsonl")
      {:ok, variants} = Variant.select(Variant.builtin(), ["baseline", "single-call", "lean"])
      cwd = File.cwd!()

      assert {:ok, records} =
               Runner.run(
                 cases: [ctx.case],
                 variants: variants,
                 repo: ctx.repo,
                 workdir: Path.join(ctx.base, "work"),
                 out: out,
                 model: "review-eval/fake",
                 log: fn _ -> :ok end
               )

      assert File.cwd!() == cwd
      assert Enum.map(records, & &1["variant"]) == ["baseline", "single-call", "lean"]

      for record <- records do
        assert %{"status" => "ok", "case" => "seed-key", "repeat" => 1} = record
        assert %{"found" => 1, "issues" => 1, "extra" => 0} = record["score"]
        assert record["usage"]["input_tokens"] > 0
        assert record["stages"]["detector"]["runs"] >= 1
        assert [%{"title" => "Guard against a missing key"}] = record["result"]["blocking"]
      end

      [baseline, single, lean] = records
      assert "read" in baseline["profiles"]["detector"]["tools"]
      assert single["profiles"]["detector"]["tools"] == ["report_findings"]
      assert single["profiles"]["detector"]["max_iterations"] == 3

      assert lean["profiles"]["detector"]["system_prompt_bytes"] <
               baseline["profiles"]["detector"]["system_prompt_bytes"]

      assert out |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1) ==
               records

      refute File.exists?(Path.join([ctx.base, "work", Case.checkout_name(ctx.case)]))
      assert baseline["settings"]["models"]["detector"] == "review-eval/fake"

      # Nothing the models were sent names the case.
      calls = collect_calls()
      assert calls != []

      refute Enum.any?(calls, fn {_stage, system, _tools, text} ->
               system <> text =~ "seed-key"
             end)

      # What the detector runs were actually sent, variant by variant.
      detector_calls = for {:detector, system, tools, _text} <- calls, do: {system, tools}

      assert Enum.any?(detector_calls, fn {system, tools} ->
               system =~ "AGENTS-MARKER" and "read" in tools
             end)

      assert Enum.any?(detector_calls, fn {system, tools} ->
               tools == ["report_findings"] and system =~ "You have no tools to read other code" and
                 not (system =~ "AGENTS-MARKER")
             end)

      assert Enum.any?(detector_calls, fn {system, tools} ->
               "read" in tools and not (system =~ "AGENTS-MARKER") and
                 not (system =~ "You have no tools")
             end)
    end

    test "records a failed run and keeps going", ctx do
      {:ok, variants} = Variant.select(Variant.builtin(), ["baseline"])

      assert {:ok, [record]} =
               Runner.run(
                 cases: [ctx.case],
                 variants: variants,
                 repo: ctx.repo,
                 workdir: Path.join(ctx.base, "work"),
                 model: "review-eval/missing",
                 log: fn _ -> :ok end
               )

      assert %{"status" => "error", "error" => "scope: " <> message} = record
      assert message =~ "review-eval/missing"
    end

    test "a crashing review is a failed run, and the next run still happens", ctx do
      {:ok, variants} = Variant.select(Variant.builtin(), ["baseline", "lean"])
      cwd = File.cwd!()

      run_review = fn change, opts ->
        if Enum.any?(opts[:profiles]["review-detector"].config.tools, &(&1.name() == "read")) and
             opts[:profiles]["review-detector"].config.system_prompt =~ "AGENTS-MARKER",
           do: raise("boom"),
           else: Tackle.Review.run(change, opts)
      end

      assert {:ok, records} =
               Runner.run(
                 cases: [ctx.case],
                 variants: variants,
                 repo: ctx.repo,
                 workdir: Path.join(ctx.base, "work"),
                 model: "review-eval/fake",
                 run_review: run_review,
                 log: fn _ -> :ok end
               )

      assert File.cwd!() == cwd
      by_variant = Map.new(records, &{&1["variant"], &1})
      assert %{"status" => "error", "error" => "crashed: " <> reason} = by_variant["baseline"]
      assert reason =~ "boom"
      assert %{"status" => "ok"} = by_variant["lean"]
      refute File.exists?(Path.join([ctx.base, "work", Case.checkout_name(ctx.case)]))
    end

    test "a review over the limit is given up", ctx do
      {:ok, variants} = Variant.select(Variant.builtin(), ["baseline"])
      test = self()

      run_review = fn _change, _opts ->
        send(test, {:review_pid, self()})
        Process.sleep(:infinity)
      end

      assert {:ok, [record]} =
               Runner.run(
                 cases: [ctx.case],
                 variants: variants,
                 repo: ctx.repo,
                 workdir: Path.join(ctx.base, "work"),
                 model: "review-eval/fake",
                 run_review: run_review,
                 limit_ms: 100,
                 log: fn _ -> :ok end
               )

      assert %{"status" => "error", "error" => "gave up after 0s"} = record
      assert_received {:review_pid, pid}
      refute Process.alive?(pid)
    end

    test "rotates the variant order between cases and repeats" do
      assert Runner.rotate([:a, :b, :c], 0) == [:a, :b, :c]
      assert Runner.rotate([:a, :b, :c], 1) == [:b, :c, :a]
      assert Runner.rotate([:a, :b, :c], 4) == [:b, :c, :a]
      assert Runner.rotate([], 2) == []
    end
  end

  defp collect_calls(acc \\ []) do
    receive do
      {:llm, stage, system, tools, text} -> collect_calls([{stage, system, tools, text} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp write(repo, path, contents) do
    full = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
  end

  defp git(dir, args) do
    case System.cmd("git", args, cd: dir, env: @git_env, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end
end
