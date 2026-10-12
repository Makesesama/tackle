defmodule Tackle.CLI.Output.ReviewProgress do
  @moduledoc """
  Line-based progress for `tackle review`.

  `event/2` turns one `Tackle.Review` event into at most one line for
  standard error. Unlike `Tackle.CLI.Output.Progress`, which keeps one live
  spinner line for interactive runs, every line is kept, so the log reads the
  same in a terminal, a CI job, or a Git hook. It tracks how many units are
  done and the candidates sent to the verifier, so verdicts can name the
  finding they are about.
  """

  alias Tackle.CLI.Output.Review, as: ReviewOutput
  alias Tackle.Review.{Delegation, Finding}

  defstruct units: 0, settled: 0, candidates: %{}

  @type t :: %__MODULE__{
          units: non_neg_integer(),
          settled: non_neg_integer(),
          candidates: %{optional(String.t()) => Finding.t()}
        }

  @doc "Returns the progress state before the first event."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Projects one review event onto a progress line, or `nil` when it adds nothing."
  @spec event(t(), Tackle.Review.event()) :: {String.t() | nil, t()}
  def event(%__MODULE__{} = progress, {:started, %{units: 0}}), do: {nil, progress}

  def event(%__MODULE__{} = progress, {:started, %{units: units}}),
    do:
      {"Reviewing #{units} #{if units == 1, do: "unit", else: "units"}…",
       %{progress | units: units}}

  def event(%__MODULE__{} = progress, {:unit, _id, :started}), do: {nil, progress}

  def event(%__MODULE__{} = progress, {:unit, id, :done}) do
    progress = settle(progress)
    {"#{counter(progress)} Reviewed #{unit(id)}", progress}
  end

  def event(%__MODULE__{} = progress, {:unit, id, {:failed, reason}}) do
    progress = settle(progress)
    {"#{counter(progress)} Could not review #{unit(id)}: #{failure(reason)}", progress}
  end

  def event(%__MODULE__{} = progress, {:candidate, %Finding{} = finding}) do
    candidates = Map.put(progress.candidates, finding.fingerprint, finding)
    {"Verifying #{describe(finding)}", %{progress | candidates: candidates}}
  end

  def event(%__MODULE__{} = progress, {:verdict, fingerprint, verdict}) do
    case Map.fetch(progress.candidates, fingerprint) do
      {:ok, finding} -> {"#{verdict_label(verdict)}: #{describe(finding)}", progress}
      :error -> {"#{verdict_label(verdict)}: #{fingerprint}", progress}
    end
  end

  def event(%__MODULE__{} = progress, _event), do: {nil, progress}

  defp settle(progress), do: %{progress | settled: progress.settled + 1}

  defp counter(%__MODULE__{settled: settled, units: units}), do: "[#{settled}/#{units}]"

  defp unit("change"), do: "the change overview"
  defp unit(id), do: id

  defp describe(finding), do: "#{ReviewOutput.location(finding.location)} #{finding.title}"

  defp verdict_label(:confirmed), do: "Confirmed"
  defp verdict_label(:rejected), do: "Rejected"
  defp verdict_label(:uncertain), do: "Unverified"
  defp verdict_label(other), do: to_string(other)

  defp failure(reason) do
    reason |> Delegation.format_error() |> String.split("\n", parts: 2) |> hd()
  end
end
