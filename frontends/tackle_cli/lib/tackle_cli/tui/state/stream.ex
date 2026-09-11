defmodule Tackle.CLI.TUI.State.Stream do
  @moduledoc """
  The live streaming turn held by `Tackle.CLI.TUI.State`.

  Groups the text accumulated for the running turn, its ordered segment
  timeline, and the flush bookkeeping that decides when the panes are redrawn.
  Every field is turn-scoped and reset together when a turn settles, so the
  stream travels as one value instead of five independent state fields.
  """

  @type t :: %__MODULE__{
          thinking: String.t(),
          response: String.t(),
          timeline: [map()],
          message_ids: [String.t()],
          active_message_id: String.t() | nil,
          flush_ref: reference() | nil,
          coalesce?: boolean()
        }

  defstruct thinking: "",
            response: "",
            timeline: [],
            message_ids: [],
            active_message_id: nil,
            flush_ref: nil,
            coalesce?: true

  @doc """
  Returns the stream state a settled turn leaves behind.

  `coalesce?` is a shell-level setting, so it is preserved.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = stream) do
    %{
      stream
      | thinking: "",
        response: "",
        timeline: [],
        message_ids: [],
        active_message_id: nil,
        flush_ref: nil
    }
  end
end
