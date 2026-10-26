defmodule Tackle.Workflow.Classify do
  @moduledoc """
  Translation between Lua values and `Tackle.Lib.Decision` data for
  `tackle.classify`.

  The functions take values already decoded from the Lua VM, where a table is a
  list of `{key, value}` pairs, and return plain Elixir data or a message for a
  Lua error. They hold no state and perform no I/O; `Tackle.Workflow.API`
  calls them around the decision request.

  ## Questions

  The questions table maps each question name to its spec:

      {
        verdict = {type = "choice", instructions = "Is the change safe?",
                   criteria = {safe = "No behaviour change", risky = "Needs review"}},
        tests = {type = "noul", instructions = "Does the change add tests?"},
        quality = {type = "score", instructions = "Rate the patch.",
                   criteria = {"poor", "fair", "good"}}
      }

    * `choice` criteria map option names to descriptions, or list option
      names when they speak for themselves;
    * `noul` (yes/no) criteria are optional, with `"true"` and `"false"`
      descriptions;
    * `score` criteria list the levels, lowest first.

  Questions are sent in name order; `Tackle.Lib.Decision.Question` documents
  the limits.

  ## Answers

  A successful classification returns one answer table per question name.
  Every answer carries `type` and `probabilities` (possibly empty), and
  `confidence` when the model reports one:

    * `choice` answers set `choice` and `probability`, the probability of that
      choice (falling back to `confidence`);
    * `noul` answers set `noul`, the probability of `true`;
    * `score` answers set `score` on the 1-based scale of `criteria`, so a
      whole score indexes the level list. A score may be fractional when the
      model reports a weighted average, and `probabilities` is keyed by level.
  """

  alias Tackle.Lib.Decision.{Answer, Question, Result, Selection}

  @spec_keys ["type", "instructions", "criteria"]
  @types %{"choice" => :choice, "noul" => :noul, "score" => :score}

  @doc "Converts a decoded state (string or table) into JSON-compatible data."
  @spec state(term()) :: {:ok, String.t() | map() | list()} | {:error, String.t()}
  def state(state) when is_binary(state), do: {:ok, state}

  def state(state) do
    if table?(state) do
      case json(state) do
        {:ok, data} -> {:ok, data}
        :error -> {:error, "state must hold only strings, numbers, booleans, and tables"}
      end
    else
      {:error, "state must be a string or a table"}
    end
  end

  @doc "Converts a decoded questions table into validated decision questions."
  @spec questions(term()) :: {:ok, [Question.t()]} | {:error, String.t()}
  def questions([_ | _] = pairs) do
    if table?(pairs) do
      Enum.reduce_while(pairs, {:ok, []}, fn {name, spec}, {:ok, acc} ->
        case question(name, spec) do
          {:ok, question} -> {:cont, {:ok, [question | acc]}}
          {:error, message} -> {:halt, {:error, message}}
        end
      end)
      |> case do
        {:ok, questions} -> {:ok, Enum.sort_by(questions, & &1.name)}
        error -> error
      end
    else
      {:error, "questions must be a table of name = spec"}
    end
  end

  def questions(_other), do: {:error, "questions must be a non-empty table of name = spec"}

  @doc """
  The Lua-facing table for a classification result.

  `Tackle.Lib.Decision.decide/3` has already checked that the result holds
  one fitting answer per question. `tokens` is what the call added to the
  workflow's usage.
  """
  @spec result_table(Result.t(), Selection.t(), non_neg_integer()) :: map()
  def result_table(%Result{answers: answers}, %Selection{ref: ref}, tokens) do
    %{
      "ok" => true,
      "status" => "ok",
      "model" => ref,
      "tokens" => tokens,
      "answers" => Map.new(answers, fn {name, answer} -> {name, answer_table(answer)} end)
    }
  end

  @doc "The Lua-facing table for a classification the model could not answer."
  @spec failure_table(term(), non_neg_integer()) :: map()
  def failure_table(reason, tokens \\ 0)

  def failure_table(:cancelled, tokens),
    do: %{
      "ok" => false,
      "status" => "cancelled",
      "text" => "classification cancelled",
      "tokens" => tokens
    }

  def failure_table(reason, tokens),
    do: %{
      "ok" => false,
      "status" => "error",
      "text" => "classification failed: #{describe(reason)}",
      "tokens" => tokens
    }

  # Questions -----------------------------------------------------------------------

  defp question(name, spec) when is_binary(name) do
    with {:ok, spec} <- spec_map(name, spec),
         {:ok, type} <- question_type(name, spec),
         {:ok, criteria} <- criteria(name, type, Map.get(spec, "criteria")) do
      question = %Question{
        name: name,
        type: type,
        instructions: Map.get(spec, "instructions"),
        criteria: criteria
      }

      case Question.validate(question) do
        :ok -> {:ok, question}
        {:error, reason} -> {:error, invalid_question(name, reason)}
      end
    end
  end

  defp question(name, _spec), do: {:error, "question names must be strings, got #{inspect(name)}"}

  defp spec_map(name, spec) do
    if table?(spec) do
      spec = Map.new(spec)

      case Map.keys(spec) -- @spec_keys do
        [] -> {:ok, spec}
        unknown -> {:error, "question #{inspect(name)} has unknown keys: #{format_keys(unknown)}"}
      end
    else
      {:error, "question #{inspect(name)} must be a table with type and instructions"}
    end
  end

  defp question_type(name, spec) do
    case Map.fetch(@types, Map.get(spec, "type")) do
      {:ok, type} ->
        {:ok, type}

      :error ->
        {:error,
         "question #{inspect(name)} needs type \"choice\", \"noul\", or \"score\", " <>
           "got #{inspect(Map.get(spec, "type"))}"}
    end
  end

  # A Lua table cannot hold `nil` values, so choice options without
  # descriptions are listed by name.
  defp criteria(name, :choice, criteria) do
    cond do
      not table?(criteria) ->
        criteria_error(name, "choice criteria must be a table of options")

      match?({:ok, _}, sequence(criteria)) ->
        {:ok, options} = sequence(criteria)
        {:ok, Map.new(options, &{&1, nil})}

      true ->
        {:ok, Map.new(criteria)}
    end
  end

  defp criteria(_name, :noul, nil), do: {:ok, nil}

  defp criteria(name, :noul, criteria) do
    if table?(criteria),
      do: {:ok, Map.new(criteria, fn {key, value} -> {noul_key(key), value} end)},
      else: criteria_error(name, "noul criteria must be a table of true/false descriptions")
  end

  defp criteria(name, :score, criteria) do
    case sequence(criteria) do
      {:ok, levels} -> {:ok, levels}
      :error -> criteria_error(name, "score criteria must be a list of levels, lowest first")
    end
  end

  defp noul_key(true), do: "true"
  defp noul_key(false), do: "false"
  defp noul_key(key), do: key

  defp criteria_error(name, message), do: {:error, "question #{inspect(name)}: #{message}"}

  defp invalid_question(name, {:invalid_question, _name, :invalid_instructions}),
    do: "question #{inspect(name)} needs non-empty instructions"

  defp invalid_question(name, {:invalid_question, _name, :invalid_name}),
    do: "question #{inspect(name)} needs a non-empty name"

  defp invalid_question(name, {:invalid_question, _name, {:option_count, count}}),
    do: "question #{inspect(name)} needs 2 to 24 options or levels, got #{count}"

  defp invalid_question(name, {:invalid_question, _name, :invalid_criteria}),
    do: "question #{inspect(name)} has invalid criteria"

  defp invalid_question(name, reason),
    do: "question #{inspect(name)} is invalid: #{inspect(reason)}"

  # Answers -------------------------------------------------------------------------

  defp answer_table(%Answer{type: :choice} = answer) do
    %{
      "type" => "choice",
      "choice" => answer.choice,
      "probability" => Answer.choice_probability(answer),
      "probabilities" => answer.probabilities,
      "confidence" => answer.confidence
    }
    |> compact()
  end

  defp answer_table(%Answer{type: :noul} = answer) do
    %{
      "type" => "noul",
      "noul" => answer.noul,
      "probabilities" => answer.probabilities,
      "confidence" => answer.confidence
    }
    |> compact()
  end

  # Lua scales are 1-based, so level 0 (the lowest) becomes 1.
  defp answer_table(%Answer{type: :score} = answer) do
    probabilities = Map.new(answer.probabilities, fn {level, p} -> {level + 1, p} end)

    %{
      "type" => "score",
      "score" => answer.score + 1,
      "probabilities" => probabilities,
      "confidence" => answer.confidence
    }
    |> compact()
  end

  defp compact(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

  # Lua tables ----------------------------------------------------------------------

  # A decoded table is a list of `{key, value}` pairs; `{}` decodes to `[]`.
  defp table?(value), do: is_list(value) and Enum.all?(value, &match?({_key, _value}, &1))

  # Decoded keys are in map order, which is not sorted once a table has more
  # than 32 keys, so sort before checking for exactly the keys 1..n.
  defp sequence([_ | _] = value) do
    if table?(value) do
      sorted = List.keysort(value, 0)

      if sorted |> Enum.with_index(1) |> Enum.all?(fn {{key, _}, index} -> key === index end),
        do: {:ok, Enum.map(sorted, fn {_key, element} -> element end)},
        else: :error
    else
      :error
    end
  end

  defp sequence(_value), do: :error

  defp json(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: {:ok, value}

  defp json([]), do: {:ok, []}

  defp json(value) do
    cond do
      not table?(value) ->
        :error

      match?({:ok, _}, sequence(value)) ->
        {:ok, elements} = sequence(value)
        json_all(elements, &json/1)

      true ->
        case json_all(value, &json_pair/1) do
          {:ok, pairs} -> object(pairs)
          :error -> :error
        end
    end
  end

  defp json_all(entries, convert) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case convert.(entry) do
        {:ok, data} -> {:cont, {:ok, [data | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp json_pair({key, value}) do
    with {:ok, key} <- json_key(key),
         {:ok, data} <- json(value),
         do: {:ok, {key, data}}
  end

  # Keys that collide once stringified (`1` and `"1"`) would drop a value.
  defp object(pairs) do
    map = Map.new(pairs)
    if map_size(map) == length(pairs), do: {:ok, map}, else: :error
  end

  defp json_key(key) when is_binary(key), do: {:ok, key}
  defp json_key(key) when is_number(key) or is_boolean(key), do: {:ok, to_string(key)}
  defp json_key(_key), do: :error

  defp format_keys(keys), do: keys |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(reason), do: inspect(reason)
end
