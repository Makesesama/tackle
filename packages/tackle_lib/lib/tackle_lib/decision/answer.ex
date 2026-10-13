defmodule Tackle.Lib.Decision.Answer do
  @moduledoc """
  A decision model's answer to one `Tackle.Lib.Decision.Question`.

    * `:choice` answers set `choice` to the selected option.
    * `:noul` answers set `noul` to the probability (`0.0..1.0`) of `true`.
    * `:score` answers set `score` to the selected level on the question's
      scale (`0` is the lowest level).

  `probabilities` maps each option (or score level) to its probability when the
  adapter reports a distribution, and `confidence` is the adapter's confidence
  in the answer when reported.
  """

  @enforce_keys [:type]
  defstruct [:type, :choice, :noul, :score, :confidence, probabilities: %{}]

  @type t :: %__MODULE__{
          type: Tackle.Lib.Decision.Question.type(),
          choice: String.t() | nil,
          noul: float() | nil,
          score: number() | nil,
          probabilities: %{optional(String.t() | non_neg_integer()) => number()},
          confidence: number() | nil
        }

  @doc """
  Returns the probability of the answer's own choice, falling back to
  `confidence` when no distribution was reported.
  """
  @spec choice_probability(t()) :: number() | nil
  def choice_probability(%__MODULE__{type: :choice, choice: choice} = answer)
      when is_binary(choice) do
    Map.get(answer.probabilities || %{}, choice, answer.confidence)
  end

  def choice_probability(%__MODULE__{}), do: nil
end
