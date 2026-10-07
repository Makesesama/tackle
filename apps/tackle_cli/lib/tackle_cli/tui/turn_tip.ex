defmodule Tackle.CLI.TUI.TurnTip do
  @moduledoc """
  One expendable hint row shown while a turn runs.

  Ported from codex's turn tips (`turn_tip.rs`, `app/turn_tips.rs`),
  reduced to working tips: once a turn has run longer than `@delay_ms`, a
  single hint row appears below the status row. Each template is exposed at
  most once per session, and activation requires the row to fit the current
  layout, so measuring never counts as exposure. The row is expendable:
  the layout drops it before any other row when the terminal is short.
  """

  alias Tackle.CLI.TUI.{Layout, State, Subagents}

  defstruct current: nil, exposed: []

  @type t :: %__MODULE__{current: String.t() | nil, exposed: [String.t()]}

  @delay_ms 30_000

  @templates [
    "Esc interrupts the running turn",
    "Ctrl+K compacts the context when it fills",
    "/resume reopens a recent session",
    "@ mentions files with fuzzy search",
    "Ctrl+V pastes text or a clipboard image",
    "F4 browses and copies from the transcript",
    "Ctrl+O copies the last final answer",
    "F7 tracks subagent tasks"
  ]

  @doc """
  Returns an updated tip state when `state` is eligible for a new tip.

  A tip becomes eligible once the active turn has run for at least
  `@delay_ms`, no overlay is open, the composer is focused and empty, and no
  tip is already showing. The layout check keeps exposure honest: a template
  is marked exposed only when its row will actually be painted. Returns
  `nil` when no tip should appear, leaving the existing state untouched.
  """
  @spec activate(State.t()) :: t() | nil
  def activate(%State{turn_tip: %__MODULE__{current: nil} = tip} = state) do
    if eligible?(state) and row_fits?(state) do
      case pick(tip) do
        nil -> nil
        template -> %{tip | current: template, exposed: [template | tip.exposed]}
      end
    else
      nil
    end
  end

  def activate(%State{}), do: nil

  @doc "Clears the visible tip, keeping the exposure history."
  @spec dismiss(t()) :: t()
  def dismiss(%__MODULE__{} = tip), do: %{tip | current: nil}

  @doc "The templates a session can still be shown, in display order."
  @spec remaining(t()) :: [String.t()]
  def remaining(%__MODULE__{exposed: exposed}),
    do: Enum.reject(@templates, &(&1 in exposed))

  defp eligible?(%State{
         active_turn: active_turn,
         overlay: nil,
         focus: :composer,
         draft_empty?: true
       })
       when is_map(active_turn) do
    case active_turn do
      %{started_at_ms: started} ->
        System.monotonic_time(:millisecond) - started >= @delay_ms

      _no_clock ->
        false
    end
  end

  defp eligible?(%State{}), do: false

  # The tip row is the last optional row the layout reserves, so a template
  # is only exposed when the terminal is tall enough to paint it.
  defp row_fits?(%State{} = state) do
    {width, height} = state.size

    regions =
      Layout.regions(
        width,
        height,
        state.draft_lines,
        false,
        Subagents.visible?(state),
        not is_nil(state.header_image),
        true
      )

    regions.tip != nil
  end

  defp pick(tip) do
    case remaining(tip) do
      [] -> nil
      templates -> hd(templates)
    end
  end
end
