defmodule Tackle.Review.Scorer.LLM do
  @moduledoc """
  Default scorer: one structured `Tackle.Lib.LLM` call per finding, without
  tools or an agent loop.

  The model sees the finding, the code it points at, and curated examples of
  comments developers do not want ("undesired comments"), and returns the
  probability that the author would act on the finding. The call uses the
  `:llm` selection and `:llm_opts` from the scorer context.
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
    "required" => ["confidence"],
    "properties" => %{
      "confidence" => %{
        "type" => "number",
        "minimum" => 0,
        "maximum" => 1,
        "description" => "Probability that the author of the change would act on the comment."
      }
    }
  }

  @doc "Returns the JSON Schema of the model's answer."
  @spec schema() :: map()
  def schema, do: @schema

  @impl true
  def score(%Finding{} = finding, %{llm: %Selection{} = selection} = context) do
    opts =
      [
        messages: [%{role: :user, content: prompt(finding, context.unit, context[:rule])}],
        temperature: 0,
        tools: [],
        tool_choice: "none",
        response_schema_name: "review_score"
      ]
      |> Keyword.merge(Map.get(context, :llm_opts, []))

    case LLM.generate_with(selection, @schema, opts) do
      {:ok, %{data: %{"confidence" => confidence}} = response}
      when is_number(confidence) and confidence >= 0 and confidence <= 1 ->
        {:ok, confidence / 1, response.usage}

      {:ok, %{data: data}} ->
        {:error, {:invalid_score_response, data}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def score(%Finding{}, _context), do: {:error, :missing_llm}

  @doc "Builds the scoring prompt for a finding in its unit."
  @spec prompt(Finding.t(), map(), Rule.t() | nil) :: String.t()
  def prompt(%Finding{} = finding, unit, rule) do
    location = finding.location

    rule_line =
      case rule do
        %Rule{id: id} -> "Rule: #{id}\n"
        nil -> ""
      end

    """
    Rate one comment from an automated code review. Answer with the probability, from \
    0 to 1, that the author of the change would act on it: it is correct, it concerns \
    the changed code, and it is worth fixing.

    Comments developers do not want, which deserve a low probability:
    #{Enum.map_join(@undesired, "\n", &("- " <> &1))}

    <comment>
    #{location.path}:#{location.start_line}-#{location.end_line} (#{location.side} side)
    #{rule_line}Category: #{finding.category}; severity: #{finding.severity}; verdict: #{finding.verdict || "unverified"}
    Title: #{finding.title}
    Trigger: #{finding.trigger}
    #{finding.body}
    </comment>

    The change around it:
    <unit id="#{unit.id}">
    #{unit.rendered}</unit>
    """
  end
end
