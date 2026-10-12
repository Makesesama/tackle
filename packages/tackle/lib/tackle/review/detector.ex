defmodule Tackle.Review.Detector do
  @moduledoc """
  Detector stage: one delegated `review-detector` run per review unit and
  sample.

  The prompt has two lanes: the rule lane checks the rules that apply to the
  unit (`Tackle.Review.Rules.resolve/3`) and cites their ids, the defect lane
  looks for defects no rule covers. It is deliberately recall-biased; the
  filter, verifier, scorer, and ranking stages provide precision.

  Findings come back through the `report_findings` tool, which validates
  them against the unit (`Tackle.Tools.ReportFindings`). A run that reported
  and then ended with an error, for example on the step limit, keeps its
  findings. With more than one sample the unit is reviewed that many times,
  one run after the other; a unit fails only when none of its samples
  succeeds.
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
    * `:rules` - the rules that apply to the unit (default `[]`);
    * `:allowed` (required) - the lines findings may point at
      (`Tackle.Review.Locations.for_unit/2`);
    * `:index` - every changed line of the change, shown in the change-level
      unit's prompt (default: `:allowed`);
    * `:samples` - how many times to review the unit (default 1);
    * `:model` - a model reference overriding the profile's model;
    * `:capacity_wait` - see `Tackle.Review.Delegation`.
  """
  @type option ::
          {:requester, Delegation.requester()}
          | {:spec, AgentSpec.t()}
          | {:rules, [Rule.t()]}
          | {:allowed, Locations.t()}
          | {:index, Locations.t()}
          | {:samples, pos_integer()}
          | {:model, String.t() | nil}
          | {:capacity_wait, non_neg_integer()}

  @typedoc "The findings of each successful sample, in sample order, and their usage."
  @type result :: %{samples: [[Finding.t()]], usage: Usage.t(), errors: [Delegation.error()]}

  @doc "Returns the name of the detector profile."
  @spec profile() :: String.t()
  def profile, do: @profile

  @doc """
  Reviews one unit and returns the findings of every successful sample.

  Returns `{:error, reason}` with the first sample's error when no sample
  succeeds, and `{:error, :cancelled}` as soon as a sample is cancelled.
  """
  @spec run(Units.unit(), [option()]) :: {:ok, result()} | {:error, Delegation.error() | term()}
  def run(unit, opts) do
    rules = Keyword.get(opts, :rules, [])
    allowed = Keyword.fetch!(opts, :allowed)

    review = %{
      stage: :detector,
      unit_id: unit.id,
      allowed: allowed,
      rule_ids: Enum.map(rules, & &1.id)
    }

    prompt = prompt(unit, rules, Keyword.get(opts, :index, allowed))

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
  # call after its report) has still reviewed the unit: keep its findings.
  defp sample(spec, prompt, review, opts) do
    delegation_opts = Keyword.take(opts, [:model, :capacity_wait])

    case Delegation.run(Keyword.fetch!(opts, :requester), spec, prompt, delegation_opts) do
      {:ok, state} ->
        {:ok, ReportFindings.collect(state.messages, review), Delegation.usage(state)}

      {:error, reason, state} ->
        if ReportFindings.reported?(state.messages, review),
          do: {:ok, ReportFindings.collect(state.messages, review), Delegation.usage(state)},
          else: {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_sample({:ok, findings, usage}, acc),
    do: {:cont, %{acc | samples: [findings | acc.samples], usages: [usage | acc.usages]}}

  defp collect_sample({:error, :cancelled}, _acc), do: {:halt, :cancelled}

  defp collect_sample({:error, reason}, acc),
    do: {:cont, %{acc | errors: [reason | acc.errors]}}

  defp finish(:cancelled), do: {:error, :cancelled}

  defp finish(%{samples: [], errors: errors}), do: {:error, List.last(errors)}

  defp finish(%{samples: samples, usages: usages, errors: errors}) do
    {:ok,
     %{
       samples: Enum.reverse(samples),
       usage: Usage.aggregate(usages),
       errors: Enum.reverse(errors)
     }}
  end

  @doc """
  Builds the detector prompt for a unit: its rules, its rendered diff, and
  the lines its findings may point at. `index` lists every changed line of
  the change for the change-level unit.
  """
  @spec prompt(Units.unit(), [Rule.t()], Locations.t()) :: String.t()
  def prompt(unit, rules, index) do
    [
      intro(unit),
      rules_section(rules),
      "<unit id=\"#{unit.id}\">\n#{unit.rendered}</unit>",
      "Changed lines your findings may point at:\n" <>
        Locations.describe(Locations.for_unit(unit, index)),
      "Review the unit in both lanes, then call report_findings."
    ]
    |> Enum.join("\n\n")
  end

  defp intro(%{kind: :code} = unit) do
    "Review unit #{unit.id} of a code change: changed code of #{unit.path} with its " <>
      "surrounding function. Lines are shown as `[+ n]` (added, new numbering), " <>
      "`[- n]` (removed, old numbering), and `[  n]` (unchanged context). Read other " <>
      "code when you need it to judge the change."
  end

  defp intro(%{kind: :change}) do
    "Review the change as a whole. The other units cover each file's hunks; this " <>
      "change-level unit is for problems single hunks hide: a changed signature, return " <>
      "shape, or behaviour whose callers or tests were not updated, inconsistent changes " <>
      "across files, and the commits' intent not matching the code. Read the changed " <>
      "files you need. Point every finding at changed lines of the file it concerns."
  end

  defp rules_section([]) do
    "No rules apply to this unit: use the defect lane only and set rule_id to null."
  end

  defp rules_section(rules) do
    entries =
      Enum.map_join(rules, "\n", fn rule ->
        ~s(<rule id="#{rule.id}" category="#{rule.category}" severity="#{rule.severity}">\n) <>
          String.trim(rule.body) <> "\n</rule>"
      end)

    "Rules for this unit. Rule-lane findings cite the rule's id as rule_id and use its " <>
      "category; its severity is a default you may lower or raise for the case at hand.\n" <>
      "<rules>\n#{entries}\n</rules>"
  end
end
