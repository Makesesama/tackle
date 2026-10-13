defmodule Tackle.Review.Scorer do
  @moduledoc """
  Behaviour of the scoring stage, which recalibrates the confidence of
  verified findings.

  The detector's own confidence is poorly calibrated, and whether a comment
  is worth showing depends on more than correctness: developers ignore
  trivial, speculative, and style comments. A scorer returns, for each
  finding, the probability that the change's author would act on it;
  `Tackle.Review.Rank` then applies the profile's thresholds to it.

  Scoring runs apart from verification, so the verifier's reasoning does
  not bias the score. The orchestrator scores findings in batches
  (`:score_batch` of `Tackle.Review.run/2`) to save model calls.

  The default implementation is `Tackle.Review.Scorer.LLM`, a single
  structured model call per batch. Other implementations, such as a trained
  classifier, implement `c:score/2`.
  """

  alias Tackle.Lib.Usage
  alias Tackle.Review.{Finding, Units}
  alias Tackle.Review.Rules.Rule

  @typedoc """
  One finding to score: the finding, the review unit it is in, and the rule
  it cites (or `nil`).
  """
  @type item :: %{finding: Finding.t(), unit: Units.unit(), rule: Rule.t() | nil}

  @typedoc """
  What a scorer knows besides the findings: `:llm` and `:llm_opts` are the
  model selection and options for scorers that call a model (see
  `Tackle.Review.Scorer.LLM`).
  """
  @type context :: %{
          optional(:llm) => Tackle.Lib.LLM.Selection.t(),
          optional(:llm_opts) => keyword(),
          optional(atom()) => term()
        }

  @doc """
  Returns the recalibrated confidence of each item, from 0.0 to 1.0, in
  item order, and the token usage of computing them (or `nil`).
  """
  @callback score([item(), ...], context()) ::
              {:ok, confidences :: [float()], Usage.t() | nil} | {:error, term()}

  @doc """
  Calls `scorer` for a batch of items and checks its answer.

  A confidence outside 0..1, a wrong number of confidences, any other
  return value, or a raise is an error, so a broken scorer cannot corrupt
  the ranking.
  """
  @spec score(module(), [item(), ...], context()) ::
          {:ok, [float()], Usage.t() | nil} | {:error, term()}
  def score(scorer, [_ | _] = items, context) when is_atom(scorer) do
    case scorer.score(items, context) do
      {:ok, confidences, usage} when is_list(confidences) ->
        check(confidences, length(items), usage)

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_scorer_result, other}}
    end
  rescue
    error -> {:error, {:scorer_crashed, Exception.message(error)}}
  end

  defp check(confidences, count, _usage) when length(confidences) != count,
    do: {:error, {:invalid_confidence_count, length(confidences), count}}

  defp check(confidences, _count, usage) do
    case Enum.find(confidences, &(not (is_number(&1) and &1 >= 0 and &1 <= 1))) do
      nil -> {:ok, Enum.map(confidences, &(&1 / 1)), usage}
      invalid -> {:error, {:invalid_confidence, invalid}}
    end
  end
end
