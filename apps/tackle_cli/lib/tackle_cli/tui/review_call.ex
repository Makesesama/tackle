defmodule Tackle.CLI.TUI.ReviewCall do
  @moduledoc """
  Bounded, pure projection of one `review_changes` tool call.

  `Tackle.Tools.Review` reports a running review as `:tool_progress`
  events whose `:review` data has a `:kind` (see its moduledoc). `apply/2`
  folds them into:

    * `target`, `profile`, `files`, `additions`, `deletions` - what is
      reviewed, once the change is loaded;
    * `progress` - units and candidates as a `Tackle.CLI.TUI.ReviewProgress`,
      the same projection the `/review` overlay draws;
    * `summary` - the final counts, once the review finished.

  The live model only exists while the shell watched the call. A settled
  call is drawn from its result text instead (`parse_result/1`), which is
  also all a resumed session has.
  """

  alias Tackle.CLI.TUI.ReviewProgress

  @type summary :: %{optional(atom()) => non_neg_integer()}

  @type t :: %__MODULE__{
          target: String.t() | nil,
          profile: String.t() | nil,
          files: non_neg_integer() | nil,
          additions: non_neg_integer() | nil,
          deletions: non_neg_integer() | nil,
          progress: ReviewProgress.t(),
          summary: summary() | nil
        }

  defstruct target: nil,
            profile: nil,
            files: nil,
            additions: nil,
            deletions: nil,
            progress: %ReviewProgress{},
            summary: nil

  @typedoc "One finding line of a `review_changes` result."
  @type finding :: %{
          group: :blocking | :optional,
          location: String.t(),
          severity: atom(),
          category: String.t(),
          rule: String.t() | nil,
          title: String.t(),
          unverified?: boolean()
        }

  @typedoc """
  A parsed `review_changes` result: the reviewed `target` and file count
  (`nil` when nothing was reviewed), the blocking and optional counts, how
  many verified findings the profile did not show (`hidden`), the findings
  in result order, and the notes.
  """
  @type result :: %{
          target: String.t() | nil,
          files: non_neg_integer() | nil,
          blocking: non_neg_integer(),
          optional: non_neg_integer(),
          hidden: non_neg_integer(),
          findings: [finding()],
          notes: [String.t()]
        }

  @severities %{
    "blocker" => :blocker,
    "high" => :high,
    "medium" => :medium,
    "low" => :low
  }

  @reviewed ~r/^Reviewed (\d+) files? \((.*)\): (\d+) blocking, (\d+) optional finding\(s\)\.$/u
  @nothing ~r/^Nothing to review in (.*)\.$/u
  @finding ~r/^\d+\. (.+?:\d+(?:-\d+)?)((?: \(removed lines\))?) \[(\w+), (\w+)(?:, rule ([^\]]+))?\] (.+?)((?: \(unverified\))?)$/u

  @doc "An empty projection, before the review reported anything."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Whether the change was loaded, so there is something to draw."
  @spec loaded?(t() | nil) :: boolean()
  def loaded?(%__MODULE__{target: target}), do: is_binary(target)
  def loaded?(_model), do: false

  @doc """
  Applies one `:review` progress map. Unknown or malformed maps leave the
  model unchanged (`===`), so callers can skip a redraw.
  """
  @spec apply(t(), map()) :: t()
  def apply(%__MODULE__{} = model, %{kind: :loaded} = review) do
    %{
      model
      | target: string(review[:target]),
        profile: string(review[:profile]),
        files: count(review[:files]),
        additions: count(review[:additions]),
        deletions: count(review[:deletions])
    }
  end

  def apply(%__MODULE__{} = model, %{kind: :started, units: units}) when is_integer(units),
    do: progress(model, {:started, %{units: units}})

  def apply(%__MODULE__{} = model, %{kind: :unit, unit: id, status: status} = review)
      when is_binary(id) do
    case status do
      :failed -> progress(model, {:unit, id, {:failed, review[:error] || "failed"}})
      status when status in [:started, :done] -> progress(model, {:unit, id, status})
      _other -> model
    end
  end

  def apply(
        %__MODULE__{} = model,
        %{
          kind: :candidate,
          finding:
            %{
              fingerprint: fp,
              title: title,
              severity: severity,
              location: %{path: path, side: side, start_line: first, end_line: last}
            } = finding
        }
      )
      when is_binary(fp) and is_binary(title) and is_atom(severity) and is_binary(path) and
             side in [:new, :old] and is_integer(first) and is_integer(last),
      do: progress(model, {:candidate, finding})

  def apply(%__MODULE__{} = model, %{kind: :verdict, fingerprint: fp, verdict: verdict})
      when is_binary(fp) and verdict in [:confirmed, :rejected, :uncertain],
      do: progress(model, {:verdict, fp, verdict})

  def apply(%__MODULE__{} = model, %{kind: :done, summary: summary}) when is_map(summary),
    do: %{model | summary: summary}

  def apply(%__MODULE__{} = model, _review), do: model

  defp progress(model, event) do
    progress = ReviewProgress.apply(model.progress, event)
    if progress === model.progress, do: model, else: %{model | progress: progress}
  end

  defp string(value) when is_binary(value), do: value
  defp string(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp string(_value), do: nil

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: nil

  @doc """
  Parses the result text of a `review_changes` call, or returns `nil` when
  it is not one (an error, or a format this shell does not know).

      iex> Tackle.CLI.TUI.ReviewCall.parse_result("Nothing to review in staged changes.")
      %{target: "staged changes", files: nil, blocking: 0, optional: 0, hidden: 0, findings: [], notes: []}
  """
  @spec parse_result(String.t() | nil) :: result() | nil
  def parse_result(text) when is_binary(text) do
    if String.valid?(text), do: parse_valid(text)
  end

  def parse_result(_text), do: nil

  defp parse_valid(text) do
    [headline | lines] = String.split(text, "\n")

    case headline(String.trim(headline)) do
      nil -> nil
      result -> body(lines, result)
    end
  end

  defp headline(line) do
    cond do
      match = Regex.run(@reviewed, line) ->
        [_line, files, target, blocking, optional] = match

        %{
          target: target,
          files: String.to_integer(files),
          blocking: String.to_integer(blocking),
          optional: String.to_integer(optional),
          hidden: 0,
          findings: [],
          notes: []
        }

      match = Regex.run(@nothing, line) ->
        [_line, target] = match

        %{
          target: target,
          files: nil,
          blocking: 0,
          optional: 0,
          hidden: 0,
          findings: [],
          notes: []
        }

      true ->
        nil
    end
  end

  # Sections are `Blocking:`, `Optional:`, the verified findings the
  # profile did not show, and `Notes:`; finding lines are numbered (`- ` for
  # hidden ones), their details indented below them. A hidden section's
  # `- … and N more` line counts N.
  defp body(lines, result) do
    {result, _section} =
      Enum.reduce(lines, {result, nil}, fn line, {result, section} ->
        case {line, section} do
          {"Blocking:", _section} ->
            {result, :blocking}

          {"Optional:", _section} ->
            {result, :optional}

          {"Notes:", _section} ->
            {result, :notes}

          {"Verified but not shown under the " <> _profile, _section} ->
            {result, :hidden}

          {"- … and " <> more, :hidden} ->
            {%{result | hidden: result.hidden + more_count(more)}, :hidden}

          {"- " <> _finding, :hidden} ->
            {%{result | hidden: result.hidden + 1}, :hidden}

          {"- " <> note, :notes} ->
            {%{result | notes: [note | result.notes]}, :notes}

          {line, group} when group in [:blocking, :optional] ->
            {finding(result, line, group), group}

          _other ->
            {result, section}
        end
      end)

    %{result | findings: Enum.reverse(result.findings), notes: Enum.reverse(result.notes)}
  end

  defp more_count(text) do
    case Integer.parse(text) do
      {count, _rest} when count > 0 -> count
      _other -> 0
    end
  end

  defp finding(result, line, group) do
    case Regex.run(@finding, line) do
      [_line, location, removed, severity, category, rule, title, unverified] ->
        finding = %{
          group: group,
          location: location <> if(removed == "", do: "", else: " (old)"),
          severity: Map.get(@severities, severity, :low),
          category: category,
          rule: if(rule == "", do: nil, else: rule),
          title: title,
          unverified?: unverified != ""
        }

        %{result | findings: [finding | result.findings]}

      _no_match ->
        result
    end
  end
end
