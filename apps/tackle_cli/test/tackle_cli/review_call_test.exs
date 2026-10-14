defmodule Tackle.CLI.TUI.ReviewCallTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.{Conversation, MessageView, ReviewCall, RuntimeEvents, State, ToolView}
  alias Tackle.CLI.TUI.{SubagentTranscript, Subagents, Viewport}
  alias Tackle.Review.{Change, Diff, Finding, Result}
  alias Tackle.CLI.Widgets.Input
  alias Tackle.Lib.Event
  alias Tackle.Lib.State, as: AgentState

  doctest Tackle.CLI.TUI.ReviewCall

  # The result format `Tackle.Tools.Review` returns, as its own tests pin it.
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

  defp candidate(fingerprint, title, severity) do
    %{
      kind: :candidate,
      finding: %{
        fingerprint: fingerprint,
        title: title,
        severity: severity,
        category: :correctness,
        location: %{path: "lib/a.ex", side: :new, start_line: 3, end_line: 3}
      }
    }
  end

  defp running_events do
    [
      %{
        kind: :loaded,
        target: "changes since main",
        files: 2,
        additions: 4,
        deletions: 2,
        profile: "default"
      },
      %{kind: :started, units: 3},
      %{kind: :unit, unit: "change", status: :started},
      %{kind: :unit, unit: "change", status: :done},
      %{kind: :unit, unit: "lib/a.ex#1", status: :started},
      %{kind: :unit, unit: "lib/b.ex#1", status: :failed, error: "timed out"},
      candidate("a", "Guard against a missing key", :high),
      %{kind: :verdict, fingerprint: "a", verdict: :confirmed},
      candidate("b", "Prefer pattern match", :medium),
      %{kind: :verdict, fingerprint: "b", verdict: :rejected}
    ]
  end

  defp model(events \\ running_events()),
    do: Enum.reduce(events, ReviewCall.new(), &ReviewCall.apply(&2, &1))

  defp entry(status, model, output, args \\ %{}) do
    %MessageView{
      kind: :tool,
      content: "review_changes",
      tool_name: "review_changes",
      tool_status: status,
      tool_arguments: args,
      tool_output: output,
      review_call: model,
      tool_elapsed_ms: 42_000
    }
  end

  defp render(entry, mode \\ :preview, width \\ 100) do
    entry
    |> ToolView.render(width, mode)
    |> Enum.flat_map(fn {widget, _height} -> widget.text end)
    |> Enum.map_join("\n", fn row -> Enum.map_join(row.spans, & &1.content) end)
  end

  describe "the model" do
    test "folds the reported progress" do
      model = model()

      assert model.target == "changes since main"
      assert {model.files, model.additions, model.deletions} == {2, 4, 2}
      assert model.profile == "default"
      assert ReviewCall.loaded?(model)

      progress = model.progress
      assert progress.total == 3
      assert {"lib/b.ex#1", {:failed, "timed out"}} in progress.units
      assert Enum.map(progress.candidates, & &1.verdict) == [:confirmed, :rejected]

      done = ReviewCall.apply(model, %{kind: :done, summary: %{candidates: 2, rejected: 1}})
      assert done.summary == %{candidates: 2, rejected: 1}
    end

    test "ignores unknown or malformed progress" do
      model = model()

      for review <- [
            %{kind: :unknown},
            %{kind: :unit, unit: "x", status: :sleeping},
            %{kind: :candidate, finding: %{fingerprint: "x"}},
            %{kind: :candidate, finding: %{fingerprint: "x", title: "T"}},
            %{
              kind: :candidate,
              finding: Map.delete(candidate("x", "T", :low).finding, :location)
            },
            %{kind: :verdict, fingerprint: "x", verdict: :maybe},
            %{kind: :started, units: "many"}
          ] do
        assert ReviewCall.apply(model, review) === model
      end

      refute ReviewCall.loaded?(ReviewCall.new())
      refute ReviewCall.loaded?(nil)
    end

    test "parses a review result's outcome, findings, and notes" do
      assert %{
               target: "changes since main",
               files: 2,
               blocking: 1,
               optional: 2,
               findings: [first, second, third],
               notes: ["1 dismissed finding not reported again."]
             } = ReviewCall.parse_result(@output)

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
               ReviewCall.parse_result(
                 "Reviewed 1 file (staged changes): 0 blocking, 0 optional finding(s)."
               )

      assert ReviewCall.parse_result("The review failed: boom") == nil
      assert ReviewCall.parse_result(nil) == nil
      assert ReviewCall.parse_result(<<"Reviewed ", 0xFF>>) == nil
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

      text = Tackle.Tools.Review.format_result(result, change, ["History is off"])

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
             } = ReviewCall.parse_result(text)

      many = for n <- 1..12, do: %{finding: %{hidden | title: "H#{n}"}, reason: :over_cap}
      text = Tackle.Tools.Review.format_result(%{result | dropped: many}, change, [])
      assert text =~ "(confirmed, over the cap of 15 findings)"
      assert text =~ "- … and 2 more"
      assert %{hidden: 12, findings: [_, _, _]} = ReviewCall.parse_result(text)

      assert %{group: :blocking, location: "lib/a b.ex:2", title: "Handle [the] read failure"} =
               first

      assert %{group: :optional, severity: :low, rule: "naming", unverified?: true} = second
      assert %{location: "lib/a b.ex:2-4 (old)", severity: :medium, rule: nil} = third
    end
  end

  describe "the card" do
    test "a running review shows the pipeline, progress, and live candidates" do
      text = render(entry(:running, model(), nil, %{"profile" => "quiet"}))

      assert text =~ "● running  review  changes since main  quiet profile  42s"
      assert text =~ "✓ Load ── ● Detect 2/3 ── ◌ Verify 2/2 ── ◌ Rank"
      assert text =~ ~r/Detecting  ━+─+  2\/3 units · 1 failed/u
      assert text =~ ~r/Verifying  ━+  2\/2 candidates · 1 confirmed · 1 rejected/u
      assert text =~ "✓  HIGH   Guard against a missing key  lib/a.ex:3"
      assert text =~ "✗  MED    Prefer pattern match  lib/a.ex:3"
    end

    test "before the change loads it names the requested target" do
      text = render(entry(:running, nil, nil, %{"staged" => true}))
      assert text =~ "review  staged changes"
      assert text =~ "● Loading the change…"

      # A call that never ran (or an orphan after a resume) is not loading.
      requested = render(entry(:requested, nil, nil, %{"range" => "main..HEAD"}))
      assert requested =~ "review  main..HEAD"
      refute requested =~ "Loading"
    end

    test "a clean review whose units failed is not shown as clean" do
      output =
        "Reviewed 2 files (changes since main): 0 blocking, 0 optional finding(s).\n\n" <>
          "Notes:\n- Unit lib/a.ex#1 was not reviewed: timed out\n- Another note"

      text = render(entry(:completed, nil, output))
      assert text =~ "● No findings, but the review was incomplete  2 files reviewed"
      assert text =~ "! Unit lib/a.ex#1 was not reviewed: timed out  +1 more note"
      refute text =~ "✓"
    end

    test "a settled review shows the outcome and one row per finding" do
      done =
        ReviewCall.apply(model(), %{
          kind: :done,
          summary: %{candidates: 4, rejected: 1, blocking: 1, optional: 2}
        })

      text = render(entry(:completed, done, @output))

      assert text =~ "review  changes since main  42s"

      assert text =~
               "✗ 1 blocking · 2 optional  2 files reviewed · +4 −2 · 4 candidates, 1 rejected"

      assert text =~ " HIGH   Guard against a missing key  lib/a.ex:3"
      assert text =~ " MED    Name the helper ?  lib/b.ex:10-12"
      assert text =~ " LOW    Keep the doc example  lib/b.ex:4 (old)"
      assert text =~ "! 1 dismissed finding not reported again."
      refute text =~ "Trigger:"

      # A resumed session has only the result text.
      resumed = render(entry(:completed, nil, @output))
      assert resumed =~ "review  changes since main"
      assert resumed =~ "✗ 1 blocking · 2 optional  2 files reviewed\n"
      assert resumed =~ " HIGH   Guard against a missing key"
    end

    test "many findings are bounded with a count of the rest" do
      lines =
        for n <- 1..15,
            do: "#{n}. lib/a.ex:#{n} [low, readability] Finding #{n}\n   Trigger: t\n   b"

      output =
        "Reviewed 1 file (changes since main): 0 blocking, 15 optional finding(s).\n\n" <>
          "Optional:\n" <> Enum.join(lines, "\n")

      text = render(entry(:completed, nil, output))
      assert text =~ "Finding 1 "
      refute text =~ "Finding 15"
      assert text =~ ~r/… \d+ more findings · details show all/u
    end

    test "verified findings the profile hid are counted, not shown as clean" do
      hidden =
        "Verified but not shown under the default profile:\n" <>
          "- lib/a.ex:3 [medium, correctness] Treat <<< apart (confirmed, confidence 0.62 " <>
          "below the optional threshold 0.80)\n   Trigger: cat <<< word\n" <>
          "- lib/a.ex:9 [low, testing] Add a test (confirmed, confidence 0.5 below " <>
          "the optional threshold 0.80)\n   Trigger: always"

      output =
        "Reviewed 2 files (changes since main): 0 blocking, 0 optional finding(s).\n\n" <>
          hidden

      text = render(entry(:completed, nil, output))

      assert text =~
               "● No findings shown · 2 verified, hidden by the profile  2 files reviewed"

      refute text =~ "✓"
      refute text =~ "Treat <<< apart"

      shown =
        "Reviewed 2 files (changes since main): 1 blocking, 0 optional finding(s).\n\n" <>
          "Blocking:\n1. lib/a.ex:1 [high, correctness] Quote the cwd\n   Trigger: t\n   b\n\n" <>
          hidden

      text = render(entry(:completed, nil, shown))
      assert text =~ "✗ 1 blocking · 0 optional · 2 verified, hidden by the profile"
      assert text =~ " HIGH   Quote the cwd  lib/a.ex:1"
    end

    test "clean and empty reviews say so" do
      assert render(
               entry(
                 :completed,
                 nil,
                 "Reviewed 3 files (changes since main): 0 blocking, 0 optional finding(s)."
               )
             ) =~ "✓ No findings  3 files reviewed"

      assert render(entry(:completed, nil, "Nothing to review in staged changes.")) =~
               "✓ Nothing to review"
    end

    test "a failure keeps the generic card with its error" do
      text = render(entry(:failed, model(), "The review failed: every review unit failed"))
      assert text =~ "✗ failed  review  changes since main"
      assert text =~ "The review failed: every review unit failed"
    end

    test "details add the progress above the full result" do
      done = ReviewCall.apply(model(), %{kind: :done, summary: %{candidates: 2}})
      text = render(entry(:completed, done, @output), :details)

      assert text =~ "Progress\n    ✓ Load ── ✓ Detect 2/3 ── ✓ Verify 2/2 ── ✓ Rank"
      assert text =~ "changes since main  2 files +4 −2  default profile"
      assert text =~ "Trigger: g/1 is called with a map without :key"

      plain = render(entry(:completed, nil, @output), :details)
      refute plain =~ "Progress"
      assert plain =~ "Trigger: g/1 is called with a map without :key"
    end

    test "every state renders at narrow widths and small budgets" do
      for status <- [:requested, :running, :completed, :failed],
          model <- [nil, model()],
          width <- [8, 30, 60] do
        assert is_list(ToolView.render(entry(status, model, @output), width))
        assert is_list(ToolView.render(entry(status, model, @output), width, :details))
      end

      for budget <- 1..4 do
        rows = Tackle.CLI.TUI.ReviewCallView.preview(model(), :completed, @output, 80, budget)
        assert length(rows) <= budget
        rows = Tackle.CLI.TUI.ReviewCallView.preview(model(), :running, nil, 80, budget)
        assert length(rows) <= budget
      end
    end
  end

  describe "runtime events" do
    defp shell do
      state = %State{
        session_id: "session",
        active_turn: %{id: "turn"},
        input: Input.new(),
        agent_state: %AgentState{},
        conversation: Viewport.new_conversation(100, 40)
      }

      Viewport.refresh(%{state | stream: %{state.stream | coalesce?: false}})
    end

    defp event(state, type, data) do
      case RuntimeEvents.handle({:tackle_event, "session", "turn", Event.new(type, data)}, state) do
        {:noreply, state} -> state
        {:noreply, state, _opts} -> state
      end
    end

    defp card(state),
      do:
        state.conversation
        |> Conversation.entries()
        |> Enum.find(&(&1.kind == :tool and &1.tool_name == "review_changes"))

    test "structured progress builds the call's review model, not its output" do
      state =
        shell()
        |> event(:tool_start, %{tool_call_id: "r1", name: "review_changes", arguments: %{}})

      state =
        Enum.reduce(running_events(), state, fn review, state ->
          event(state, :tool_progress, %{
            tool_call_id: "r1",
            name: "review_changes",
            review: review
          })
        end)

      card = card(state)
      assert %ReviewCall{target: "changes since main"} = card.review_call
      assert length(card.review_call.progress.candidates) == 2
      assert card.tool_output in [nil, ""]

      # Progress for another call is ignored.
      other =
        event(state, :tool_progress, %{
          tool_call_id: "nope",
          name: "review_changes",
          review: %{kind: :started, units: 9}
        })

      assert card(other).review_call == card.review_call

      settled =
        event(state, :tool_execution_end, %{
          tool_call_id: "r1",
          name: "review_changes",
          status: :completed,
          result: @output
        })

      assert %ReviewCall{} = card(settled).review_call
      assert card(settled).tool_output == @output
    end

    test "a subagent's review keeps its activity line and gets a live card" do
      state =
        shell()
        |> event(:tool_start, %{
          tool_call_id: "one",
          name: "subagent",
          arguments: %{"profile" => "worker", "prompt" => "Fix and review"}
        })
        |> event(:subagent_started, %{
          tool_call_id: "one",
          run_id: "run-one",
          profile: "worker",
          status: :running
        })
        |> event(:subagent_progress, %{
          run_id: "run-one",
          tool_call_id: "one",
          event: Event.new(:tool_start, %{tool_call_id: "child-review", name: "review_changes"})
        })

      state =
        Enum.reduce(running_events(), state, fn review, state ->
          event(state, :subagent_progress, %{
            run_id: "run-one",
            event:
              Event.new(:tool_progress, %{
                tool_call_id: "child-review",
                name: "review_changes",
                review: review
              })
          })
        end)

      assert [%{subagent_work: work}] = Subagents.tasks(state)
      assert work =~ "Running review_changes"

      transcript =
        Enum.reduce(
          [
            Event.new(:tool_start, %{tool_call_id: "child-review", name: "review_changes"})
            | Enum.map(
                running_events(),
                &Event.new(:tool_progress, %{
                  tool_call_id: "child-review",
                  name: "review_changes",
                  review: &1
                })
              )
          ],
          SubagentTranscript.new(),
          &SubagentTranscript.apply(&2, &1)
        )

      assert [%{review: %ReviewCall{target: "changes since main"}}] = transcript.timeline
    end

    test "text progress of other tools still streams as output" do
      state =
        shell()
        |> event(:tool_start, %{tool_call_id: "b1", name: "bash", arguments: %{}})
        |> event(:tool_progress, %{tool_call_id: "b1", name: "bash", delta: "hello\n"})

      bash = state.conversation |> Conversation.entries() |> Enum.find(&(&1.tool_name == "bash"))
      assert bash.tool_output == "hello\n"
    end
  end
end
