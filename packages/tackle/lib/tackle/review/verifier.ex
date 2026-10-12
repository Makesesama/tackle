defmodule Tackle.Review.Verifier do
  @moduledoc """
  Verifier stage: one delegated `review-verifier` run per candidate finding.

  The verifier tries to confirm the finding's stated trigger by reading the
  code, and reports its verdict through `report_verdict` before explaining
  anything (conclusion-first verification is faster and more precise than
  reasoning-first). `rejected` findings are dropped by the orchestrator;
  `confirmed` and `uncertain` ones go on to scoring and ranking.
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
    * `:rule` - the rule the finding cites, if any;
    * `:model` - a model reference overriding the profile's model;
    * `:capacity_wait` - see `Tackle.Review.Delegation`.
  """
  @type option ::
          {:requester, Delegation.requester()}
          | {:spec, AgentSpec.t()}
          | {:rule, Rule.t() | nil}
          | {:model, String.t() | nil}
          | {:capacity_wait, non_neg_integer()}

  @typedoc "A verdict with its evidence and the run's usage."
  @type result :: %{
          verdict: ReportVerdict.verdict(),
          evidence: String.t(),
          usage: Usage.t()
        }

  @doc "Returns the name of the verifier profile."
  @spec profile() :: String.t()
  def profile, do: @profile

  @doc """
  Verifies one finding, shown with the unit it is in.

  A verdict reported before the run ended with an error (for example on
  the step limit) still counts. Returns `{:error, :no_verdict}` when the run
  ends without reporting a verdict, or the run's
  `t:Tackle.Review.Delegation.error/0` when it fails without one.
  """
  @spec run(Finding.t(), Units.unit(), [option()]) ::
          {:ok, result()} | {:error, :no_verdict | Delegation.error() | term()}
  def run(%Finding{} = finding, unit, opts) do
    review = %{stage: :verifier, fingerprint: finding.fingerprint, unit_id: unit.id}
    prompt = prompt(finding, unit, Keyword.get(opts, :rule))
    delegation_opts = Keyword.take(opts, [:model, :capacity_wait])

    with {:ok, spec} <- Delegation.put_review_context(Keyword.fetch!(opts, :spec), review) do
      case Delegation.run(Keyword.fetch!(opts, :requester), spec, prompt, delegation_opts) do
        {:ok, state} -> verdict(state, :no_verdict)
        {:error, reason, state} -> verdict(state, reason)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A verdict recorded before the run failed still counts, so a rejected
  # finding stays rejected.
  defp verdict(state, missing) do
    case ReportVerdict.collect(state.messages) do
      {:ok, report} -> {:ok, Map.put(report, :usage, Delegation.usage(state))}
      :error -> {:error, missing}
    end
  end

  @doc "Builds the verifier prompt for a finding, its rule, and its unit."
  @spec prompt(Finding.t(), Units.unit(), Rule.t() | nil) :: String.t()
  def prompt(%Finding{} = finding, unit, rule) do
    location = finding.location

    [
      "Verify this candidate finding from an automated review of a code change.",
      """
      <finding>
      Title: #{finding.title}
      Location: #{location.path}:#{location.start_line}-#{location.end_line} (#{location.side} side)
      Category: #{finding.category}; severity: #{finding.severity}
      Trigger: #{finding.trigger}
      #{finding.body}
      </finding>\
      """,
      rule_section(rule),
      "The change around it (`[+ n]` added, `[- n]` removed, `[  n]` context):\n" <>
        "<unit id=\"#{unit.id}\">\n#{unit.rendered}</unit>",
      "Check whether the trigger really makes the changed code fail, then call " <>
        "report_verdict before writing any explanation."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp rule_section(nil), do: nil

  defp rule_section(%Rule{} = rule),
    do: "It cites this rule:\n<rule id=\"#{rule.id}\">\n#{String.trim(rule.body)}\n</rule>"
end
