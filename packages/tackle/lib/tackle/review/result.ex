defmodule Tackle.Review.Result do
  @moduledoc """
  The result of `Tackle.Review.run/2`.

    * `blocking` and `optional` - the findings to show, best first;
    * `rejected` - candidates the verifier rejected, with its evidence; not
      shown, but kept so the rejection rate can be inspected later;
    * `dropped` - candidates removed by a deterministic filter
      (`Tackle.Review.Filter`) or by the profile's thresholds and cap
      (`Tackle.Review.Rank`), with the reason;
    * `summary` - see `t:summary/0`;
    * `usage` - the token usage of every model call of the review.
  """

  alias Tackle.Lib.Usage
  alias Tackle.Review.{Filter, Finding, Rank, Units}

  defstruct blocking: [],
            optional: [],
            rejected: [],
            dropped: [],
            summary: nil,
            usage: nil

  @typedoc """
  `:blocking` when a blocking finding is shown, `:optional` when only
  optional ones are, `:clean` when none is.
  """
  @type verdict :: :blocking | :optional | :clean

  @typedoc """
  What was reviewed and how it went:

    * `profile` and `samples` - the settings used;
    * `units` - how many units were reviewed (code units plus the
      change-level unit);
    * `files` - the reviewed paths; `skipped` - files not reviewed and why;
    * `failed_units` - units whose detector runs all failed without
      reporting anything;
    * `incomplete_units` - units whose detector runs all stopped early
      (`reason` says why) after reporting findings, which are kept;
    * `detected` - findings reported by the detector, before merging;
    * `candidates` - findings sent to the verifier;
    * `confirmed`, `uncertain`, `rejected` - verifier outcomes;
    * `verification_failures` - candidates whose verifier run failed; they
      are kept as uncertain;
    * `scoring_failures` - findings that kept the detector's confidence
      because the scorer failed;
    * `blocking` and `optional` - how many findings are shown;
    * `verdict` - see `t:verdict/0`;
    * `warnings` - rule discovery and resolution warnings.
  """
  @type summary :: %{
          profile: Rank.profile(),
          samples: pos_integer(),
          units: non_neg_integer(),
          files: [String.t()],
          skipped: [Units.skipped()],
          failed_units: [%{unit: String.t(), reason: term()}],
          incomplete_units: [%{unit: String.t(), reason: term()}],
          detected: non_neg_integer(),
          candidates: non_neg_integer(),
          confirmed: non_neg_integer(),
          uncertain: non_neg_integer(),
          rejected: non_neg_integer(),
          verification_failures: [%{fingerprint: String.t(), reason: term()}],
          scoring_failures: [%{fingerprint: String.t(), reason: term()}],
          blocking: non_neg_integer(),
          optional: non_neg_integer(),
          verdict: verdict(),
          warnings: [String.t()]
        }

  @type t :: %__MODULE__{
          blocking: [Finding.t()],
          optional: [Finding.t()],
          rejected: [%{finding: Finding.t(), evidence: String.t()}],
          dropped: [%{finding: Finding.t(), reason: Filter.reason() | Rank.reason()}],
          summary: summary(),
          usage: Usage.t()
        }

  @doc "Returns the shown findings, blocking first."
  @spec findings(t()) :: [Finding.t()]
  def findings(%__MODULE__{blocking: blocking, optional: optional}), do: blocking ++ optional

  @doc """
  Returns the verified findings the profile did not show, in rank order, with
  why (`Tackle.Review.Rank`): below its confidence threshold, uncertain
  where it wants confirmed findings, over its cap, or in a lane it hides.

  These passed verification (confirmed or uncertain), unlike the
  candidates a deterministic filter dropped, which were never verified.
  """
  @spec hidden(t()) :: [%{finding: Finding.t(), reason: Rank.reason()}]
  def hidden(%__MODULE__{dropped: dropped}) do
    Enum.filter(dropped, &(&1.finding.verdict in [:confirmed, :uncertain]))
  end

  @doc "Returns the overall verdict for the shown findings."
  @spec verdict([Finding.t()], [Finding.t()]) :: verdict()
  def verdict([_ | _], _optional), do: :blocking
  def verdict([], [_ | _]), do: :optional
  def verdict([], []), do: :clean
end
