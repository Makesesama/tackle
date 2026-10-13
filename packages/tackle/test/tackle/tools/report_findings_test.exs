defmodule Tackle.Tools.ReportFindingsTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Message
  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.Call
  alias Tackle.Review.Finding
  alias Tackle.Tools.{ReportFindings, ReportVerdict}

  @review %{
    stage: :detector,
    unit_id: "lib/a.ex#1",
    allowed: %{"lib/a.ex" => %{new: [10..12], old: []}},
    rule_ids: ["unhandled-error"]
  }

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        "title" => "Handle the error from File.read",
        "category" => "correctness",
        "severity" => "high",
        "blocking" => true,
        "confidence" => 0.8,
        "rule_id" => "unhandled-error",
        "location" => %{
          "path" => "lib/a.ex",
          "side" => "new",
          "start_line" => 11,
          "end_line" => 11
        },
        "trigger" => "The file does not exist",
        "body" => "The error tuple is ignored.",
        "suggestion" => nil
      },
      overrides
    )
  end

  defp tool(args, context), do: Tool.execute_tool_call(ReportFindings, args, context)

  describe "accept/2" do
    test "returns valid findings and indexed errors for invalid ones" do
      bad_location = %{"path" => "lib/a.ex", "side" => "new", "start_line" => 1, "end_line" => 2}

      assert {[%Finding{title: "Handle the error from File.read"}], errors} =
               ReportFindings.accept(
                 [
                   finding(),
                   finding(%{"location" => bad_location}),
                   finding(%{"rule_id" => "other", "severity" => "huge"})
                 ],
                 @review
               )

      assert [
               "findings[2].location: new lines 1-2 of lib/a.ex contain no changed line" <> _,
               "findings[3].severity: must be one of" <> _,
               "findings[3].rule_id: unknown rule \"other\"" <> _
             ] = errors
    end

    test "refuses too many findings at once" do
      assert {[], ["findings: 21 findings is too many" <> _]} =
               ReportFindings.accept(List.duplicate(finding(), 21), @review)
    end
  end

  describe "run/2" do
    test "records valid findings" do
      assert {:ok, "Recorded 1 finding."} = tool(%{"findings" => [finding()]}, %{review: @review})
      assert {:ok, "Recorded no findings."} = tool(%{"findings" => []}, %{review: @review})

      assert {:ok, "Recorded 1 finding." <> _} =
               tool(%{"findings" => [finding()], "done" => true}, %{review: @review})
    end

    test "with done: false, asks for the rest of the review" do
      assert {:ok, text} =
               tool(%{"findings" => [finding()], "done" => false}, %{review: @review})

      assert text =~ "Recorded 1 finding. Keep reviewing"
      assert text =~ "without done: false"
    end

    test "returns the errors of rejected findings to the model" do
      bad =
        finding(%{
          "location" => %{
            "path" => "lib/b.ex",
            "side" => "new",
            "start_line" => 1,
            "end_line" => 1
          }
        })

      assert {:ok, text} = tool(%{"findings" => [finding(), bad]}, %{review: @review})
      assert text =~ "Recorded 1 finding. The other findings were not recorded"
      assert text =~ "- findings[2].location.path: lib/b.ex is not part of this review unit"

      assert {:error, text} = tool(%{"findings" => [bad]}, %{review: @review})
      assert text =~ "No findings were recorded"
      assert text =~ "findings[1].location.path"
    end

    test "only works in a detector run" do
      assert {:error, text} = tool(%{"findings" => []}, %{})
      assert text =~ "only available in review detector runs"
    end
  end

  test "collect/2 revalidates answered calls only, in transcript order" do
    second = finding(%{"title" => "Check the second case"})

    invalid =
      finding(%{
        "location" => %{"path" => "lib/a.ex", "side" => "new", "start_line" => 1, "end_line" => 1}
      })

    messages = [
      Message.user("review"),
      Message.assistant(
        tool_calls: [
          %Call{
            id: "1",
            name: "report_findings",
            arguments: %{"findings" => [finding(), invalid]}
          },
          %Call{id: "2", name: "read", arguments: %{"path" => "lib/a.ex"}}
        ]
      ),
      Message.tool_result("1", "report_findings", "Recorded 1 finding."),
      Message.tool_result("2", "read", "..."),
      Message.assistant(
        tool_calls: [
          %{"id" => "3", "name" => "report_findings", "arguments" => %{"findings" => [second]}}
        ]
      ),
      Message.tool_result("3", "report_findings", "Recorded 1 finding."),
      # Interrupted: never answered.
      Message.assistant(
        tool_calls: [
          %Call{id: "4", name: "report_findings", arguments: %{"findings" => [finding()]}}
        ]
      )
    ]

    assert [
             %Finding{title: "Handle the error from File.read"},
             %Finding{title: "Check the second case"}
           ] =
             ReportFindings.collect(messages, @review)
  end

  test "collect/2 counts a finding reported again once" do
    report = fn id, findings, done ->
      [
        Message.assistant(
          tool_calls: [
            %Call{
              id: id,
              name: "report_findings",
              arguments: %{"findings" => findings, "done" => done}
            }
          ]
        ),
        Message.tool_result(id, "report_findings", "Recorded.")
      ]
    end

    second = finding(%{"title" => "Check the second case"})
    messages = report.("1", [finding()], false) ++ report.("2", [finding(), second], true)

    assert [%Finding{title: "Handle the error from File.read"}, %Finding{title: "Check" <> _}] =
             ReportFindings.collect(messages, @review)
  end

  test "finished?/2 is true only for an answered last call the tool accepted" do
    invalid =
      finding(%{
        "location" => %{"path" => "lib/a.ex", "side" => "new", "start_line" => 1, "end_line" => 1}
      })

    report = fn id, findings ->
      Message.assistant(
        tool_calls: [%Call{id: id, name: "report_findings", arguments: %{"findings" => findings}}]
      )
    end

    refute ReportFindings.finished?([Message.user("review")], @review)

    # Every finding invalid: the tool returned an error, nothing was recorded.
    rejected = [report.("1", [invalid]), Message.tool_result("1", "report_findings", "No...")]
    refute ReportFindings.finished?(rejected, @review)

    # Never answered.
    refute ReportFindings.finished?([report.("2", [finding()])], @review)

    empty = [report.("3", []), Message.tool_result("3", "report_findings", "Recorded no...")]
    assert ReportFindings.finished?(empty, @review)

    partial = [
      report.("4", [finding(), invalid]),
      Message.tool_result("4", "report_findings", "Recorded 1 finding.")
    ]

    assert ReportFindings.finished?(rejected ++ partial, @review)

    # Reports made while still reviewing do not finish the run.
    progress = [
      Message.assistant(
        tool_calls: [
          %Call{
            id: "5",
            name: "report_findings",
            arguments: %{"findings" => [finding()], "done" => false}
          }
        ]
      ),
      Message.tool_result("5", "report_findings", "Recorded 1 finding.")
    ]

    refute ReportFindings.finished?(progress, @review)
    assert ReportFindings.finished?(progress ++ empty, @review)
  end

  describe "report_verdict" do
    test "parses verdicts and reports problems" do
      assert {:ok, %{finding: "F2", verdict: :confirmed, evidence: "lib/a.ex:11 ignores it."}} =
               ReportVerdict.parse(
                 %{
                   "finding" => "F2",
                   "verdict" => "confirmed",
                   "evidence" => " lib/a.ex:11 ignores it. "
                 },
                 ["F1", "F2"]
               )

      assert {:error, "finding: must be one of F1, F2"} =
               ReportVerdict.parse(
                 %{"finding" => "F3", "verdict" => "confirmed", "evidence" => "x"},
                 ["F1", "F2"]
               )

      assert {:error, "verdict: must be one of confirmed, rejected, uncertain"} =
               ReportVerdict.parse(
                 %{"finding" => "F1", "verdict" => "maybe", "evidence" => "x"},
                 ["F1"]
               )

      assert {:error, "evidence: must not be empty"} =
               ReportVerdict.parse(
                 %{"finding" => "F1", "verdict" => "rejected", "evidence" => "  "},
                 ["F1"]
               )

      assert {:error, "report_verdict requires a finding, a verdict, and evidence"} =
               ReportVerdict.parse(%{"verdict" => "rejected", "evidence" => "x"}, ["F1"])
    end

    test "only works in a verifier run" do
      args = %{"finding" => "F1", "verdict" => "confirmed", "evidence" => "lib/a.ex:11"}

      assert {:ok, text} =
               Tool.execute_tool_call(ReportVerdict, args, %{
                 review: %{stage: :verifier, finding_ids: ["F1"]}
               })

      assert text =~ "Verdict recorded: confirmed"
      assert text =~ "do not call report_verdict again"

      assert {:ok, text} =
               Tool.execute_tool_call(ReportVerdict, args, %{
                 review: %{stage: :verifier, finding_ids: ["F1", "F2"]}
               })

      assert text =~ "Verdict on F1 recorded: confirmed"
      assert text =~ "Go on with the findings you have not decided yet"

      assert {:error, text} =
               Tool.execute_tool_call(ReportVerdict, args, %{review: @review})

      assert text =~ "only available in review verifier runs"
    end

    test "collect/2 returns the first answered valid verdict of each finding" do
      call = fn id, finding, verdict, evidence ->
        Message.assistant(
          tool_calls: [
            %Call{
              id: id,
              name: "report_verdict",
              arguments: %{"finding" => finding, "verdict" => verdict, "evidence" => evidence}
            }
          ]
        )
      end

      messages = [
        call.("1", "F1", "nope", "x"),
        Message.tool_result("1", "report_verdict", "Error: verdict"),
        call.("2", "F1", "rejected", "a:1"),
        Message.tool_result("2", "report_verdict", "Verdict recorded"),
        call.("3", "F1", "confirmed", "b:2"),
        Message.tool_result("3", "report_verdict", "Verdict recorded"),
        call.("4", "F2", "uncertain", "c:3"),
        Message.tool_result("4", "report_verdict", "Verdict recorded"),
        call.("5", "F3", "confirmed", "d:4"),
        Message.tool_result("5", "report_verdict", "Error: finding"),
        # Never answered, so it does not count.
        call.("6", "F2", "confirmed", "e:5")
      ]

      assert %{
               "F1" => %{verdict: :rejected, evidence: "a:1"},
               "F2" => %{verdict: :uncertain, evidence: "c:3"}
             } = verdicts = ReportVerdict.collect(messages, ["F1", "F2"])

      assert map_size(verdicts) == 2
      assert ReportVerdict.collect(Enum.take(messages, 2), ["F1"]) == %{}
    end
  end
end
