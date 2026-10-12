defmodule Tackle.Tools.ReportVerdict do
  @moduledoc """
  Structured output tool of the `review-verifier` profile: reports the
  verdict on one candidate finding, before any explanation.

  The verdict is `confirmed` (the stated trigger makes the code fail),
  `rejected` (it does not, or the finding is wrong), or `uncertain`, with
  short `evidence`. The tool keeps no state; the review orchestrator reads
  the first recorded verdict back from the finished run's transcript with
  `collect/1`.

  It only works in a verifier run, whose trusted session context carries
  `:review` with `stage: :verifier` (set by `Tackle.Review.Verifier`).
  """

  use Tackle.Lib.Tool

  alias Tackle.Tools.ReportFindings

  @verdict_atoms %{"confirmed" => :confirmed, "rejected" => :rejected, "uncertain" => :uncertain}
  @verdicts Map.keys(@verdict_atoms) |> Enum.sort()
  @max_evidence 1_000

  tool_name("report_verdict")

  description(
    "Report your verdict on the candidate finding as soon as you have decided, before " <>
      "writing any explanation. confirmed: the stated trigger really makes the code fail; " <>
      "rejected: it does not, the code already handles it, or the finding is wrong; " <>
      "uncertain: the code does not settle it. Only the first verdict counts."
  )

  input do
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

  @typedoc "A validated verdict with its evidence."
  @type report :: %{verdict: verdict(), evidence: String.t()}

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, context) do
    with :ok <- verifier_context(context),
         {:ok, report} <- parse(args) do
      {:ok,
       "Verdict recorded: #{report.verdict}. Add at most one short sentence of justification " <>
         "and stop; do not call report_verdict again."}
    end
  end

  @impl true
  def model_error(reason) when is_binary(reason), do: reason
  def model_error(_reason), do: nil

  @doc "Validates decoded `report_verdict` arguments."
  @spec parse(term()) :: {:ok, report()} | {:error, String.t()}
  def parse(%{"verdict" => verdict, "evidence" => evidence})
      when verdict in @verdicts and is_binary(evidence) do
    evidence = String.trim(evidence)

    cond do
      evidence == "" ->
        {:error, "evidence: must not be empty"}

      String.length(evidence) > @max_evidence ->
        {:error, "evidence: must be at most #{@max_evidence} characters"}

      true ->
        {:ok, %{verdict: Map.fetch!(@verdict_atoms, verdict), evidence: evidence}}
    end
  end

  def parse(%{"verdict" => verdict}) when verdict not in @verdicts,
    do: {:error, "verdict: must be one of #{Enum.join(@verdicts, ", ")}"}

  def parse(_args), do: {:error, "report_verdict requires a verdict and evidence"}

  @doc """
  Returns the first valid verdict recorded during a run, or `:error` when the
  run reported none. Only calls that received a tool result count.
  """
  @spec collect([Tackle.Lib.Message.t()]) :: {:ok, report()} | :error
  def collect(messages) when is_list(messages) do
    answered = ReportFindings.answered_call_ids(messages)

    reports =
      for %{role: :assistant, tool_calls: calls} when is_list(calls) <- messages,
          call <- calls,
          ReportFindings.call_field(call, :name) == "report_verdict",
          MapSet.member?(answered, ReportFindings.call_field(call, :id)),
          {:ok, report} <- [parse(ReportFindings.call_field(call, :arguments))],
          do: report

    case reports do
      [report | _rest] -> {:ok, report}
      [] -> :error
    end
  end

  defp verifier_context(context) do
    case Map.get(context, :review) do
      %{stage: :verifier} -> :ok
      _other -> {:error, "report_verdict is only available in review verifier runs"}
    end
  end
end
