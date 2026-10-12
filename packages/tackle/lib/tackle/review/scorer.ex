defmodule Tackle.Review.Scorer do
  @moduledoc """
  Behaviour of the scoring stage, which recalibrates a verified finding's
  confidence.

  The detector's own confidence is poorly calibrated, and whether a comment
  is worth showing depends on more than correctness: developers ignore
  trivial, speculative, and style comments. A scorer returns the probability
  that the change's author would act on the finding; `Tackle.Review.Rank`
  then applies the profile's thresholds to it.

  The default implementation is `Tackle.Review.Scorer.LLM`, a single
  structured model call. Other implementations, such as a trained
  classifier, implement `c:score/2`.
  """

  alias Tackle.Lib.Usage
  alias Tackle.Review.{Finding, Units}
  alias Tackle.Review.Rules.Rule

  @typedoc """
  What a scorer knows about a finding:

    * `:unit` - the review unit the finding is in;
    * `:rule` - the rule it cites, or `nil`;
    * `:llm` and `:llm_opts` - the model selection and options for scorers
      that call a model (see `Tackle.Review.Scorer.LLM`).
  """
  @type context :: %{
          required(:unit) => Units.unit(),
          required(:rule) => Rule.t() | nil,
          optional(:llm) => Tackle.Lib.LLM.Selection.t(),
          optional(:llm_opts) => keyword(),
          optional(atom()) => term()
        }

  @doc """
  Returns the finding's recalibrated confidence, from 0.0 to 1.0, and the
  token usage of computing it (or `nil`).
  """
  @callback score(Finding.t(), context()) ::
              {:ok, confidence :: float(), Usage.t() | nil} | {:error, term()}

  @doc """
  Calls `scorer` and checks its answer.

  A confidence outside 0..1, any other return value, or a raise is an error,
  so a broken scorer cannot corrupt the ranking.
  """
  @spec score(module(), Finding.t(), context()) ::
          {:ok, float(), Usage.t() | nil} | {:error, term()}
  def score(scorer, %Finding{} = finding, context) when is_atom(scorer) do
    case scorer.score(finding, context) do
      {:ok, confidence, usage}
      when is_number(confidence) and confidence >= 0 and confidence <= 1 ->
        {:ok, confidence / 1, usage}

      {:ok, confidence, _usage} ->
        {:error, {:invalid_confidence, confidence}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_scorer_result, other}}
    end
  rescue
    error -> {:error, {:scorer_crashed, Exception.message(error)}}
  end
end
