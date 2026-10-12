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

  test "reported?/2 is true only for an answered call the tool accepted" do
    invalid =
      finding(%{
        "location" => %{"path" => "lib/a.ex", "side" => "new", "start_line" => 1, "end_line" => 1}
      })

    report = fn id, findings ->
      Message.assistant(
        tool_calls: [%Call{id: id, name: "report_findings", arguments: %{"findings" => findings}}]
      )
    end

    refute ReportFindings.reported?([Message.user("review")], @review)

    # Every finding invalid: the tool returned an error, nothing was recorded.
    rejected = [report.("1", [invalid]), Message.tool_result("1", "report_findings", "No...")]
    refute ReportFindings.reported?(rejected, @review)

    # Never answered.
    refute ReportFindings.reported?([report.("2", [finding()])], @review)

    empty = [report.("3", []), Message.tool_result("3", "report_findings", "Recorded no...")]
    assert ReportFindings.reported?(empty, @review)

    partial = [
      report.("4", [finding(), invalid]),
      Message.tool_result("4", "report_findings", "Recorded 1 finding.")
    ]

    assert ReportFindings.reported?(rejected ++ partial, @review)
  end

  describe "report_verdict" do
    test "parses verdicts and reports problems" do
      assert {:ok, %{verdict: :confirmed, evidence: "lib/a.ex:11 ignores it."}} =
               ReportVerdict.parse(%{
                 "verdict" => "confirmed",
                 "evidence" => " lib/a.ex:11 ignores it. "
               })

      assert {:error, "verdict: must be one of confirmed, rejected, uncertain"} =
               ReportVerdict.parse(%{"verdict" => "maybe", "evidence" => "x"})

      assert {:error, "evidence: must not be empty"} =
               ReportVerdict.parse(%{"verdict" => "rejected", "evidence" => "  "})
    end

    test "only works in a verifier run" do
      args = %{"verdict" => "confirmed", "evidence" => "lib/a.ex:11"}

      assert {:ok, text} =
               Tool.execute_tool_call(ReportVerdict, args, %{
                 review: %{stage: :verifier}
               })

      assert text =~ "Verdict recorded: confirmed"

      assert {:error, text} =
               Tool.execute_tool_call(ReportVerdict, args, %{review: @review})

      assert text =~ "only available in review verifier runs"
    end

    test "collect/1 returns the first answered valid verdict" do
      messages = [
        Message.assistant(
          tool_calls: [
            %Call{
              id: "1",
              name: "report_verdict",
              arguments: %{"verdict" => "nope", "evidence" => "x"}
            }
          ]
        ),
        Message.tool_result("1", "report_verdict", "Error: verdict"),
        Message.assistant(
          tool_calls: [
            %Call{
              id: "2",
              name: "report_verdict",
              arguments: %{"verdict" => "rejected", "evidence" => "a:1"}
            }
          ]
        ),
        Message.tool_result("2", "report_verdict", "Verdict recorded"),
        Message.assistant(
          tool_calls: [
            %Call{
              id: "3",
              name: "report_verdict",
              arguments: %{"verdict" => "confirmed", "evidence" => "b:2"}
            }
          ]
        ),
        Message.tool_result("3", "report_verdict", "Verdict recorded")
      ]

      assert {:ok, %{verdict: :rejected, evidence: "a:1"}} = ReportVerdict.collect(messages)
      assert :error = ReportVerdict.collect(Enum.take(messages, 2))
    end
  end
end
