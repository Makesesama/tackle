defmodule Tackle.Review.Filter do
  @moduledoc """
  Deterministic filters applied to candidate findings before verification.

  `deterministic/2` drops a finding when:

    * `:not_on_changed_lines` - its location overlaps no changed line;
    * `:unknown_rule` - it cites a rule that was not discovered;
    * `:inactive_rule` - it cites a suppressed or retired rule;
    * `:suppressed_category` - its category is suppressed;
    * `:known` - its fingerprint is among the known ones (already shown or
      dismissed in an earlier review);
    * `:low_confidence` - its confidence is below the floor for its category.

  The confidence floors are deliberately low: they only spare the verifier
  obvious noise. The review profile's thresholds are applied later, by
  `Tackle.Review.Rank`, to the scored confidence.
  """

  alias Tackle.Review.{Finding, Locations}
  alias Tackle.Review.Rules.Rule

  @default_min_confidence %{readability: 0.3, maintainability: 0.3}
  @default_floor 0.2

  @typedoc "Why a finding was dropped."
  @type reason ::
          :not_on_changed_lines
          | :unknown_rule
          | :inactive_rule
          | :suppressed_category
          | :known
          | :low_confidence

  @typedoc """
  Options:

    * `:changed` - the change's changed lines (`Tackle.Review.Locations.index/1`);
      when absent, locations are not checked;
    * `:rules` - every discovered rule, whatever its status; when absent,
      cited rules are not checked;
    * `:suppressed_categories` - categories to drop (default `[]`);
    * `:known_fingerprints` - fingerprints to drop (default none);
    * `:min_confidence` - a floor for every category, or a map of floors by
      category (missing categories use #{@default_floor}). Default:
      `#{inspect(@default_min_confidence)}`, otherwise #{@default_floor}.
  """
  @type option ::
          {:changed, Locations.t()}
          | {:rules, [Rule.t()]}
          | {:suppressed_categories, [Finding.category()]}
          | {:known_fingerprints, Enumerable.t()}
          | {:min_confidence, number() | %{optional(Finding.category()) => number()}}

  @doc "Splits findings into kept ones and dropped ones with their reasons, keeping order."
  @spec deterministic([Finding.t()], [option()]) ::
          {[Finding.t()], [{Finding.t(), reason()}]}
  def deterministic(findings, opts \\ []) when is_list(findings) do
    config = %{
      changed: Keyword.get(opts, :changed),
      rules: opts |> Keyword.get(:rules) |> rules_by_id(),
      suppressed: MapSet.new(Keyword.get(opts, :suppressed_categories, [])),
      known: MapSet.new(Keyword.get(opts, :known_fingerprints, [])),
      min_confidence: Keyword.get(opts, :min_confidence, @default_min_confidence)
    }

    {kept, dropped} =
      Enum.reduce(findings, {[], []}, fn finding, {kept, dropped} ->
        case reason(finding, config) do
          nil -> {[finding | kept], dropped}
          reason -> {kept, [{finding, reason} | dropped]}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(dropped)}
  end

  defp reason(finding, config) do
    cond do
      config.changed != nil and not Locations.changed?(finding.location, config.changed) ->
        :not_on_changed_lines

      rule_reason(finding.rule_id, config.rules) != nil ->
        rule_reason(finding.rule_id, config.rules)

      MapSet.member?(config.suppressed, finding.category) ->
        :suppressed_category

      finding.fingerprint != nil and MapSet.member?(config.known, finding.fingerprint) ->
        :known

      finding.confidence < confidence_floor(config.min_confidence, finding.category) ->
        :low_confidence

      true ->
        nil
    end
  end

  defp rules_by_id(nil), do: nil
  defp rules_by_id(rules) when is_list(rules), do: Map.new(rules, &{&1.id, &1})

  defp rule_reason(nil, _rules), do: nil
  defp rule_reason(_rule_id, nil), do: nil

  defp rule_reason(rule_id, rules) do
    case Map.fetch(rules, rule_id) do
      {:ok, %Rule{status: :active}} -> nil
      {:ok, %Rule{}} -> :inactive_rule
      :error -> :unknown_rule
    end
  end

  defp confidence_floor(value, _category) when is_number(value), do: value

  defp confidence_floor(floors, category) when is_map(floors),
    do: Map.get(floors, category, @default_floor)
end
