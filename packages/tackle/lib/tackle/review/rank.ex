defmodule Tackle.Review.Rank do
  @moduledoc """
  Ranks verified findings and selects the ones to show.

  A finding's score is `severity weight × confidence × support factor`,
  where the support factor is `(1 + support) / (1 + samples)`, capped at 1:
  a finding every sample reported keeps its full score, one reported by a
  single sample out of three keeps half of it.

  Review profiles change thresholds and caps only, never prompts:

  | Profile | Blocking findings | Optional findings | Cap |
  |---|---|---|---|
  | `:quiet` | confirmed, confidence ≥ 0.7 | none | 5 |
  | `:default` | confidence ≥ 0.5 | confirmed, confidence ≥ 0.8 | 15 |
  | `:assertive` | confidence ≥ 0.3 | confidence ≥ 0.3 | 50 |

  The cap applies to the whole change; blocking findings are kept first.

  Verification and scoring cost model runs, so `Tackle.Review` does not
  verify candidates in a lane the profile hides (`visible?/2`), and verifies
  at most `verify_limit/1` candidates by default: twice the cap.
  """

  alias Tackle.Review.Finding

  @profiles [:quiet, :default, :assertive]

  @severity_weights %{blocker: 1.0, high: 0.8, medium: 0.6, low: 0.4}

  @thresholds %{
    quiet: %{
      blocking: %{min_confidence: 0.7, uncertain: false},
      optional: nil,
      cap: 5
    },
    default: %{
      blocking: %{min_confidence: 0.5, uncertain: true},
      optional: %{min_confidence: 0.8, uncertain: false},
      cap: 15
    },
    assertive: %{
      blocking: %{min_confidence: 0.3, uncertain: true},
      optional: %{min_confidence: 0.3, uncertain: true},
      cap: 50
    }
  }

  @typedoc "A review profile."
  @type profile :: :quiet | :default | :assertive

  @typedoc "The thresholds for blocking or optional findings; `nil` hides them all."
  @type lane :: %{min_confidence: float(), uncertain: boolean()} | nil

  @typedoc "A profile's thresholds and cap."
  @type thresholds :: %{blocking: lane(), optional: lane(), cap: pos_integer()}

  @typedoc """
  Why a finding is not shown: its lane is hidden by the profile, it is
  uncertain where the profile wants confirmed findings, its confidence is
  below the threshold, or the cap was reached.
  """
  @type reason :: :hidden_lane | :uncertain | :below_threshold | :over_cap | :over_verify_limit

  @typedoc "Shown findings by lane, best first, and the others with their reasons."
  @type selection :: %{
          blocking: [Finding.t()],
          optional: [Finding.t()],
          dropped: [{Finding.t(), reason()}]
        }

  @doc "Returns the profiles, from the quietest."
  @spec profiles() :: [profile()]
  def profiles, do: @profiles

  @doc "Returns a profile's thresholds and cap."
  @spec thresholds(profile()) :: thresholds()
  def thresholds(profile) when profile in @profiles, do: Map.fetch!(@thresholds, profile)

  @doc """
  Returns a finding's score. `samples` is how many detector samples ran
  per unit (default 1).
  """
  @spec score(Finding.t(), pos_integer()) :: float()
  def score(%Finding{} = finding, samples \\ 1) when is_integer(samples) and samples > 0 do
    support_factor = min((1 + finding.support) / (1 + samples), 1.0)
    Map.fetch!(@severity_weights, finding.severity) * finding.confidence * support_factor
  end

  @doc """
  Returns whether a profile shows a finding's lane (blocking or optional)
  at all.
  """
  @spec visible?(Finding.t(), profile()) :: boolean()
  def visible?(%Finding{blocking: blocking}, profile) when profile in @profiles do
    thresholds = thresholds(profile)
    lane = if blocking, do: thresholds.blocking, else: thresholds.optional
    lane != nil
  end

  @doc """
  Returns how many candidates `Tackle.Review` verifies at most by default
  under a profile: twice its cap.
  """
  @spec verify_limit(profile()) :: pos_integer()
  def verify_limit(profile) when profile in @profiles, do: 2 * thresholds(profile).cap

  @doc """
  Selects the findings to show under a profile, ordered by score (then by
  path and line). Accepts `samples:` for `score/2`.
  """
  @spec select([Finding.t()], profile(), keyword()) :: selection()
  def select(findings, profile, opts \\ []) when is_list(findings) do
    thresholds = thresholds(profile)
    samples = Keyword.get(opts, :samples, 1)

    {eligible, dropped} =
      findings
      |> Enum.sort_by(&{-score(&1, samples), &1.location.path, &1.location.start_line})
      |> Enum.split_with(&(eligibility(&1, thresholds) == :ok))

    dropped = Enum.map(dropped, &{&1, eligibility(&1, thresholds)})
    {blocking, optional} = Enum.split_with(eligible, & &1.blocking)
    {blocking, over_blocking} = Enum.split(blocking, thresholds.cap)
    {optional, over_optional} = Enum.split(optional, thresholds.cap - length(blocking))
    over_cap = Enum.map(over_blocking ++ over_optional, &{&1, :over_cap})

    %{blocking: blocking, optional: optional, dropped: dropped ++ over_cap}
  end

  defp eligibility(finding, thresholds) do
    lane = if finding.blocking, do: thresholds.blocking, else: thresholds.optional

    cond do
      lane == nil -> :hidden_lane
      finding.verdict == :uncertain and not lane.uncertain -> :uncertain
      finding.confidence < lane.min_confidence -> :below_threshold
      true -> :ok
    end
  end
end
