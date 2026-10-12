defmodule Tackle.Review.Finding do
  @moduledoc """
  A review finding: its fields, the input schema the detector fills in,
  validation of that input, and a stable fingerprint.

  The detector reports the fields of `t:input/0` (see `json_schema/0`);
  `from_input/2` validates them and builds the struct. The remaining fields
  are derived later in the pipeline: `support` (how many samples found the
  finding), `verdict` (set by the verifier; rejected findings are dropped),
  and `fingerprint` (see `fingerprint/2`).

  Categories and severities are shared with `Tackle.Review.Rules`.
  """

  alias Tackle.Review.Diff

  @categories [:correctness, :security, :performance, :maintainability, :readability, :testing]
  @severities [:blocker, :high, :medium, :low]
  @sides [:new, :old]

  @max_title 80
  @max_trigger 500
  @max_body 1_000
  @max_suggestion 2_000

  @fingerprint_version "tackle-review-finding/1"

  @enforce_keys [
    :title,
    :category,
    :severity,
    :blocking,
    :confidence,
    :location,
    :trigger,
    :body
  ]
  defstruct [
    :title,
    :category,
    :severity,
    :blocking,
    :confidence,
    :location,
    :trigger,
    :body,
    rule_id: nil,
    suggestion: nil,
    support: 1,
    verdict: nil,
    fingerprint: nil
  ]

  @typedoc "What a finding or rule is about."
  @type category ::
          :correctness | :security | :performance | :maintainability | :readability | :testing

  @typedoc "How bad the problem is, from `:blocker` down to `:low`."
  @type severity :: :blocker | :high | :medium | :low

  @typedoc "The side of the diff: new (added and context lines) or old (removed lines)."
  @type side :: :new | :old

  @typedoc "Repository-relative path and an inclusive line range on one side of the diff."
  @type location :: %{
          path: String.t(),
          side: side(),
          start_line: pos_integer(),
          end_line: pos_integer()
        }

  @typedoc "The verifier's verdict, or `nil` before verification."
  @type verdict :: :confirmed | :uncertain | nil

  @typedoc """
  A finding.

    * `title` - imperative summary, at most 80 characters;
    * `blocking` - a functional problem (`true`) or an optional improvement;
    * `confidence` - between 0.0 and 1.0;
    * `rule_id` - the rule the finding applies, `nil` for defect findings;
    * `trigger` - the concrete input or condition under which the code fails;
    * `body` - one short paragraph;
    * `suggestion` - a replacement that fully fixes the issue, or `nil`.
  """
  @type t :: %__MODULE__{
          title: String.t(),
          category: category(),
          severity: severity(),
          blocking: boolean(),
          confidence: float(),
          rule_id: String.t() | nil,
          location: location(),
          trigger: String.t(),
          body: String.t(),
          suggestion: String.t() | nil,
          support: pos_integer(),
          verdict: verdict(),
          fingerprint: String.t() | nil
        }

  @typedoc "Decoded JSON input as described by `json_schema/0` (string keys)."
  @type input :: %{optional(String.t()) => term()}

  @typedoc """
  Validation options:

    * `:rule_ids` - the rule ids the finding may cite; when given, any other
      `rule_id` is an error.
  """
  @type option :: {:rule_ids, [String.t()]}

  @doc "Returns the categories, in documentation order."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc "Returns the severities, from most to least severe."
  @spec severities() :: [severity()]
  def severities, do: @severities

  @doc """
  Returns the JSON Schema of one finding as reported by the detector.

  Every property is listed as required, with `rule_id` and `suggestion`
  nullable, so the schema also works with providers' strict structured
  output modes. Derived fields (`support`, `verdict`, `fingerprint`) are not
  part of it.
  """
  @spec json_schema() :: map()
  def json_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => [
        "title",
        "category",
        "severity",
        "blocking",
        "confidence",
        "rule_id",
        "location",
        "trigger",
        "body",
        "suggestion"
      ],
      "properties" => %{
        "title" => %{
          "type" => "string",
          "maxLength" => @max_title,
          "description" => "Imperative summary of the problem, at most #{@max_title} characters."
        },
        "category" => %{"type" => "string", "enum" => Enum.map(@categories, &Atom.to_string/1)},
        "severity" => %{"type" => "string", "enum" => Enum.map(@severities, &Atom.to_string/1)},
        "blocking" => %{
          "type" => "boolean",
          "description" =>
            "True for a functional problem that should be fixed before merging; " <>
              "false for an optional improvement."
        },
        "confidence" => %{
          "type" => "number",
          "minimum" => 0,
          "maximum" => 1,
          "description" => "Probability that the problem is real, from 0 to 1."
        },
        "rule_id" => %{
          "type" => ["string", "null"],
          "description" => "Id of the rule this finding applies; null for other defects."
        },
        "location" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["path", "side", "start_line", "end_line"],
          "properties" => %{
            "path" => %{"type" => "string", "description" => "Repository-relative file path."},
            "side" => %{
              "type" => "string",
              "enum" => Enum.map(@sides, &Atom.to_string/1),
              "description" =>
                "\"new\" for added or unchanged lines (new numbering), \"old\" for removed lines."
            },
            "start_line" => %{"type" => "integer", "minimum" => 1},
            "end_line" => %{"type" => "integer", "minimum" => 1}
          }
        },
        "trigger" => %{
          "type" => "string",
          "maxLength" => @max_trigger,
          "description" => "The concrete input or condition under which the code fails."
        },
        "body" => %{
          "type" => "string",
          "maxLength" => @max_body,
          "description" => "One short paragraph explaining the problem."
        },
        "suggestion" => %{
          "type" => ["string", "null"],
          "maxLength" => @max_suggestion,
          "description" => "Replacement code that fully fixes the issue, or null."
        }
      }
    }
  end

  @doc """
  Validates decoded detector input and builds a finding.

  Returns every problem at once, as `"field: message"` strings meant to be
  sent back to the model for correction. Strings are trimmed; `rule_id` and
  `suggestion` may be omitted, `null`, or blank; unknown keys are ignored.
  Accepts `t:option/0`.
  """
  @spec from_input(term(), [option()]) :: {:ok, t()} | {:error, [String.t()]}
  def from_input(input, opts \\ [])

  def from_input(input, opts) when is_map(input) do
    rule_ids = Keyword.get(opts, :rule_ids)

    fields = [
      title: text(input, "title", @max_title),
      category: enum(input, "category", @categories),
      severity: enum(input, "severity", @severities),
      blocking: boolean(input, "blocking"),
      confidence: confidence(input, "confidence"),
      rule_id: rule_id(input, "rule_id", rule_ids),
      location: location(input, "location"),
      trigger: text(input, "trigger", @max_trigger),
      body: text(input, "body", @max_body),
      suggestion: optional_text(input, "suggestion", @max_suggestion)
    ]

    case for({_key, {:error, errors}} <- fields, do: errors) do
      [] -> {:ok, struct!(__MODULE__, for({key, {:ok, value}} <- fields, do: {key, value}))}
      errors -> {:error, List.flatten(errors)}
    end
  end

  def from_input(_input, _opts), do: {:error, ["finding: must be an object"]}

  @doc """
  Returns the text of the diff lines a location covers, such as
  `unit.lines` of a `Tackle.Review.Units` unit.

  The new side covers added and context lines by new line number, the old
  side removed and context lines by old line number.
  """
  @spec excerpt([Diff.line()], location()) :: String.t()
  def excerpt(lines, %{side: side, start_line: first, end_line: last}) when is_list(lines) do
    kinds = if side == :new, do: [:add, :context], else: [:remove, :context]

    lines
    |> Enum.filter(fn line ->
      number = Map.fetch!(line, side)
      line.kind in kinds and is_integer(number) and number >= first and number <= last
    end)
    |> Enum.map_join("\n", & &1.text)
  end

  @doc """
  Computes a fingerprint that identifies the same problem across runs.

  It hashes the path, the rule id (or the category for defect findings), the
  normalized title (lowercase, punctuation and repeated whitespace removed),
  and the normalized code excerpt (blank lines dropped, whitespace collapsed),
  so it survives line shifts, reindentation, and rewording of punctuation.
  Line numbers are deliberately not part of it. Returns 32 lowercase hex
  characters.
  """
  @spec fingerprint(t(), String.t()) :: String.t()
  def fingerprint(%__MODULE__{} = finding, excerpt) when is_binary(excerpt) do
    key =
      if finding.rule_id,
        do: "rule:" <> finding.rule_id,
        else: "category:" <> Atom.to_string(finding.category)

    [@fingerprint_version, finding.location.path, key, normalize_title(finding.title)]
    |> Kernel.++([normalize_code(excerpt)])
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  @doc "Sets `fingerprint` from `fingerprint/2`."
  @spec put_fingerprint(t(), String.t()) :: t()
  def put_fingerprint(%__MODULE__{} = finding, excerpt),
    do: %{finding | fingerprint: fingerprint(finding, excerpt)}

  ## Validation

  defp parse_enum(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp parse_enum(_value, _allowed), do: :error

  defp text(input, key, max) do
    case Map.get(input, key) do
      value when is_binary(value) -> nonempty_text(String.trim(value), key, max)
      nil -> error(key, "is required")
      _value -> error(key, "must be a string")
    end
  end

  defp nonempty_text("", key, _max), do: error(key, "must not be empty")
  defp nonempty_text(value, key, max), do: limit(value, key, max)

  defp optional_text(input, key, max) do
    case Map.get(input, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> if blank?(value), do: {:ok, nil}, else: text(input, key, max)
      _value -> error(key, "must be a string or null")
    end
  end

  defp limit(value, key, max) do
    if String.length(value) <= max,
      do: {:ok, value},
      else: error(key, "must be at most #{max} characters")
  end

  defp enum(input, key, allowed) do
    case Map.get(input, key) do
      nil ->
        error(key, "is required")

      value ->
        case parse_enum(value, allowed) do
          {:ok, atom} -> {:ok, atom}
          :error -> error(key, "must be one of #{Enum.join(allowed, ", ")}")
        end
    end
  end

  defp boolean(input, key) do
    case Map.get(input, key) do
      value when is_boolean(value) -> {:ok, value}
      nil -> error(key, "is required")
      _value -> error(key, "must be true or false")
    end
  end

  defp confidence(input, key) do
    case Map.get(input, key) do
      value when is_number(value) and value >= 0 and value <= 1 -> {:ok, value / 1}
      nil -> error(key, "is required")
      _value -> error(key, "must be a number from 0 to 1")
    end
  end

  defp rule_id(input, key, rule_ids) do
    case Map.get(input, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        value = String.trim(value)

        cond do
          value == "" ->
            {:ok, nil}

          is_nil(rule_ids) or value in rule_ids ->
            {:ok, value}

          rule_ids == [] ->
            error(key, "unknown rule #{inspect(value)}; no rules apply, use null")

          true ->
            error(
              key,
              "unknown rule #{inspect(value)}; use one of #{Enum.join(rule_ids, ", ")} or null"
            )
        end

      _value ->
        error(key, "must be a string or null")
    end
  end

  defp location(input, key) do
    case Map.get(input, key) do
      %{} = location ->
        location_parts(
          path: location_path(location),
          side: location_side(location),
          start_line: line_number(location, "start_line"),
          end_line: line_number(location, "end_line")
        )

      nil ->
        error(key, "is required")

      _value ->
        error(key, "must be an object")
    end
  end

  defp location_parts(parts) do
    case for({_key, {:error, errors}} <- parts, do: errors) do
      [] -> location_range(Map.new(for {key, {:ok, value}} <- parts, do: {key, value}))
      errors -> {:error, List.flatten(errors)}
    end
  end

  defp location_path(location) do
    case Map.get(location, "path") do
      value when is_binary(value) ->
        if blank?(value),
          do: error("location.path", "must not be empty"),
          else: {:ok, String.trim(value)}

      nil ->
        error("location.path", "is required")

      _value ->
        error("location.path", "must be a string")
    end
  end

  defp location_side(location) do
    case Map.get(location, "side") do
      nil ->
        error("location.side", "is required")

      value ->
        case parse_enum(value, @sides) do
          {:ok, side} -> {:ok, side}
          :error -> error("location.side", "must be new or old")
        end
    end
  end

  defp line_number(location, key) do
    case Map.get(location, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      nil -> error("location." <> key, "is required")
      _value -> error("location." <> key, "must be a positive integer")
    end
  end

  defp location_range(%{start_line: first, end_line: last} = location) when last >= first,
    do: {:ok, location}

  defp location_range(_location),
    do: error("location.end_line", "must not be less than location.start_line")

  defp error(key, message), do: {:error, ["#{key}: #{message}"]}

  defp blank?(value), do: String.trim(value) == ""

  ## Fingerprint normalization

  defp normalize_title(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  defp normalize_code(code) do
    code
    |> String.replace_invalid()
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.split(~r/\s+/u, trim: true) |> Enum.join(" ")))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end
end
