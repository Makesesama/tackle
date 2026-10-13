defmodule Tackle.Lib.Decision.Request do
  @moduledoc """
  A decision request: the questions to answer about one observed state.

  `state` is the text or JSON-compatible data (map or list) the decision model
  judges. `model` is the adapter-local decision model id; `Tackle.Lib.Decision.decide/3`
  fills it from the selection.

  `validate/1` enforces the provider-neutral limits before anything is sent:
  1 to 64 uniquely named, valid questions, a non-empty state, and an encoded
  request (`to_json_map/1` as JSON) of at most 64 KiB.
  """

  alias Tackle.Lib.Decision.Question

  @enforce_keys [:state, :questions]
  defstruct [:model, :state, :questions]

  @type state :: String.t() | map() | list()
  @type t :: %__MODULE__{
          model: String.t() | nil,
          state: state(),
          questions: [Question.t()]
        }

  @max_questions 64
  @max_encoded_bytes 64 * 1024

  @doc "Builds a request for `state` and `questions`."
  @spec new(state(), [Question.t()], String.t() | nil) :: t()
  def new(state, questions, model \\ nil),
    do: %__MODULE__{model: model, state: state, questions: questions}

  @doc "Maximum number of questions per request."
  @spec max_questions() :: pos_integer()
  def max_questions, do: @max_questions

  @doc "Maximum size in bytes of the JSON-encoded request."
  @spec max_encoded_bytes() :: pos_integer()
  def max_encoded_bytes, do: @max_encoded_bytes

  @doc """
  Validates a request before it is sent to an adapter.

  Returns `{:error, {:invalid_decision_request, detail}}`, where `detail` is one
  of `:invalid_model`, `:empty_state`, `:invalid_state`, `{:question_count, n}`,
  `{:duplicate_question, name}`, `{:invalid_question, ...}`, or
  `{:request_too_large, bytes}`.
  """
  @spec validate(term()) :: :ok | {:error, {:invalid_decision_request, term()}}
  def validate(%__MODULE__{} = request) do
    with :ok <- validate_model(request.model),
         :ok <- validate_state(request.state),
         :ok <- validate_questions(request.questions),
         {:ok, bytes} <- encoded_size(request) do
      if bytes <= @max_encoded_bytes, do: :ok, else: invalid({:request_too_large, bytes})
    end
  end

  def validate(_other), do: invalid(:not_a_request)

  @doc """
  Returns the JSON-compatible form of a request.

      %{"model" => model, "state" => state,
        "questions" => %{name => %{"type" => "choice", "instructions" => ..., "criteria" => ...}}}

  This form bounds the request size; adapters may use it as the starting point
  of their wire format.
  """
  @spec to_json_map(t()) :: map()
  def to_json_map(%__MODULE__{model: model, state: state, questions: questions}) do
    %{
      "model" => model,
      "state" => state,
      "questions" => Map.new(questions, &{&1.name, Question.to_json_map(&1)})
    }
  end

  defp validate_model(model) when is_binary(model) and model != "", do: :ok
  defp validate_model(_model), do: invalid(:invalid_model)

  defp validate_state(state) when state in ["", [], %{}], do: invalid(:empty_state)

  defp validate_state(state) when is_binary(state) do
    if String.trim(state) == "", do: invalid(:empty_state), else: :ok
  end

  defp validate_state(state) when is_map(state) or is_list(state), do: :ok
  defp validate_state(_state), do: invalid(:invalid_state)

  defp validate_questions(questions) when is_list(questions) do
    count = length(questions)

    if count in 1..@max_questions do
      validate_each_question(questions)
    else
      invalid({:question_count, count})
    end
  end

  defp validate_questions(_questions), do: invalid({:question_count, 0})

  defp validate_each_question(questions) do
    Enum.reduce_while(questions, {:ok, MapSet.new()}, fn question, {:ok, seen} ->
      case Question.validate(question) do
        :ok ->
          if MapSet.member?(seen, question.name),
            do: {:halt, invalid({:duplicate_question, question.name})},
            else: {:cont, {:ok, MapSet.put(seen, question.name)}}

        {:error, reason} ->
          {:halt, invalid(reason)}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Maps and lists must be JSON-encodable; anything else (tuples, pids, ...)
  # cannot cross a provider boundary.
  defp encoded_size(request) do
    {:ok, request |> to_json_map() |> JSON.encode_to_iodata!() |> IO.iodata_length()}
  rescue
    _exception -> invalid(:invalid_state)
  end

  defp invalid(detail), do: {:error, {:invalid_decision_request, detail}}
end
