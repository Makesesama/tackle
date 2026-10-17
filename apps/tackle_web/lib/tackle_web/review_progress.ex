defmodule Tackle.Web.ReviewProgress do
  @moduledoc """
  What a review in progress is doing, live on its pages.

  The review job's process reports as it goes (`track/3`, `report/2`): its
  phase, and the events of `Tackle.Review.run/2`, folded into a bounded
  projection as the CLI's review view does: the review's parts (units) with
  their status, and the candidate findings sent to the verifier with their
  verdicts, both newest first; only the latest 200 candidates are kept, and
  the others counted in `omitted`.

  The latest projection is kept in a `Registry` under the request's id,
  owned by the job's process, so a page opened mid-review starts from it
  (`current/1`) and nothing outlives the job. Every change is sent on the
  request's topic (`Tackle.Web.Updates.review/1`) as
  `{Tackle.Web.ReviewProgress, request_id, version, progress | nil}`, where
  `nil` says the job stopped reporting. Versions only grow, so a page that
  read `current/1` after subscribing keeps whichever is newer.

  Progress lives on the node that runs the job; pages on other nodes get
  the messages but not `current/1`.
  """

  import Kernel, except: [apply: 2]

  require Logger

  alias Tackle.Web.Updates

  @max_candidates 200

  @phases [:checkout, :jail, :loading, :reviewing, :storing, :posting]

  @type phase :: :checkout | :jail | :loading | :reviewing | :storing | :posting
  @type unit_status :: :running | :done | :failed
  @type verdict :: :confirmed | :rejected | :uncertain | nil
  @type candidate :: %{
          fingerprint: String.t(),
          title: String.t() | nil,
          severity: atom() | nil,
          path: String.t() | nil,
          start_line: pos_integer() | nil,
          end_line: pos_integer() | nil,
          verdict: verdict()
        }

  @type t :: %__MODULE__{
          phase: phase(),
          total: non_neg_integer() | nil,
          units: [{String.t(), unit_status()}],
          candidates: [candidate()],
          omitted: non_neg_integer(),
          started_at: DateTime.t() | nil,
          version: integer()
        }

  defstruct phase: :checkout,
            total: nil,
            units: [],
            candidates: [],
            omitted: 0,
            started_at: nil,
            version: 0

  @doc false
  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: __MODULE__)

  @doc "The phases of a review job, in order."
  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc "A projection that starts in `phase`."
  @spec new(phase()) :: t()
  def new(phase \\ :checkout) when phase in @phases,
    do: %__MODULE__{phase: phase, started_at: DateTime.utc_now(), version: version()}

  @doc """
  Runs `fun` while the calling process reports the progress of request
  `id`, starting in `phase`; afterwards the progress is gone and pages are
  told so. A process that already tracks `id` just runs `fun`.
  """
  @spec track(Ecto.UUID.t(), phase(), (-> result)) :: result when result: term()
  def track(id, phase, fun) when is_function(fun, 0) do
    progress = new(phase)

    case Registry.register(__MODULE__, id, progress) do
      {:ok, _owner} ->
        publish(id, progress.version, progress)

        try do
          fun.()
        after
          Registry.unregister(__MODULE__, id)
          publish(id, version(), nil)
        end

      {:error, {:already_registered, _pid}} ->
        fun.()
    end
  end

  @doc """
  Applies `event` to the progress the calling process tracks for request
  `id` and tells the pages when it changed. Does nothing for a request the
  process does not track, and never raises: it is the review's `:on_event`.
  """
  @spec report(Ecto.UUID.t(), {:phase, phase()} | Tackle.Review.event()) :: :ok
  def report(id, event) do
    case Registry.update_value(__MODULE__, id, &step(&1, event)) do
      {same, same} -> :ok
      {progress, _old} -> publish(id, progress.version, progress)
      :error -> :ok
    end
  rescue
    error ->
      Logger.warning("review progress not reported: #{inspect(error.__struct__)}")
      :ok
  end

  defp step(progress, event) do
    case apply(progress, event) do
      ^progress -> progress
      changed -> %{changed | version: version()}
    end
  end

  @doc "The progress of request `id`, or nil when no job on this node reports it."
  @spec current(Ecto.UUID.t()) :: t() | nil
  def current(id) do
    case Registry.lookup(__MODULE__, id) do
      [{_pid, progress}] -> progress
      [] -> nil
    end
  end

  defp publish(id, version, progress),
    do: Updates.broadcast(Updates.review(id), {__MODULE__, id, version, progress})

  # Strictly increasing on this node, across processes.
  defp version, do: System.unique_integer([:monotonic, :positive])

  @doc """
  Applies one event: `{:phase, phase}` from the job, or a `Tackle.Review`
  event. Returns the projection unchanged (`===`) for events it does not
  show, such as `{:done, result}`.
  """
  @spec apply(t(), term()) :: t()
  def apply(%__MODULE__{} = progress, {:phase, phase}) when phase in @phases,
    do: %{progress | phase: phase}

  def apply(%__MODULE__{} = progress, {:started, %{units: units}}) when is_integer(units),
    do: %{progress | phase: :reviewing, total: units}

  def apply(%__MODULE__{} = progress, {:unit, id, :started}) when is_binary(id),
    do: put_unit(progress, id, :running)

  def apply(%__MODULE__{} = progress, {:unit, id, :done}) when is_binary(id),
    do: put_unit(progress, id, :done)

  def apply(%__MODULE__{} = progress, {:unit, id, {:failed, _reason}}) when is_binary(id),
    do: put_unit(progress, id, :failed)

  def apply(%__MODULE__{} = progress, {:candidate, %{fingerprint: fingerprint} = finding})
      when is_binary(fingerprint),
      do: put_candidate(progress, candidate(finding))

  def apply(%__MODULE__{} = progress, {:verdict, fingerprint, verdict})
      when is_binary(fingerprint) and verdict in [:confirmed, :rejected, :uncertain] do
    case Enum.find_index(progress.candidates, &(&1.fingerprint == fingerprint)) do
      # Probably one of the candidates no longer kept, already counted.
      nil when progress.omitted > 0 ->
        progress

      nil ->
        put_candidate(progress, %{candidate(%{fingerprint: fingerprint}) | verdict: verdict})

      index ->
        %{
          progress
          | candidates: List.update_at(progress.candidates, index, &%{&1 | verdict: verdict})
        }
    end
  end

  def apply(%__MODULE__{} = progress, _event), do: progress

  # Only what the page shows, as plain data.
  defp candidate(finding) do
    location = Map.get(finding, :location) || %{}

    %{
      fingerprint: finding.fingerprint,
      title: text(Map.get(finding, :title)),
      severity: atom(Map.get(finding, :severity)),
      path: text(Map.get(location, :path)),
      start_line: line(Map.get(location, :start_line)),
      end_line: line(Map.get(location, :end_line)),
      verdict: nil
    }
  end

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp atom(value) when is_atom(value) and not is_nil(value), do: value
  defp atom(_value), do: nil

  defp line(value) when is_integer(value) and value > 0, do: value
  defp line(_value), do: nil

  defp put_unit(progress, id, status) do
    units =
      case List.keyfind(progress.units, id, 0) do
        nil -> [{id, status} | progress.units]
        _found -> List.keyreplace(progress.units, id, 0, {id, status})
      end

    %{progress | units: units}
  end

  defp put_candidate(progress, candidate) do
    candidates = [candidate | progress.candidates]
    overflow = max(length(candidates) - @max_candidates, 0)

    %{
      progress
      | candidates: Enum.take(candidates, @max_candidates),
        omitted: progress.omitted + overflow
    }
  end

  @doc "Unit and candidate counts."
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
  def counts(%__MODULE__{} = progress) do
    units = Enum.map(progress.units, &elem(&1, 1))
    verdicts = Enum.map(progress.candidates, & &1.verdict)

    %{
      total: progress.total,
      running: Enum.count(units, &(&1 == :running)),
      done: Enum.count(units, &(&1 == :done)),
      failed: Enum.count(units, &(&1 == :failed)),
      candidates: length(verdicts) + progress.omitted,
      confirmed: Enum.count(verdicts, &(&1 == :confirmed)),
      rejected: Enum.count(verdicts, &(&1 == :rejected)),
      uncertain: Enum.count(verdicts, &(&1 == :uncertain)),
      verifying: Enum.count(verdicts, &is_nil/1)
    }
  end

  @doc """
  The step of the review proper: `:starting` before its parts are known,
  `:detecting` while parts are unsettled, `:verifying` while a candidate
  waits for its verdict, then `:ranking` (which reports no events).
  """
  @spec stage(t()) :: :starting | :detecting | :verifying | :ranking
  def stage(%__MODULE__{total: nil}), do: :starting

  def stage(%__MODULE__{} = progress) do
    counts = counts(progress)

    cond do
      counts.done + counts.failed < progress.total -> :detecting
      counts.verifying > 0 -> :verifying
      true -> :ranking
    end
  end

  @doc "What the job is doing, in a few words."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{phase: :reviewing} = progress) do
    counts = counts(progress)

    case stage(progress) do
      :starting ->
        "Starting the review"

      :detecting ->
        "Reviewing: #{counts.done + counts.failed} of #{counts.total} parts done"

      :verifying ->
        "Verifying findings: #{counts.candidates - counts.verifying} of #{counts.candidates} checked"

      :ranking ->
        "Ranking the findings"
    end
  end

  def describe(%__MODULE__{phase: phase}), do: phase_label(phase)

  @doc "The words for a phase."
  @spec phase_label(phase()) :: String.t()
  def phase_label(:checkout), do: "Fetching the pull request"
  def phase_label(:jail), do: "Starting the review jail"
  def phase_label(:loading), do: "Reading the change and rules"
  def phase_label(:reviewing), do: "Reviewing"
  def phase_label(:storing), do: "Storing the review"
  def phase_label(:posting), do: "Posting on the pull request"
end
