defmodule Tackle.Tools.ReviewResultTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.{Change, Diff, Finding, Result}
  alias Tackle.Tools.Review

  doctest Tackle.Tools.Review

  # A result text in the format `Review.format_result/3` writes.
  @output """
  Reviewed 2 files (changes since main): 1 blocking, 2 optional finding(s).

  Blocking:
  1. lib/a.ex:3 [high, correctness] Guard against a missing key
     Trigger: g/1 is called with a map without :key
     map.key raises KeyError for such maps.
     Suggestion:
     def g(map), do: Map.get(map, :key)

  Optional:
  2. lib/b.ex:10-12 [medium, maintainability, rule naming] Name the helper (unverified)
     Trigger: always
     It is unclear.
  3. lib/b.ex:4 (removed lines) [low, readability] Keep the doc example
     Trigger: always
     It documented the call.

  Notes:
  - 1 dismissed finding not reported again.
  """

  describe "parse_result/1" do
    test "parses a review result's outcome, findings, and notes" do
      assert %{
               target: "changes since main",
               files: 2,
               blocking: 1,
               optional: 2,
               findings: [first, second, third],
               notes: ["1 dismissed finding not reported again."]
             } = Review.parse_result(@output)

      assert first == %{
               group: :blocking,
               location: "lib/a.ex:3",
               severity: :high,
               category: "correctness",
               rule: nil,
               title: "Guard against a missing key",
               unverified?: false
             }

      assert %{
               group: :optional,
               location: "lib/b.ex:10-12",
               rule: "naming",
               title: "Name the helper",
               unverified?: true
             } = second

      assert %{location: "lib/b.ex:4 (old)", severity: :low} = third

      assert %{files: 1, blocking: 0, optional: 0, findings: []} =
               Review.parse_result(
                 "Reviewed 1 file (staged changes): 0 blocking, 0 optional finding(s)."
               )

      assert Review.parse_result("The review failed: boom") == nil
      assert Review.parse_result(nil) == nil
      assert Review.parse_result(<<"Reviewed ", 0xFF>>) == nil
    end

    test "parses the result text the review tool actually produces" do
      {:ok, diff} =
        Diff.parse("""
        diff --git a/lib/a b.ex b/lib/a b.ex
        --- a/lib/a b.ex
        +++ b/lib/a b.ex
        @@ -1,2 +1,2 @@
         defmodule A do
        -  def run(x), do: x
        +  def run(x), do: File.read!(x)
        """)

      change = %Change{
        cwd: "/repo",
        root: "/repo",
        mode: :branch,
        base_ref: "main",
        base_sha: "abc",
        head_sha: :worktree,
        diff: diff
      }

      finding = fn title, opts ->
        %Finding{
          title: title,
          category: Keyword.get(opts, :category, :correctness),
          severity: Keyword.get(opts, :severity, :high),
          blocking: Keyword.get(opts, :blocking, true),
          confidence: 0.8,
          rule_id: Keyword.get(opts, :rule_id),
          location: %{
            path: "lib/a b.ex",
            side: Keyword.get(opts, :side, :new),
            start_line: 2,
            end_line: Keyword.get(opts, :end_line, 2)
          },
          trigger: "x is missing",
          body: "It raises.\nTwice.",
          suggestion: "File.read(x)",
          verdict: Keyword.get(opts, :verdict, :confirmed),
          fingerprint: title
        }
      end

      blocking = [finding.("Handle [the] read failure", [])]

      optional = [
        finding.("Name it",
          severity: :low,
          blocking: false,
          rule_id: "naming",
          verdict: :uncertain
        ),
        finding.("Keep the doc", severity: :medium, blocking: false, side: :old, end_line: 4)
      ]

      summary = %{
        profile: :default,
        samples: 1,
        units: 2,
        files: ["lib/a b.ex"],
        skipped: [],
        failed_units: [%{unit: "lib/a b.ex#1", reason: :timeout}],
        incomplete_units: [],
        detected: 3,
        candidates: 3,
        confirmed: 2,
        uncertain: 1,
        rejected: 0,
        verification_failures: [],
        scoring_failures: [],
        blocking: 1,
        optional: 2,
        verdict: :blocking,
        warnings: []
      }

      # Ranked out after verification (listed), and filtered before it (not).
      hidden = finding.("Close the file", severity: :medium, blocking: false)
      filtered = finding.("Off the diff", verdict: nil)

      dropped = [
        %{finding: filtered, reason: :not_on_changed_lines},
        %{finding: %{hidden | confidence: 0.62}, reason: :below_threshold}
      ]

      summary = %{summary | scoring_failures: [%{fingerprint: "x", reason: :timeout}]}

      result = %Result{
        blocking: blocking,
        optional: optional,
        dropped: dropped,
        summary: summary
      }

      text = Review.format_result(result, change, ["History is off"])

      assert text =~
               "Verified but not shown under the default profile:\n" <>
                 "- lib/a b.ex:2 [medium, correctness] Close the file " <>
                 "(confirmed, confidence 0.62 below the optional threshold 0.80)\n" <>
                 "   Trigger: x is missing\n\nNotes:"

      refute text =~ "Off the diff"

      assert %{
               target: "changes since main",
               files: 1,
               blocking: 1,
               optional: 2,
               hidden: 1,
               findings: [first, second, third],
               notes: [
                 "History is off",
                 "Unit lib/a b.ex#1 was not reviewed: " <> _reason,
                 "1 finding could not be scored and kept the detector's confidence: timed out"
               ]
             } = Review.parse_result(text)

      many = for n <- 1..12, do: %{finding: %{hidden | title: "H#{n}"}, reason: :over_cap}
      text = Review.format_result(%{result | dropped: many}, change, [])
      assert text =~ "(confirmed, over the cap of 15 findings)"
      assert text =~ "- … and 2 more"
      assert %{hidden: 12, findings: [_, _, _]} = Review.parse_result(text)

      assert %{group: :blocking, location: "lib/a b.ex:2", title: "Handle [the] read failure"} =
               first

      assert %{group: :optional, severity: :low, rule: "naming", unverified?: true} = second
      assert %{location: "lib/a b.ex:2-4 (old)", severity: :medium, rule: nil} = third
    end
  end
end
