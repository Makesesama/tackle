defmodule Tackle.CLI.Widgets.Input do
  @moduledoc """
  Tackle-owned native multiline editor with grapheme-safe soft wrapping.

  `new/0` returns a local, opaque mutable resource; do not persist it or pass it
  to another node. Editing and painting use Tackle's NIF, not ExRatatui's
  textarea resource. The host owns submission, paste normalization, and shortcut
  precedence. `set_value/2` resets undo/redo; `insert_str/2` is one undoable edit.

  Arrow keys move by grapheme or visual row. Home/End (Ctrl+A/E) move within a
  logical line; Alt+B/F and Ctrl+B/F move by whitespace-delimited word;
  Ctrl+W deletes the preceding word, and Ctrl+U/R undo/redo. Unknown modified
  chords are ignored. Wrapping preserves all source whitespace and reserves a
  visible insertion cell. Undo retains at most 100 snapshots / 8 MiB.

  Paint replaces control characters (tabs display as spaces) without changing
  the draft. A reversed cell is the caret; it is hidden when `focused` is false.
  Rendering is limited to 65,536 cells, like the other native surfaces.
  """

  alias ExRatatui.Layout.Rect
  alias Tackle.CLI.{Native, Widgets.Surface}
  alias Tackle.CLI.TUI.MessageView

  defstruct [:state, :block, placeholder: "", focused: true]

  @type t :: %__MODULE__{
          state: reference() | nil,
          block: ExRatatui.Widgets.Block.t() | nil,
          placeholder: String.t(),
          focused: boolean()
        }

  @spec new() :: reference()
  defdelegate new(), to: Native, as: :input_new
  @spec get_value(reference()) :: String.t()
  defdelegate get_value(state), to: Native, as: :input_get_value
  @spec set_value(reference(), String.t()) :: :ok
  defdelegate set_value(state, value), to: Native, as: :input_set_value
  @spec insert_str(reference(), String.t()) :: :ok
  defdelegate insert_str(state, value), to: Native, as: :input_insert_str
  @spec handle_key(reference(), String.t(), [String.t()], non_neg_integer()) :: :ok
  defdelegate handle_key(state, code, modifiers, width), to: Native, as: :input_handle_key
  @spec rows(reference(), non_neg_integer()) :: pos_integer()
  defdelegate rows(state, width), to: Native, as: :input_rows

  @doc "Renders the native editor inside an optional ExRatatui block."
  @spec render(t(), Rect.t()) :: [{struct(), Rect.t()}]
  def render(%__MODULE__{} = widget, %Rect{} = rect) do
    {blocks, inner} =
      if widget.block do
        {[{widget.block, rect}], inner_rect(widget.block, rect)}
      else
        {[], rect}
      end

    placeholder = widget.placeholder |> MessageView.sanitize() |> String.replace("\n", " ")

    {:ok, rows} =
      Native.input_render(widget.state, inner.width, inner.height, placeholder, widget.focused)

    blocks ++ Surface.place(rows, inner)
  end

  defp inner_rect(block, rect) do
    {left, right, top, bottom} = block.padding
    border = fn side -> if :all in block.borders or side in block.borders, do: 1, else: 0 end
    left = left + border.(:left)
    right = right + border.(:right)
    top = top + border.(:top)
    bottom = bottom + border.(:bottom)

    %Rect{
      x: rect.x + min(rect.width, left),
      y: rect.y + min(rect.height, top),
      width: max(rect.width - left - right, 0),
      height: max(rect.height - top - bottom, 0)
    }
  end

  defimpl ExRatatui.Widget do
    defdelegate render(widget, rect), to: Tackle.CLI.Widgets.Input
  end
end
