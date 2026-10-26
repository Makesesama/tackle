defmodule Tackle.Lib.Decision.Answer do
  @moduledoc """
  A decision model's answer to one `Tackle.Lib.Decision.Question`.

  `type` is the question's type, and the field of that type holds the answer:

    * `:choice` answers set `choice` to one of the question's options.
    * `:noul` answers set `noul` to the probability (`0..1`) of `true`.
    * `:score` answers set `score` to a number on the question's scale, from
      `0` (the lowest level) to the number of levels minus one. A whole score
      is the selected level; an adapter whose model reports a distribution may
      instead return the probability-weighted average of the levels, which
      can be fractional.

  `probabilities` maps each option (`:choice`), `"true"` or `"false"`
  (`:noul`), or zero-based integer level (`:score`) to its probability when
  the adapter reports a distribution, and is empty otherwise. `confidence` is
  the adapter's confidence (`0..1`) in the answer when reported.

  `Tackle.Lib.Decision.decide/3` checks every answer against its question with
  `validate/2`, so callers receive only answers that fit.
  """

  alias Tackle.Lib.Decision.Question

  @enforce_keys [:type]
  defstruct [:type, :choice, :noul, :score, :confidence, probabilities: %{}]

  @type t :: %__MODULE__{
          type: Question.type(),
          choice: String.t() | nil,
          noul: number() | nil,
          score: number() | nil,
          probabilities: %{optional(String.t() | non_neg_integer()) => number()},
          confidence: number() | nil
        }

  @typedoc "The part of an answer `validate/2` found unusable."
  @type invalid_field ::
          :not_an_answer | :type | :choice | :noul | :score | :probabilities | :confidence

  @noul_keys ["true", "false"]

  @doc """
  Returns the probability of the answer's own choice, falling back to
  `confidence` when no distribution was reported.
  """
  @spec choice_probability(t()) :: number() | nil
  def choice_probability(%__MODULE__{type: :choice, choice: choice} = answer)
      when is_binary(choice) do
    Map.get(answer.probabilities, choice, answer.confidence)
  end

  def choice_probability(%__MODULE__{}), do: nil

  @doc """
  Checks an answer against the question it answers.

  The answer must be an `Answer` of the question's type whose value fits the
  question (an option, a probability, or a score within the scale), whose
  `probabilities` is a map from the question's options, `"true"`/`"false"`,
  or levels to numbers in `0..1`, and whose `confidence` is `nil` or a number
  in `0..1`. Returns `{:error, field}` naming the first part that does not fit.
  """
  @spec validate(term(), Question.t()) :: :ok | {:error, invalid_field()}
  def validate(%__MODULE__{type: type} = answer, %Question{type: type} = question) do
    cond do
      not valid_value?(answer, question) -> {:error, type}
      not valid_probabilities?(answer.probabilities, question) -> {:error, :probabilities}
      not (is_nil(answer.confidence) or probability?(answer.confidence)) -> {:error, :confidence}
      true -> :ok
    end
  end

  def validate(%__MODULE__{}, %Question{}), do: {:error, :type}
  def validate(_other, %Question{}), do: {:error, :not_an_answer}

  defp valid_value?(%__MODULE__{type: :choice, choice: choice}, %Question{criteria: options}),
    do: is_binary(choice) and is_map_key(options, choice)

  defp valid_value?(%__MODULE__{type: :noul, noul: noul}, _question), do: probability?(noul)

  defp valid_value?(%__MODULE__{type: :score, score: score}, %Question{criteria: levels}),
    do: is_number(score) and score >= 0 and score <= length(levels) - 1

  defp valid_probabilities?(probabilities, question)
       when is_map(probabilities) and not is_struct(probabilities) do
    Enum.all?(probabilities, fn {key, probability} ->
      probability?(probability) and probability_key?(key, question)
    end)
  end

  defp valid_probabilities?(_probabilities, _question), do: false

  defp probability_key?(option, %Question{type: :choice, criteria: options}),
    do: is_binary(option) and is_map_key(options, option)

  defp probability_key?(key, %Question{type: :noul}), do: key in @noul_keys

  defp probability_key?(level, %Question{type: :score, criteria: levels}),
    do: is_integer(level) and level >= 0 and level < length(levels)

  defp probability?(value), do: is_number(value) and value >= 0 and value <= 1
end
