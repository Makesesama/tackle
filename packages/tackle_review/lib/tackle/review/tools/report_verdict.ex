defmodule Tackle.Review.Tools.ReportVerdict do
  @moduledoc """
  Structured output tool of the `review-verifier` profile: reports the
  verdict on one candidate finding, before any explanation.

  A verifier run checks one or more findings, each with an id such as `F1`;
  the model calls the tool once per finding as soon as it has decided on
  it. The verdict is `confirmed` (the stated trigger makes the code fail),
  `rejected` (it does not, or the finding is wrong), or `uncertain`, with
  short `evidence`. The tool keeps no state; the review orchestrator reads
  the first recorded verdict of each finding back from the finished run's
  transcript with `collect/2`.

  It only works in a verifier run, whose trusted session context carries
  `:review` with `stage: :verifier` and the run's `finding_ids` (set by
  `Tackle.Review.Verifier`).
  """

  use Tackle.Lib.Tool

  alias Tackle.Lib.Message
  alias Tackle.Lib.Tool.Call
  alias Tackle.Review.Tools.ReportFindings

  @verdict_atoms %{"confirmed" => :confirmed, "rejected" => :rejected, "uncertain" => :uncertain}
  @verdicts Map.keys(@verdict_atoms) |> Enum.sort()
  @max_evidence 1_000

  tool_name("report_verdict")

  description(
    "Report your verdict on one candidate finding as soon as you have decided on it, " <>
      "before writing any explanation; call it once per finding. confirmed: the stated " <>
      "trigger really makes the code fail; rejected: it does not, the code already handles " <>
      "it, or the finding is wrong; uncertain: the code does not settle it. Only the first " <>
      "verdict on each finding counts."
  )

  input do
    field(:finding, :string, required: true, description: "The finding's id, such as F1")

    field(:verdict, :string,
      required: true,
      enum: @verdicts,
      description: "confirmed, rejected, or uncertain"
    )

    field(:evidence, :string,
      required: true,
      description: "One or two sentences of evidence, citing file:line"
    )
  end

  @typedoc "A verifier's verdict."
  @type verdict :: :confirmed | :rejected | :uncertain

  @typedoc "A validated verdict on the finding with id `finding`, with its evidence."
  @type report :: %{finding: String.t(), verdict: verdict(), evidence: String.t()}

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, context) do
    with {:ok, ids} <- verifier_context(context),
         {:ok, report} <- parse(args, ids) do
      {:ok, reply(report, ids)}
    end
  end

  defp reply(report, [_id]) do
    "Verdict recorded: #{report.verdict}. Add at most one short sentence of justification " <>
      "and stop; do not call report_verdict again."
  end

  defp reply(report, _ids) do
    "Verdict on #{report.finding} recorded: #{report.verdict}. Go on with the findings you " <>
      "have not decided yet; once every finding has a verdict, add at most one short " <>
      "sentence and stop."
  end

  @doc """
  Validates decoded `report_verdict` arguments against the ids of the
  run's findings.
  """
  @spec parse(term(), [String.t()]) :: {:ok, report()} | {:error, String.t()}
  def parse(%{"finding" => finding, "verdict" => verdict, "evidence" => evidence}, ids)
      when is_binary(finding) and verdict in @verdicts and is_binary(evidence) do
    evidence = String.trim(evidence)
    finding = String.trim(finding)

    cond do
      finding not in ids ->
        {:error, "finding: must be one of #{Enum.join(ids, ", ")}"}

      evidence == "" ->
        {:error, "evidence: must not be empty"}

      String.length(evidence) > @max_evidence ->
        {:error, "evidence: must be at most #{@max_evidence} characters"}

      true ->
        {:ok,
         %{finding: finding, verdict: Map.fetch!(@verdict_atoms, verdict), evidence: evidence}}
    end
  end

  def parse(%{"verdict" => verdict}, _ids) when verdict not in @verdicts,
    do: {:error, "verdict: must be one of #{Enum.join(@verdicts, ", ")}"}

  def parse(_args, _ids),
    do: {:error, "report_verdict requires a finding, a verdict, and evidence"}

  @doc """
  Returns the first valid verdict recorded for each finding during a run,
  by finding id; findings without one are absent. Only calls that received
  a tool result count.
  """
  @spec collect([Tackle.Lib.Message.t()], [String.t()]) :: %{optional(String.t()) => report()}
  def collect(messages, ids) when is_list(messages) and is_list(ids) do
    answered = ReportFindings.answered_call_ids(messages)

    reports =
      for %Message{role: :assistant, tool_calls: calls} <- messages,
          %Call{name: "report_verdict", id: id, arguments: arguments} <- calls,
          MapSet.member?(answered, id),
          {:ok, report} <- [parse(arguments, ids)],
          do: report

    Enum.reduce(reports, %{}, fn report, acc -> Map.put_new(acc, report.finding, report) end)
  end

  defp verifier_context(context) do
    case Map.get(context, :review) do
      %{stage: :verifier, finding_ids: [_ | _] = ids} -> {:ok, ids}
      _other -> {:error, "report_verdict is only available in review verifier runs"}
    end
  end
end
