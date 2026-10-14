defmodule Tackle.Bench.ReviewEval.Score do
  @moduledoc """
  Matches a review's findings against a case's known issues.

  A finding matches an issue when it is not a `:testing` finding (the
  issues are functional bugs, and a "add tests for this" finding next to a
  bug is not a report of it), it is on the new side of the file of one of
  the issue's locations, its line range overlaps that location's lines
  widened by `:slack` lines (default 3), and, when the issue lists
  keywords, its title, body, trigger, or suggestion contains one of them
  (case-insensitive).

  Every finding the review produced is considered, so a missed issue can be
  attributed to the stage that lost it:

    * `:shown` - a shown (blocking or optional) finding matches;
    * `:rejected` - only a finding the verifier rejected matches;
    * `{:dropped, reason}` - only a finding the filters or ranking dropped;
    * `:missed` - no finding matches: the detector did not find it.

  Shown findings that match no issue are counted as `extra`. They are not
  necessarily false positives (a case's issue list is not exhaustive), but
  their number is a noise proxy comparable across variants on the same
  cases.
  """

  alias Tackle.Review.{Finding, Result}

  @default_slack 3

  @type outcome :: :shown | :rejected | {:dropped, atom()} | :missed

  @type t :: %{
          issues: non_neg_integer(),
          found: non_neg_integer(),
          detected: non_neg_integer(),
          shown: non_neg_integer(),
          extra: non_neg_integer(),
          per_issue: [%{id: String.t(), outcome: outcome()}]
        }

  @doc "Scores a result against located issues (see the module documentation)."
  @spec score(Result.t(), [map()], keyword()) :: t()
  def score(%Result{} = result, issues, opts \\ []) do
    slack = Keyword.get(opts, :slack, @default_slack)
    shown = result.blocking ++ result.optional

    tiers = [
      {:shown, shown},
      {:rejected, Enum.map(result.rejected, & &1.finding)}
      | Enum.map(result.dropped, &{{:dropped, &1.reason}, [&1.finding]})
    ]

    per_issue =
      Enum.map(issues, fn issue ->
        outcome =
          Enum.find_value(tiers, :missed, fn {outcome, findings} ->
            if Enum.any?(findings, &matches?(&1, issue, slack)), do: outcome
          end)

        %{id: issue.id, outcome: outcome}
      end)

    extra =
      Enum.count(shown, fn finding -> not Enum.any?(issues, &matches?(finding, &1, slack)) end)

    %{
      issues: length(issues),
      found: Enum.count(per_issue, &(&1.outcome == :shown)),
      detected: Enum.count(per_issue, &(&1.outcome != :missed)),
      shown: length(shown),
      extra: extra,
      per_issue: per_issue
    }
  end

  @doc "Whether a finding matches an issue (see the module documentation)."
  @spec matches?(Finding.t(), map(), non_neg_integer()) :: boolean()
  def matches?(finding, issue, slack \\ @default_slack)

  def matches?(%Finding{category: :testing}, _issue, _slack), do: false

  def matches?(%Finding{location: location} = finding, issue, slack) do
    location.side == :new and
      Enum.any?(issue.locations, fn place ->
        location.path == place.path and location.start_line <= place.end_line + slack and
          location.end_line >= place.start_line - slack
      end) and
      keywords?(finding, issue.keywords)
  end

  defp keywords?(_finding, []), do: true

  defp keywords?(finding, keywords) do
    text =
      [finding.title, finding.body, finding.trigger, finding.suggestion]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> String.downcase()

    Enum.any?(keywords, &String.contains?(text, &1))
  end
end
