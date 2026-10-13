defmodule Tackle.CLI.TUI.ReviewProgress do
  @moduledoc """
  Bounded, pure projection of one `/review` run's live progress.

  `Tackle.Review.run/2` reports its pipeline as events (see
  `Tackle.Review`). This module folds them into a model that
  `Tackle.CLI.TUI.ReviewView` draws, in the spirit of
  `Tackle.CLI.TUI.WorkflowProgress`:

    * `units` - every review unit by id, in the order it started, with its
      status (`:running`, `:done`, or `{:failed, reason}`);
    * `total` - how many units the review has, once it started;
    * `candidates` - the findings sent to the verifier, in arrival order,
      each with its verdict (`nil` while verification runs).

  Unit failures and verdicts can arrive for units or candidates the model
  has not seen; they are recorded on first sight rather than dropped. The
  candidate list is bounded: only the latest 200 candidates are kept and
  older ones are counted in `omitted`.
  """

  alias Tackle.Review.Finding

  @max_candidates 200

  @type unit_status :: :running | :done | {:failed, term()}
  @type verdict :: :confirmed | :rejected | :uncertain | nil
  @typedoc """
  A candidate's finding: the full `Tackle.Review.Finding`, or the compact
  map `review_changes` reports (`fingerprint`, `title`, `severity`,
  `category`, `location`), or `nil` when only its verdict was seen.
  """
  @type candidate_finding ::
          Finding.t()
          | %{
              required(:fingerprint) => String.t(),
              required(:title) => String.t(),
              required(:severity) => Finding.severity(),
              required(:location) => Finding.location(),
              optional(atom()) => term()
            }

  @typedoc """
  What `apply/2` folds: a `Tackle.Review` event, or one whose candidate is
  the compact map `review_changes` reports.
  """
  @type event :: Tackle.Review.event() | {:candidate, candidate_finding()}
  @type candidate :: %{
          fingerprint: String.t(),
          finding: candidate_finding() | nil,
          verdict: verdict()
        }
  @type phase :: :starting | :detecting | :verifying | :ranking

  @type t :: %__MODULE__{
          total: non_neg_integer() | nil,
          units: [{String.t(), unit_status()}],
          candidates: [candidate()],
          omitted: non_neg_integer()
        }

  defstruct total: nil, units: [], candidates: [], omitted: 0

  @doc "An empty projection, before the review reported anything."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Applies one `Tackle.Review` event.

  Returns the model unchanged (`===`) for events it does not project, such
  as `{:done, result}`, so callers can skip a redraw.
  """
  @spec apply(t(), event()) :: t()
  def apply(%__MODULE__{} = model, {:started, %{units: units}}) when is_integer(units),
    do: %{model | total: units}

  def apply(%__MODULE__{} = model, {:unit, id, :started}) when is_binary(id),
    do: %{model | units: put_unit(model.units, id, :running)}

  def apply(%__MODULE__{} = model, {:unit, id, :done}) when is_binary(id),
    do: %{model | units: put_unit(model.units, id, :done)}

  def apply(%__MODULE__{} = model, {:unit, id, {:failed, _reason} = failed}) when is_binary(id),
    do: %{model | units: put_unit(model.units, id, failed)}

  def apply(%__MODULE__{} = model, {:candidate, %{fingerprint: fingerprint} = finding})
      when is_binary(fingerprint) do
    put_candidate(model, %{fingerprint: fingerprint, finding: finding, verdict: nil})
  end

  def apply(%__MODULE__{} = model, {:verdict, fingerprint, verdict})
      when is_binary(fingerprint) do
    case Enum.find_index(model.candidates, &(&1.fingerprint == fingerprint)) do
      nil ->
        put_candidate(model, %{fingerprint: fingerprint, finding: nil, verdict: verdict})

      index ->
        %{model | candidates: List.update_at(model.candidates, index, &%{&1 | verdict: verdict})}
    end
  end

  def apply(%__MODULE__{} = model, _event), do: model

  @doc "Unit and candidate counts, for headers and summaries."
  @spec counts(t()) :: %{
          total: non_neg_integer() | nil,
          running: non_neg_integer(),
          done: non_neg_integer(),
          failed: non_neg_integer(),
          candidates: non_neg_integer(),
          confirmed: non_neg_integer(),
          rejected: non_neg_integer(),
          uncertain: non_neg_integer(),
          verifying: non_neg_integer()
        }
  def counts(%__MODULE__{} = model) do
    units = Enum.map(model.units, &elem(&1, 1))
    verdicts = Enum.map(model.candidates, & &1.verdict)

    %{
      total: model.total,
      running: Enum.count(units, &(&1 == :running)),
      done: Enum.count(units, &(&1 == :done)),
      failed: Enum.count(units, &match?({:failed, _reason}, &1)),
      candidates: length(verdicts) + model.omitted,
      confirmed: Enum.count(verdicts, &(&1 == :confirmed)),
      rejected: Enum.count(verdicts, &(&1 == :rejected)),
      uncertain: Enum.count(verdicts, &(&1 == :uncertain)),
      verifying: Enum.count(verdicts, &is_nil/1)
    }
  end

  @doc """
  The pipeline stage the events point at: `:starting` before the units are
  known, `:detecting` while units are unsettled, `:verifying` while a
  candidate waits for its verdict, then `:ranking` (scoring and selection
  report no events of their own).
  """
  @spec phase(t()) :: phase()
  def phase(%__MODULE__{total: nil}), do: :starting

  def phase(%__MODULE__{} = model) do
    counts = counts(model)

    cond do
      counts.done + counts.failed < model.total -> :detecting
      counts.verifying > 0 -> :verifying
      true -> :ranking
    end
  end

  defp put_unit(units, id, status) do
    case List.keyfind(units, id, 0) do
      nil -> units ++ [{id, status}]
      _found -> List.keyreplace(units, id, 0, {id, status})
    end
  end

  defp put_candidate(model, candidate) do
    candidates = model.candidates ++ [candidate]
    overflow = max(length(candidates) - @max_candidates, 0)

    %{
      model
      | candidates: Enum.drop(candidates, overflow),
        omitted: model.omitted + overflow
    }
  end
end
