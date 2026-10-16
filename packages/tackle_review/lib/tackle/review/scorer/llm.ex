defmodule Tackle.Review.Scorer.LLM do
  @moduledoc """
  Default scorer: one structured `Tackle.Lib.LLM` call per batch of
  findings, without tools or an agent loop.

  The model sees each finding, the code it points at (each unit once), and
  curated examples of comments developers do not want ("undesired
  comments"), and returns for each finding the probability that the author
  would act on it. The call uses the `:llm` selection and `:llm_opts` from
  the scorer context.
  """

  @behaviour Tackle.Review.Scorer

  alias Tackle.Lib.LLM
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Review.Finding
  alias Tackle.Review.Rules.Rule

  @undesired [
    "style, formatting, or naming preferences;",
    "speculative \"consider\" or \"might\" remarks without a concrete failure;",
    "restating what the code does, or asking for comments or documentation;",
    "problems a compiler, type checker, or linter reports anyway;",
    "problems in code the change did not touch;",
    "vague concerns without a concrete input or condition that fails;",
    "suggestions whose fix would not fully solve the stated problem."
  ]

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["scores"],
    "properties" => %{
      "scores" => %{
        "type" => "array",
        "description" => "One entry per comment, in any order.",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["id", "confidence"],
          "properties" => %{
            "id" => %{"type" => "string", "description" => "The comment's id, such as C1."},
            "confidence" => %{
              "type" => "number",
              "minimum" => 0,
              "maximum" => 1,
              "description" =>
                "Probability that the author of the change would act on the comment."
            }
          }
        }
      }
    }
  }

  @doc "Returns the JSON Schema of the model's answer."
  @spec schema() :: map()
  def schema, do: @schema

  @impl true
  def score([_ | _] = items, %{llm: %Selection{} = selection} = context) do
    opts =
      [
        messages: [%{role: :user, content: prompt(items)}],
        temperature: 0,
        tools: [],
        tool_choice: "none",
        response_schema_name: "review_scores"
      ]
      |> Keyword.merge(Map.get(context, :llm_opts, []))

    case LLM.generate_with(selection, @schema, opts) do
      {:ok, %{data: data} = response} ->
        with {:ok, confidences} <- confidences(data, ids(items)) do
          {:ok, confidences, response.usage}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def score(_items, _context), do: {:error, :missing_llm}

  # Every comment needs exactly one valid score.
  defp confidences(%{"scores" => scores} = data, ids) when is_list(scores) do
    by_id =
      for %{"id" => id, "confidence" => confidence} <- scores,
          is_number(confidence) and confidence >= 0 and confidence <= 1,
          reduce: %{} do
        acc -> Map.update(acc, id, confidence, fn _first -> :duplicate end)
      end

    confidences = Enum.map(ids, &Map.get(by_id, &1))

    if length(scores) == length(ids) and Enum.all?(confidences, &is_number/1),
      do: {:ok, Enum.map(confidences, &(&1 / 1))},
      else: {:error, {:invalid_score_response, data}}
  end

  defp confidences(data, _ids), do: {:error, {:invalid_score_response, data}}

  defp ids(items), do: Enum.map(1..length(items), &"C#{&1}")

  @doc "Builds the scoring prompt for a batch of findings in their units."
  @spec prompt([Tackle.Review.Scorer.item(), ...]) :: String.t()
  def prompt([_ | _] = items) do
    comments =
      items
      |> Enum.zip(ids(items))
      |> Enum.map_join("\n\n", fn {item, id} -> comment(item, id) end)

    units =
      items
      |> Enum.map(& &1.unit)
      |> Enum.uniq_by(& &1.id)
      |> Enum.map_join("\n", &"<unit id=\"#{&1.id}\">\n#{&1.rendered}</unit>")

    """
    Rate #{count(items)} from an automated code review. For each comment, answer with the \
    probability, from 0 to 1, that the author of the change would act on it: it is \
    correct, it concerns the changed code, and it is worth fixing. Judge each comment on \
    its own, not against the others.

    Comments developers do not want, which deserve a low probability:
    #{Enum.map_join(@undesired, "\n", &("- " <> &1))}

    #{comments}

    The change around them:
    #{units}
    """
  end

  defp count([_item]), do: "one comment"
  defp count(items), do: "#{length(items)} comments"

  defp comment(%{finding: %Finding{location: location} = finding, unit: unit} = item, id) do
    rule_line =
      case item[:rule] do
        %Rule{id: rule_id} -> "Rule: #{rule_id}\n"
        nil -> ""
      end

    """
    <comment id="#{id}" unit="#{unit.id}">
    #{location.path}:#{location.start_line}-#{location.end_line} (#{location.side} side)
    #{rule_line}Category: #{finding.category}; severity: #{finding.severity}; verdict: #{finding.verdict || "unverified"}
    Title: #{finding.title}
    Trigger: #{finding.trigger}
    #{finding.body}
    </comment>\
    """
  end
end
