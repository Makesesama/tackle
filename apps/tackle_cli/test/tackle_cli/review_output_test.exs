defmodule Tackle.CLI.Output.ReviewTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.Output
  alias Tackle.CLI.Output.Review, as: ReviewOutput
  alias Tackle.CLI.Output.ReviewProgress
  alias Tackle.CLI.Review
  alias Tackle.Lib.Usage
  alias Tackle.Review.{Change, Diff, Finding, Result}

  defp change(overrides \\ []) do
    {:ok, diff} = Diff.parse("")

    struct!(
      %Change{
        cwd: "/repo",
        root: "/repo",
        mode: :branch,
        base_ref: "main",
        base_sha: String.duplicate("a", 40),
        head_sha: :worktree,
        diff: diff
      },
      overrides
    )
  end

  defp finding(overrides \\ []) do
    struct!(
      %Finding{
        title: "Guard against a missing key",
        category: :correctness,
        severity: :high,
        blocking: true,
        confidence: 0.9,
        rule_id: "missing-nil-check",
        location: %{path: "lib/a.ex", side: :new, start_line: 3, end_line: 3},
        trigger: "g/1 is called with a map\nwithout :key",
        body: "map.key raises KeyError for such maps.",
        suggestion: nil,
        support: 1,
        verdict: :confirmed,
        fingerprint: "fp-nil-check"
      },
      overrides
    )
  end

  defp optional_finding do
    finding(
      title: "Cover the new clause with a test",
      category: :testing,
      severity: :low,
      blocking: false,
      confidence: 0.6,
      rule_id: nil,
      location: %{path: "lib/b.ex", side: :old, start_line: 7, end_line: 9},
      trigger: "Any future change to h/0",
      verdict: :uncertain,
      fingerprint: "fp-test"
    )
  end

  defp summary(overrides \\ %{}) do
    Map.merge(
      %{
        profile: :default,
        samples: 1,
        units: 3,
        files: ["lib/a.ex", "lib/b.ex"],
        skipped: [%{path: "mix.lock", reason: :lock_file}],
        failed_units: [],
        incomplete_units: [],
        detected: 3,
        candidates: 2,
        confirmed: 1,
        uncertain: 1,
        rejected: 1,
        verification_failures: [],
        scoring_failures: [],
        blocking: 1,
        optional: 1,
        verdict: :blocking,
        warnings: []
      },
      overrides
    )
  end

  defp result(overrides \\ []) do
    struct!(
      %Result{
        blocking: [finding()],
        optional: [optional_finding()],
        rejected: [
          %{finding: finding(title: "Rename f", fingerprint: "fp-rename"), evidence: "Style."}
        ],
        dropped: [%{finding: finding(fingerprint: "fp-low"), reason: :low_confidence}],
        summary: summary(),
        usage: %Usage{input_tokens: 120, output_tokens: 30, raw: %{"provider" => "detail"}}
      },
      overrides
    )
  end

  defp text(data), do: data |> Owl.Data.untag() |> IO.iodata_to_binary()

  defp text_output, do: Output.new(format: :human, color: :never, width: 100)

  describe "text output" do
    test "groups findings into blocking and optional with severity, location, trigger, and rule" do
      rendered = text(ReviewOutput.render(result(), change(), text_output()))

      assert rendered =~ "Blocking (1)"
      assert rendered =~ "Optional (1)"

      {blocking, optional} =
        rendered |> String.split("Optional (1)", parts: 2) |> List.to_tuple()

      assert blocking =~ "HIGH    lib/a.ex:3  Guard against a missing key"
      assert blocking =~ "Trigger: g/1 is called with a map without :key"
      assert blocking =~ "Rule: missing-nil-check"
      refute blocking =~ "(unverified)"

      assert optional =~
               "LOW     lib/b.ex:7-9 (old)  Cover the new clause with a test (unverified)"

      assert optional =~ "Trigger: Any future change to h/0"
      refute optional =~ "Rule:"

      # Rejected and dropped candidates are not shown.
      refute rendered =~ "Rename f"
      refute rendered =~ "map.key raises"
    end

    test "ends with the verdict and a summary of what was reviewed" do
      rendered = text(ReviewOutput.render(result(), change(), text_output()))

      assert rendered =~ "Blocking findings found."
      assert rendered =~ "Reviewed 2 files in 3 units (changes since main, default profile)"
      assert rendered =~ "1 blocking, 1 optional · 2 candidates, 1 rejected"
      assert rendered =~ "Skipped: mix.lock (lock file)"
    end

    test "ends with the cost of each stage and the total, counting cached input" do
      usage = fn input, cached, output, reasoning ->
        %Usage{
          input_tokens: input,
          cache_read_tokens: cached,
          output_tokens: output,
          reasoning_tokens: reasoning
        }
      end

      stages = %{
        detector: %{
          runs: 3,
          failed: 1,
          usage: usage.(52_300, 325_600, 4_500, 2_500),
          duration_ms: 56_000
        },
        verifier: %{
          runs: 3,
          failed: 0,
          usage: usage.(35_500, 97_300, 1_800, nil),
          duration_ms: 40_000
        },
        scorer: %{runs: 1, failed: 0, usage: usage.(1_800, nil, 238, 201), duration_ms: 9_600}
      }

      summary = summary(%{stages: stages, duration_ms: 105_000})
      rendered = text(ReviewOutput.render(result(summary: summary), change(), text_output()))

      assert rendered =~ "Cost (1m 45s):"

      assert rendered =~
               "  detector: 3 runs (1 failed), 377.9k in (325.6k cached, 86%), " <>
                 "4.5k out (2.5k reasoning), 56.0s"

      assert rendered =~ "  verifier: 3 runs, 132.8k in (97.3k cached, 73%), 1.8k out, 40.0s"
      assert rendered =~ "  scorer: 1 call, 1.8k in, 238 out (201 reasoning), 9.6s"

      assert rendered =~
               "  total: 7 model runs, 512.5k in (422.9k cached, 83%), " <>
                 "6.5k out (2.7k reasoning), 1m 45s"

      assert ReviewOutput.cost_summary(summary) ==
               "7 model runs, 519.0k tokens (422.9k cached), 1m 45s"

      assert ReviewOutput.cost_summary(summary(%{})) == nil

      assert [
               {"detector", "3 runs (1 failed), " <> _detector},
               {"verifier", _verifier},
               {"scorer", "1 call, " <> _scorer},
               {"total", "7 model runs, " <> _total}
             ] = ReviewOutput.stage_costs(summary)

      assert ReviewOutput.stage_costs(summary(%{})) == []
    end

    test "reports a clean review and an empty change" do
      clean = result(blocking: [], optional: [], summary: summary(%{verdict: :clean}))
      rendered = text(ReviewOutput.render(clean, change(mode: :staged), text_output()))

      assert rendered =~ "No findings."
      assert rendered =~ "staged changes"
      refute rendered =~ "Blocking ("

      empty =
        result(
          blocking: [],
          optional: [],
          rejected: [],
          dropped: [],
          summary: summary(%{units: 0, files: [], skipped: [], candidates: 0, verdict: :clean})
        )

      range = change(mode: :range, base_ref: "v1", head_sha: String.duplicate("b", 40))
      rendered = text(ReviewOutput.render(empty, range, text_output()))
      assert rendered =~ "Nothing to review in v1..bbbbbbbbbbbb"
      refute rendered =~ "Skipped"
    end

    test "lists failed units, verification and scoring failures, and rule warnings as notes" do
      summary =
        summary(%{
          failed_units: [%{unit: "lib/b.ex#1", reason: :timeout}],
          incomplete_units: [%{unit: "lib/a.ex#1", reason: :run_cancelled}],
          verification_failures: [%{fingerprint: "fp", reason: {:agent_error, "step limit"}}],
          scoring_failures: [%{fingerprint: "fp", reason: :boom}],
          warnings: ["rules/x.md: unknown category"]
        })

      rendered = text(ReviewOutput.render(result(summary: summary), change(), text_output()))

      assert rendered =~ "Notes"
      assert rendered =~ "Unit lib/b.ex#1 was not reviewed: timed out"
      assert rendered =~ "Unit lib/a.ex#1 was reviewed only in part (cancelled)"
      assert rendered =~ "A finding could not be verified: agent failed: step limit"
      assert rendered =~ "A finding kept its detector confidence: :boom"
      assert rendered =~ "rules/x.md: unknown category"
    end

    test "colors severities only when color is enabled" do
      colored =
        ReviewOutput.render(result(), change(), Output.new(format: :human, color: :always))

      assert inspect(colored) =~ "Owl.Data.tag("
      assert text(colored) == text(ReviewOutput.render(result(), change(), text_output()))

      refute inspect(ReviewOutput.render(result(), change(), text_output())) =~ "Owl.Data.tag("
    end
  end

  describe "JSON output" do
    test "encodes the whole result with the change" do
      json =
        result() |> ReviewOutput.render(change(), Output.new(format: :json)) |> JSON.decode!()

      assert json["verdict"] == "blocking"

      assert json["change"] == %{
               "mode" => "branch",
               "root" => "/repo",
               "base_ref" => "main",
               "base_sha" => String.duplicate("a", 40),
               "head_sha" => "worktree"
             }

      assert [blocking] = json["blocking"]

      assert blocking == %{
               "title" => "Guard against a missing key",
               "category" => "correctness",
               "severity" => "high",
               "blocking" => true,
               "confidence" => 0.9,
               "rule_id" => "missing-nil-check",
               "location" => %{
                 "path" => "lib/a.ex",
                 "side" => "new",
                 "start_line" => 3,
                 "end_line" => 3
               },
               "trigger" => "g/1 is called with a map\nwithout :key",
               "body" => "map.key raises KeyError for such maps.",
               "suggestion" => nil,
               "support" => 1,
               "verdict" => "confirmed",
               "fingerprint" => "fp-nil-check"
             }

      assert [%{"verdict" => "uncertain", "location" => %{"side" => "old"}}] = json["optional"]

      assert [%{"finding" => %{"title" => "Rename f"}, "evidence" => "Style."}] =
               json["rejected"]

      assert [%{"finding" => %{"fingerprint" => "fp-low"}, "reason" => "low_confidence"}] =
               json["dropped"]

      assert json["usage"] == %{"input_tokens" => 120, "output_tokens" => 30}
    end

    test "encodes summary atoms and failure reasons as strings" do
      summary =
        summary(%{
          failed_units: [%{unit: "lib/b.ex#1", reason: :timeout}],
          incomplete_units: [%{unit: "lib/a.ex#1", reason: :timeout}],
          verification_failures: [%{fingerprint: "fp", reason: {:runtime_error, :killed}}],
          scoring_failures: [%{fingerprint: "fp2", reason: {:error, "bad"}}]
        })

      json =
        result(summary: summary, usage: nil)
        |> ReviewOutput.render(change(), Output.new(format: :json))
        |> JSON.decode!()

      assert %{
               "profile" => "default",
               "verdict" => "blocking",
               "units" => 3,
               "files" => ["lib/a.ex", "lib/b.ex"],
               "skipped" => [%{"path" => "mix.lock", "reason" => "lock_file"}],
               "failed_units" => [%{"unit" => "lib/b.ex#1", "reason" => "timed out"}],
               "incomplete_units" => [%{"unit" => "lib/a.ex#1", "reason" => "timed out"}],
               "verification_failures" => [
                 %{"fingerprint" => "fp", "reason" => "agent crashed: :killed"}
               ],
               "scoring_failures" => [%{"fingerprint" => "fp2", "reason" => ~s({:error, "bad"})}]
             } = json["summary"]

      assert json["usage"] == %{}
    end
  end

  describe "errors" do
    test "describe change, review, and startup failures" do
      assert ReviewOutput.format_error({:change, {:not_a_git_repository, "/tmp/x"}}) ==
               "/tmp/x is not inside a Git repository"

      assert ReviewOutput.format_error({:change, {:unknown_revision, "nope"}}) ==
               "unknown revision: nope"

      assert ReviewOutput.format_error(:cancelled) == "the review was cancelled"

      assert ReviewOutput.format_error(
               {:detection_failed, [%{unit: "a", reason: :timeout}, %{unit: "b", reason: :x}]}
             ) == "every review unit failed (2); first: timed out"

      assert ReviewOutput.format_error({:missing_tool, "review-detector", "report_findings"}) ==
               "the agent profile review-detector must keep the report_findings tool"

      assert ReviewOutput.format_error({:missing_profile, "review-verifier"}) =~
               "review-verifier is missing"

      assert ReviewOutput.format_error({:unknown_model, "x/y"}) == ~s({:unknown_model, "x/y"})
    end

    test "render in the output's format" do
      assert text(ReviewOutput.render_error(:cancelled, text_output())) ==
               "error: the review was cancelled"

      assert JSON.decode!(ReviewOutput.render_error(:cancelled, Output.new(format: :json))) ==
               %{"error" => "the review was cancelled"}
    end
  end

  test "exit status is 1 only when a blocking finding is shown" do
    assert Review.exit_status(result()) == 1
    assert Review.exit_status(result(blocking: [])) == 0
    assert Review.exit_status(result(blocking: [], optional: [])) == 0
  end

  describe "progress" do
    defp lines(events) do
      {lines, _progress} =
        Enum.map_reduce(events, ReviewProgress.new(), fn event, progress ->
          ReviewProgress.event(progress, event)
        end)

      Enum.reject(lines, &is_nil/1)
    end

    test "counts units and names the finding of each verdict" do
      nil_check = finding()
      test_gap = optional_finding()

      assert lines([
               {:started, %{units: 3}},
               {:unit, "change", :started},
               {:unit, "lib/a.ex#1", :started},
               {:unit, "lib/a.ex#1", :done},
               {:unit, "change", :done},
               {:unit, "lib/b.ex#1", {:failed, {:agent_error, "step limit\nmore"}}},
               {:candidate, nil_check},
               {:candidate, test_gap},
               {:verdict, "fp-nil-check", :confirmed},
               {:verdict, "fp-test", :rejected},
               {:verdict, "fp-unknown", :uncertain},
               {:done, result()}
             ]) == [
               "Reviewing 3 units…",
               "[1/3] Reviewed lib/a.ex#1",
               "[2/3] Reviewed the change overview",
               "[3/3] Could not review lib/b.ex#1: agent failed: step limit",
               "Verifying lib/a.ex:3 Guard against a missing key",
               "Verifying lib/b.ex:7-9 (old) Cover the new clause with a test",
               "Confirmed: lib/a.ex:3 Guard against a missing key",
               "Rejected: lib/b.ex:7-9 (old) Cover the new clause with a test",
               "Unverified: fp-unknown"
             ]
    end

    test "prints nothing for an empty change or a failed review" do
      assert lines([{:started, %{units: 0}}, {:done, result()}]) == []
      assert lines([{:started, %{units: 1}}, {:error, :cancelled}]) == ["Reviewing 1 unit…"]
    end
  end
end
