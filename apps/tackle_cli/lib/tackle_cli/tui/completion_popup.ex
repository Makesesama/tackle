defmodule Tackle.CLI.TUI.CompletionPopup do
  @moduledoc """
  Shared chrome for popups anchored above the composer.

  Both inline completions — `@` file mentions and `/` commands — float in the
  same place: a panel directly above the input bar, sized to the rows they
  show. This module computes that geometry once so the two popups cannot
  drift apart; each caller keeps its own title, rows, and empty-state hint.

  The chrome starts with a `Clear` widget: the popup floats over live
  transcript content, and a panel's style fill only recolors the cells behind
  it — it does not erase their symbols — so without the clear the transcript's
  text would show through between the popup's rows and merge with them.
  """

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Clear}
  alias Tackle.CLI.TUI.Theme

  @doc """
  Anchors a popup showing `rows` content rows above the composer's rectangle.

  Returns the chrome widgets — the `Clear` and the opaque panel, each with the
  popup's rectangle — plus the inner content rectangle, or `:skip` when the
  terminal is too short to fit the popup above the input bar.
  """
  @spec anchor(String.t(), pos_integer(), Rect.t()) ::
          {[{Clear.t() | Block.t(), Rect.t()}], Rect.t()} | :skip
  def anchor(title, rows, %Rect{} = composer) when is_integer(rows) and rows > 0 do
    height = rows + 2

    if composer.y < height do
      :skip
    else
      rect = %Rect{
        x: composer.x,
        y: composer.y - height,
        width: max(composer.width, 12),
        height: height
      }

      inner = %Rect{
        x: rect.x + 1,
        y: rect.y + 1,
        width: max(rect.width - 2, 0),
        height: max(rect.height - 2, 0)
      }

      clear = {%Clear{}, rect}
      panel = {Theme.surface_panel_block(title, :accent), rect}

      {[clear, panel], inner}
    end
  end
end
