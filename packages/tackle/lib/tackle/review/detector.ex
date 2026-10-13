defmodule Tackle.Review.Detector do
  @moduledoc """
  Detector stage: one delegated `review-detector` run per batch of review
  units and sample.

  A batch is either the change-level unit alone or one or more code units
  (`Tackle.Review.Units.batch/2`), so a change of many small files needs few
  runs. The prompt has two lanes: the rule lane checks the rules that apply
  to the units (`Tackle.Review.Rules.resolve/3`) and cites their ids, the
  defect lane looks for defects no rule covers. It is deliberately
  recall-biased; the filter, verifier, scorer, and ranking stages provide
  precision.

  Findings come back through the `report_findings` tool, which validates
  them against the batch's changed lines (`Tackle.Tools.ReportFindings`). A
  run that reported and then ended with an error, for example on the step
  limit, keeps its findings. With more than one sample the batch is reviewed
  that many times, one run after the other; the orchestrator counts a batch
  as failed only when none of its samples succeeds.
  """

  alias Tackle.Lib.Usage
  alias Tackle.Review.{Delegation, Finding, Locations, Units}
  alias Tackle.Review.Rules.Rule
  alias Tackle.Runtime.AgentSpec
  alias Tackle.Tools.ReportFindings

  @profile "review-detector"

  @typedoc """
  Options:

    * `:requester` (required) - the agent the run is delegated from;
    * `:spec` (required) - the `review-detector` profile spec;
    * `:rules` - the rules that apply to the units (default `[]`);
    * `:index` - every changed line of the change, which the change-level
      unit's findings may point at (required for the change-level unit);
    * `:samples` - how many times to review the units (default 1);
    * `:model` - a model reference overriding the profile's model;
    * `:capacity_wait` - see `Tackle.Review.Delegation`.
  """
  @type option ::
          {:requester, Delegation.requester()}
          | {:spec, AgentSpec.t()}
          | {:rules, [Rule.t()]}
          | {:index, Locations.t()}
          | {:samples, pos_integer()}
          | {:model, String.t() | nil}
          | {:capacity_wait, non_neg_integer()}

  @typedoc """
  The findings of each successful sample, in sample order; the errors of
  the failed ones; how many runs were started; and the usage of every run,
  failed ones included when their transcript was available.
  """
  @type result :: %{
          samples: [[Finding.t()]],
          errors: [Delegation.error()],
          runs: non_neg_integer(),
          usage: Usage.t()
        }

  @doc "Returns the name of the detector profile."
  @spec profile() :: String.t()
  def profile, do: @profile

  @doc """
  Returns the lines the findings of a batch may point at: the changes of
  its code units, or every changed line in `index` for the change-level
  unit.
  """
  @spec allowed([Units.unit(), ...], Locations.t()) :: Locations.t()
  def allowed([%{kind: :change} = unit], index), do: Locations.for_unit(unit, index)
  def allowed(units, _index), do: Locations.index(units)

  @doc """
  Reviews a batch of units and returns the findings of every sample.

  Returns `{:ok, result}` even when every sample failed (`samples` is then
  empty and `errors` says why), so the usage of failed runs is not lost.
  Returns `{:error, :cancelled}` as soon as a sample is cancelled.
  """
  @spec run([Units.unit(), ...], [option()]) :: {:ok, result()} | {:error, :cancelled | term()}
  def run([_ | _] = units, opts) do
    rules = Keyword.get(opts, :rules, [])
    index = Keyword.get(opts, :index, %{})

    review = %{
      stage: :detector,
      unit_id: Enum.map_join(units, ",", & &1.id),
      allowed: allowed(units, index),
      rule_ids: Enum.map(rules, & &1.id)
    }

    prompt = prompt(units, rules, review.allowed)

    with {:ok, spec} <- Delegation.put_review_context(Keyword.fetch!(opts, :spec), review) do
      opts
      |> Keyword.get(:samples, 1)
      |> then(&Enum.to_list(1..&1//1))
      |> Enum.reduce_while(%{samples: [], usages: [], errors: []}, fn _sample, acc ->
        spec |> sample(prompt, review, opts) |> collect_sample(acc)
      end)
      |> finish()
    end
  end

  # A run that reported and then failed (on the step limit, or in the model
  # call after its report) has still reviewed the units: keep its findings.
  defp sample(spec, prompt, review, opts) do
    delegation_opts = Keyword.take(opts, [:model, :capacity_wait])

    case Delegation.run(Keyword.fetch!(opts, :requester), spec, prompt, delegation_opts) do
      {:ok, state} ->
        {:ok, ReportFindings.collect(state.messages, review), Delegation.usage(state)}

      {:error, reason, state} ->
        if ReportFindings.reported?(state.messages, review),
          do: {:ok, ReportFindings.collect(state.messages, review), Delegation.usage(state)},
          else: {:error, reason, Delegation.usage(state)}

      {:error, reason} ->
        {:error, reason, nil}
    end
  end

  defp collect_sample({:ok, findings, usage}, acc),
    do: {:cont, %{acc | samples: [findings | acc.samples], usages: [usage | acc.usages]}}

  defp collect_sample({:error, :cancelled, _usage}, _acc), do: {:halt, :cancelled}

  defp collect_sample({:error, reason, usage}, acc),
    do: {:cont, %{acc | errors: [reason | acc.errors], usages: [usage | acc.usages]}}

  defp finish(:cancelled), do: {:error, :cancelled}

  defp finish(%{samples: samples, usages: usages, errors: errors}) do
    {:ok,
     %{
       samples: Enum.reverse(samples),
       errors: Enum.reverse(errors),
       runs: length(samples) + length(errors),
       usage: usages |> Enum.reject(&is_nil/1) |> Usage.aggregate()
     }}
  end

  @doc """
  Builds the detector prompt for a batch of units: their rules, their
  rendered diffs, and the lines their findings may point at (`allowed/2`).
  """
  @spec prompt([Units.unit(), ...], [Rule.t()], Locations.t()) :: String.t()
  def prompt(units, rules, allowed) do
    [
      intro(units),
      rules_section(rules),
      Enum.map_join(units, "\n\n", &"<unit id=\"#{&1.id}\">\n#{&1.rendered}</unit>"),
      "Changed lines your findings may point at:\n" <> Locations.describe(allowed),
      outro(units)
    ]
    |> Enum.join("\n\n")
  end

  @line_format "Lines are shown as `[+ n]` (added, new numbering), `[- n]` (removed, old " <>
                 "numbering), and `[  n]` (unchanged context). Read other code when you need " <>
                 "it to judge the change."

  defp intro([%{kind: :change}]) do
    "Review the change as a whole. The other units cover each file's hunks; this " <>
      "change-level unit is for problems single hunks hide: a changed signature, return " <>
      "shape, or behaviour whose callers or tests were not updated, inconsistent changes " <>
      "across files, and the commits' intent not matching the code. Read the changed " <>
      "files you need. Point every finding at changed lines of the file it concerns."
  end

  defp intro([%{kind: :code} = unit]) do
    "Review unit #{unit.id} of a code change: changed code of #{unit.path} with its " <>
      "surrounding function. " <> @line_format
  end

  defp intro(units) do
    "Review these #{length(units)} units of a code change, each the changed code of one " <>
      "file with its surrounding function. Review every unit. " <> @line_format
  end

  defp outro([_unit]), do: "Review the unit in both lanes, then call report_findings."

  defp outro(_units) do
    "Review the units in both lanes, then call report_findings once with the findings " <>
      "of all units."
  end

  defp rules_section([]) do
    "No rules apply here: use the defect lane only and set rule_id to null."
  end

  defp rules_section(rules) do
    entries =
      Enum.map_join(rules, "\n", fn rule ->
        ~s(<rule id="#{rule.id}" category="#{rule.category}" severity="#{rule.severity}">\n) <>
          String.trim(rule.body) <> "\n</rule>"
      end)

    "Rules to check. Rule-lane findings cite the rule's id as rule_id and use its " <>
      "category; its severity is a default you may lower or raise for the case at hand.\n" <>
      "<rules>\n#{entries}\n</rules>"
  end
end
