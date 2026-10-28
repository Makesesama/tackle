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
  call is drawn from its result text instead
  (`Tackle.Tools.Review.parse_result/1`), which is also all a resumed
  session has.
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
end
