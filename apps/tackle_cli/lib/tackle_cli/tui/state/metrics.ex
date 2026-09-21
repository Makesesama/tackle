defmodule Tackle.CLI.TUI.State.Metrics do
  @moduledoc """
  The usage and context metrics held by `Tackle.CLI.TUI.State`.

  `latest_usage` is the newest usage known to the shell, `turn_usages`
  collects the usages reported during the running turn, and `context_usage` is
  the live context pressure. The turn-scoped fields reset together when a turn
  settles or the session is replaced, so they travel as one value.
  """

  @type t :: %__MODULE__{
          latest_usage: Tackle.Lib.Usage.t() | nil,
          turn_usages: [Tackle.Lib.Usage.t()],
          context_usage: Tackle.Lib.ContextUsage.t() | nil
        }

  defstruct latest_usage: nil, turn_usages: [], context_usage: nil

  @doc "Returns the metrics a settled turn leaves behind, keeping `latest_usage`."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = metrics), do: %{metrics | turn_usages: [], context_usage: nil}
end
