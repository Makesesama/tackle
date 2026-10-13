defmodule Tackle.Review.Verifier do
  @moduledoc """
  Verifier stage: one delegated `review-verifier` run per batch of candidate
  findings that share a review unit.

  The verifier tries to confirm each finding's stated trigger by reading the
  code, and reports each verdict through `report_verdict` before explaining
  anything (conclusion-first verification is faster and more precise than
  reasoning-first). Findings of one unit share the code the verifier has to
  read, so batching them saves runs; the orchestrator bounds the batch size.
  `rejected` findings are dropped by the orchestrator; `confirmed` and
  `uncertain` ones go on to scoring and ranking.
  """

  alias Tackle.Lib.Usage
  alias Tackle.Review.{Delegation, Finding, Units}
  alias Tackle.Review.Rules.Rule
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Tools.ReportVerdict

  @profile "review-verifier"

  @typedoc """
  Options:

    * `:requester` (required) - the agent the run is delegated from;
    * `:spec` (required) - the `review-verifier` profile spec;
    * `:rules` - the rules by id, to show the ones the findings cite
      (default `%{}`);
    * `:model` - a model reference overriding the profile's model;
    * `:capacity_wait` - see `Tackle.Review.Delegation`.
  """
  @type option ::
          {:requester, Delegation.requester()}
          | {:spec, AgentSpec.t()}
          | {:rules, %{optional(String.t()) => Rule.t()}}
          | {:model, String.t() | nil}
          | {:capacity_wait, non_neg_integer()}

  @typedoc "A verdict with its evidence."
  @type verdict :: %{verdict: ReportVerdict.verdict(), evidence: String.t()}

  @typedoc """
  The outcome of one run: a verdict, or why there is none, per finding (in
  the order given), and the run's usage (`nil` when the run never started).
  """
  @type result :: %{
          verdicts: [{:ok, verdict()} | {:error, :no_verdict | Delegation.error() | term()}],
          usage: Usage.t() | nil
        }

  @doc "Returns the name of the verifier profile."
  @spec profile() :: String.t()
  def profile, do: @profile

  @doc """
  Verifies findings of one unit in a single run.

  A verdict reported before the run ended with an error (for example on the
  step limit) still counts. A finding without a verdict gets
  `{:error, :no_verdict}` when the run ended normally, or the run's
  `t:Tackle.Review.Delegation.error/0` otherwise. Returns
  `{:error, :cancelled}` when the run was cancelled.
  """
  @spec run([Finding.t(), ...], Units.unit(), [option()]) ::
          {:ok, result()} | {:error, :cancelled | term()}
  def run([_ | _] = findings, unit, opts) do
    ids = ids(findings)
    review = %{stage: :verifier, finding_ids: ids, unit_id: unit.id}
    prompt = prompt(findings, unit, Keyword.get(opts, :rules, %{}))
    delegation_opts = Keyword.take(opts, [:model, :capacity_wait])

    with {:ok, spec} <- Delegation.put_review_context(Keyword.fetch!(opts, :spec), review) do
      case Delegation.run(Keyword.fetch!(opts, :requester), spec, prompt, delegation_opts) do
        {:ok, state} ->
          {:ok, result(state, ids, :no_verdict)}

        {:error, reason, state} ->
          {:ok, result(state, ids, reason)}

        {:error, :cancelled} ->
          {:error, :cancelled}

        {:error, reason} ->
          {:ok, %{verdicts: Enum.map(ids, fn _ -> {:error, reason} end), usage: nil}}
      end
    end
  end

  # A verdict recorded before the run failed still counts, so a rejected
  # finding stays rejected.
  defp result(state, ids, missing) do
    reports = ReportVerdict.collect(state.messages, ids)

    verdicts =
      Enum.map(ids, fn id ->
        case Map.fetch(reports, id) do
          {:ok, report} -> {:ok, Map.delete(report, :finding)}
          :error -> {:error, missing}
        end
      end)

    %{verdicts: verdicts, usage: Delegation.usage(state)}
  end

  defp ids(findings), do: Enum.map(1..length(findings), &"F#{&1}")

  @doc """
  Builds the verifier prompt for findings of one unit, with the rules they
  cite (from `rules`, by id).
  """
  @spec prompt([Finding.t(), ...], Units.unit(), %{optional(String.t()) => Rule.t()}) ::
          String.t()
  def prompt([_ | _] = findings, unit, rules) do
    entries =
      findings
      |> Enum.zip(ids(findings))
      |> Enum.map_join("\n\n", fn {finding, id} -> finding_entry(finding, id) end)

    [
      intro(findings),
      entries,
      rules_section(findings, rules),
      "The change around #{if length(findings) == 1, do: "it", else: "them"} " <>
        "(`[+ n]` added, `[- n]` removed, `[  n]` context):\n" <>
        "<unit id=\"#{unit.id}\">\n#{unit.rendered}</unit>",
      outro(findings)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp intro([_finding]),
    do: "Verify this candidate finding from an automated review of a code change."

  defp intro(findings),
    do:
      "Verify these #{length(findings)} candidate findings from an automated review of a " <>
        "code change. Judge each one on its own."

  defp outro([_finding]) do
    "Check whether the trigger really makes the changed code fail, then call " <>
      "report_verdict with finding F1 before writing any explanation."
  end

  defp outro(_findings) do
    "For each finding, check whether its trigger really makes the changed code fail, and " <>
      "call report_verdict with its id as soon as you have decided on it, before writing " <>
      "any explanation."
  end

  defp finding_entry(%Finding{location: location} = finding, id) do
    """
    <finding id="#{id}">
    Title: #{finding.title}
    Location: #{location.path}:#{location.start_line}-#{location.end_line} (#{location.side} side)
    Category: #{finding.category}; severity: #{finding.severity}
    Trigger: #{finding.trigger}
    #{finding.body}
    </finding>\
    """
  end

  defp rules_section(findings, rules) do
    cited =
      findings
      |> Enum.map(& &1.rule_id)
      |> Enum.uniq()
      |> Enum.flat_map(fn id -> List.wrap(Map.get(rules, id)) end)

    case cited do
      [] ->
        nil

      [_ | _] ->
        intro = if length(findings) == 1, do: "It cites this rule:", else: "Cited rules:"

        Enum.join(
          [intro | Enum.map(cited, &"<rule id=\"#{&1.id}\">\n#{String.trim(&1.body)}\n</rule>")],
          "\n"
        )
    end
  end
end
