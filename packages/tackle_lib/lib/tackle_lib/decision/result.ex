defmodule Tackle.Lib.Decision.Result do
  @moduledoc """
  The result of one decision request.

  `answers` holds exactly one `Tackle.Lib.Decision.Answer` per asked question,
  keyed by question name. `model` is the model that answered, or `nil` for the
  requested one. `usage` is canonical usage: adapters return a
  `Tackle.Lib.Usage` (or a map with its field names), which
  `Tackle.Lib.Decision.decide/3` normalizes.
  """

  alias Tackle.Lib.Decision.{Answer, Question}

  @enforce_keys [:answers]
  defstruct [:model, :usage, answers: %{}]

  @type t :: %__MODULE__{
          model: String.t() | nil,
          answers: %{required(String.t()) => Answer.t()},
          usage: Tackle.Lib.Usage.t() | map() | nil
        }

  @typedoc "Why `validate/2` rejected a result."
  @type invalid_detail ::
          {:model, term()}
          | {:usage, term()}
          | {:answers, term()}
          | {:missing_answer, String.t()}
          | {:unexpected_answer, term()}
          | {:invalid_answer, String.t(), Answer.invalid_field()}

  @doc """
  Checks a result against the questions it answers.

  `model` must be a non-empty string or `nil`, `usage` a map or `nil`, and
  `answers` a map with exactly one answer per question that fits it
  (`Tackle.Lib.Decision.Answer.validate/2`). Returns `{:error, detail}` for
  the first problem.
  """
  @spec validate(t(), [Question.t()]) :: :ok | {:error, invalid_detail()}
  def validate(%__MODULE__{} = result, questions) when is_list(questions) do
    cond do
      not (is_nil(result.model) or (is_binary(result.model) and result.model != "")) ->
        {:error, {:model, result.model}}

      not (is_nil(result.usage) or is_map(result.usage)) ->
        {:error, {:usage, result.usage}}

      not (is_map(result.answers) and not is_struct(result.answers)) ->
        {:error, {:answers, result.answers}}

      true ->
        validate_answers(result.answers, questions)
    end
  end

  defp validate_answers(answers, questions) do
    asked = MapSet.new(questions, & &1.name)

    case Enum.find(Map.keys(answers), &(not MapSet.member?(asked, &1))) do
      nil -> Enum.find_value(questions, :ok, &answer_error(answers, &1))
      name -> {:error, {:unexpected_answer, name}}
    end
  end

  defp answer_error(answers, %Question{name: name} = question) do
    case Map.fetch(answers, name) do
      {:ok, answer} ->
        case Answer.validate(answer, question) do
          :ok -> nil
          {:error, field} -> {:error, {:invalid_answer, name, field}}
        end

      :error ->
        {:error, {:missing_answer, name}}
    end
  end
end
