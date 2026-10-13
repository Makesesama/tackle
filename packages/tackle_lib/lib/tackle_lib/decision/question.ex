defmodule Tackle.Lib.Decision.Question do
  @moduledoc """
  One question asked of a decision model about a request's state.

  A question has a unique `name`, a `type`, model-facing `instructions`, and
  type-specific `criteria`:

    * `:choice` picks one option. `criteria` is a map of option name to an
      optional description (`nil` when the option name speaks for itself) and
      must contain 2 to 24 options.
    * `:noul` answers yes/no with a probability of `true`. `criteria` is `nil`
      or a map with optional `"true"` and `"false"` descriptions.
    * `:score` rates on an ordered scale. `criteria` is a list of 2 to 24 level
      descriptions, lowest level first.
  """

  @enforce_keys [:name, :type, :instructions]
  defstruct [:name, :type, :instructions, criteria: nil]

  @type type :: :choice | :noul | :score
  @type choice_criteria :: %{required(String.t()) => String.t() | nil}
  @type noul_criteria :: %{optional(String.t()) => String.t()} | nil
  @type score_criteria :: [String.t()]

  @type t :: %__MODULE__{
          name: String.t(),
          type: type(),
          instructions: String.t(),
          criteria: choice_criteria() | noul_criteria() | score_criteria()
        }

  @types [:choice, :noul, :score]
  @min_options 2
  @max_options 24
  @noul_keys ["true", "false"]

  @doc "Builds a `:choice` question from an option => description map."
  @spec choice(String.t(), String.t(), choice_criteria()) :: t()
  def choice(name, instructions, options),
    do: %__MODULE__{name: name, type: :choice, instructions: instructions, criteria: options}

  @doc "Builds a `:noul` (yes/no) question with optional `\"true\"`/`\"false\"` descriptions."
  @spec noul(String.t(), String.t(), noul_criteria()) :: t()
  def noul(name, instructions, criteria \\ nil),
    do: %__MODULE__{name: name, type: :noul, instructions: instructions, criteria: criteria}

  @doc "Builds a `:score` question from level descriptions, lowest level first."
  @spec score(String.t(), String.t(), score_criteria()) :: t()
  def score(name, instructions, levels),
    do: %__MODULE__{name: name, type: :score, instructions: instructions, criteria: levels}

  @doc """
  Validates a question's name, type, instructions, and criteria.

  Returns `{:error, {:invalid_question, name, detail}}` for the first problem.
  """
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{name: name} = question) do
    with :ok <- validate_name(name),
         :ok <- validate_type(question),
         :ok <- validate_instructions(question) do
      validate_criteria(question)
    end
  end

  def validate(other), do: {:error, {:invalid_question, other}}

  @doc """
  Returns the JSON-compatible form of a question (without its name).

  `criteria` is omitted for a `:noul` question without descriptions.
  """
  @spec to_json_map(t()) :: map()
  def to_json_map(%__MODULE__{type: type, instructions: instructions, criteria: criteria}) do
    map = %{"type" => Atom.to_string(type), "instructions" => instructions}
    if is_nil(criteria), do: map, else: Map.put(map, "criteria", criteria)
  end

  defp validate_name(name) do
    if non_empty_string?(name), do: :ok, else: {:error, {:invalid_question, name, :invalid_name}}
  end

  defp validate_type(%__MODULE__{name: name, type: type}) do
    if type in @types, do: :ok, else: {:error, {:invalid_question, name, {:invalid_type, type}}}
  end

  defp validate_instructions(%__MODULE__{name: name, instructions: instructions}) do
    if non_empty_string?(instructions),
      do: :ok,
      else: {:error, {:invalid_question, name, :invalid_instructions}}
  end

  defp validate_criteria(%__MODULE__{type: :choice, name: name, criteria: options})
       when is_map(options) do
    with :ok <- validate_option_count(name, map_size(options)) do
      if Enum.all?(options, fn {option, description} ->
           non_empty_string?(option) and (is_nil(description) or is_binary(description))
         end),
         do: :ok,
         else: invalid_criteria(name)
    end
  end

  defp validate_criteria(%__MODULE__{type: :noul, criteria: nil}), do: :ok

  defp validate_criteria(%__MODULE__{type: :noul, name: name, criteria: criteria})
       when is_map(criteria) do
    if Enum.all?(criteria, fn {key, description} ->
         key in @noul_keys and is_binary(description)
       end),
       do: :ok,
       else: invalid_criteria(name)
  end

  defp validate_criteria(%__MODULE__{type: :score, name: name, criteria: levels})
       when is_list(levels) do
    with :ok <- validate_option_count(name, length(levels)) do
      if Enum.all?(levels, &non_empty_string?/1), do: :ok, else: invalid_criteria(name)
    end
  end

  defp validate_criteria(%__MODULE__{name: name}), do: invalid_criteria(name)

  defp validate_option_count(_name, count) when count in @min_options..@max_options, do: :ok

  defp validate_option_count(name, count),
    do: {:error, {:invalid_question, name, {:option_count, count}}}

  defp invalid_criteria(name), do: {:error, {:invalid_question, name, :invalid_criteria}}

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
