defmodule Tackle.CLI.TUI.State.Metrics do
  @moduledoc """
  The usage and context metrics held by `Tackle.CLI.TUI.State`.

  `latest_usage` is the newest usage known to the shell, `turn_usages`
  collects the usages reported during the running turn, `turn_compactions`
  where in them a compaction rewrote the context, and `context_usage` is the
  live context pressure. The turn-scoped fields reset together when a turn
  settles or the session is replaced, so they travel as one value.
  """

  @type t :: %__MODULE__{
          latest_usage: Tackle.Lib.Usage.t() | nil,
          turn_usages: [Tackle.Lib.Usage.t()],
          turn_compactions: [non_neg_integer()],
          context_usage: Tackle.Lib.ContextUsage.t() | nil
        }

  defstruct latest_usage: nil, turn_usages: [], turn_compactions: [], context_usage: nil

  @doc "Returns the metrics a settled turn leaves behind, keeping `latest_usage`."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = metrics),
    do: %{metrics | turn_usages: [], turn_compactions: [], context_usage: nil}

  @doc "Records that a compaction rewrote the context after the turn's usages so far."
  @spec compacted(t()) :: t()
  def compacted(%__MODULE__{} = metrics),
    do: %{metrics | turn_compactions: metrics.turn_compactions ++ [length(metrics.turn_usages)]}

  @doc """
  Returns the turn's usages split at its compactions, oldest first.

  The first list continues the context of the settled conversation (it may
  be empty); each later one starts after a compaction.
  """
  @spec turn_segments(t()) :: [[Tackle.Lib.Usage.t()], ...]
  def turn_segments(%__MODULE__{turn_usages: usages, turn_compactions: compactions}) do
    {segments, rest, _taken} =
      Enum.reduce(compactions, {[], usages, 0}, fn at, {segments, rest, taken} ->
        {segment, rest} = Enum.split(rest, at - taken)
        {[segment | segments], rest, at}
      end)

    Enum.reverse([rest | segments])
  end
end
