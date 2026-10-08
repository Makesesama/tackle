defmodule Tackle.CLI.Widgets.Input do
  @moduledoc """
  Tackle-owned native multiline editor with grapheme-safe soft wrapping.

  `new/0` returns a local, opaque mutable resource; do not persist it or pass it
  to another node. Editing and painting use Tackle's NIF, not ExRatatui's
  textarea resource. The host owns submission, paste normalization, and shortcut
  precedence. `set_value/2` resets undo/redo and drops every element;
  `insert_str/2` is one undoable edit.

  Arrow keys move by grapheme or visual row. Home/End (Ctrl+A/E) move within a
  logical line; Alt+B/F and Ctrl+B/F move by whitespace-delimited word;
  Ctrl+W deletes the preceding word, and Ctrl+U/R undo/redo. Unknown modified
  chords are ignored. Wrapping preserves all source whitespace and reserves a
  visible insertion cell. Undo retains at most 100 snapshots / 8 MiB.

  A collapsed paste is an *element*: the host inserts its label with
  `insert_element/4` and its own payload id, and the editor treats the range as
  one unit. Motion steps over it, an edit that touches it removes it whole, and
  `elements/1` reports which ids the draft still holds. All of that is the
  editor's business; the payload behind an id never enters this module, so the
  host stays free to retain, restore, or discard it.

  Paint replaces control characters (tabs display as spaces) without changing
  the draft. A reversed cell is the caret; it is hidden when `focused` is false.
  Rendering is limited to 65,536 cells, like the other native surfaces.
  """

  alias ExRatatui.Layout.Rect
  alias Tackle.CLI.{Native, Widgets.Surface}
  alias Tackle.CLI.TUI.MessageView
  alias Tackle.CLI.Widgets.Conversation

  defstruct [:state, :block, placeholder: "", focused: true, element_style: nil]

  @typedoc "A payload id with the byte range its label occupies in the draft."
  @type element :: {id :: integer(), start :: non_neg_integer(), stop :: non_neg_integer()}

  @type t :: %__MODULE__{
          state: reference() | nil,
          block: ExRatatui.Widgets.Block.t() | nil,
          placeholder: String.t(),
          focused: boolean(),
          element_style: ExRatatui.Style.t() | nil
        }

  @spec new() :: reference()
  defdelegate new(), to: Native, as: :input_new

  @doc "The draft text. Elements are reported separately by `elements/1`."
  @spec get_value(reference()) :: String.t()
  defdelegate get_value(state), to: Native, as: :input_get_value

  @doc "Loads `value` as the draft, dropping every element and the undo history."
  @spec set_value(reference(), String.t()) :: :ok
  defdelegate set_value(state, value), to: Native, as: :input_set_value

  @spec insert_str(reference(), String.t()) :: :ok
  defdelegate insert_str(state, value), to: Native, as: :input_insert_str

  @doc """
  Inserts `prefix` and then `label` at the caret as one undoable element.

  The label is the host's own text — the editor never interprets it — and `id`
  is the host's identifier for the payload it stands for.
  """
  @spec insert_element(reference(), String.t(), String.t(), integer()) :: :ok
  defdelegate insert_element(state, prefix, label, id), to: Native, as: :input_insert_element

  @doc "The elements the draft still holds, in draft order."
  @spec elements(reference()) :: [element()]
  defdelegate elements(state), to: Native, as: :input_elements

  @doc """
  Loads `text` and re-attaches the label spans recorded for it, in one edit.

  Spans that do not fit `text` are dropped, so a stale snapshot cannot produce
  a split label. Returns the spans it attached, which the caller compares with
  what it asked for.
  """
  @spec restore(reference(), String.t(), [element()]) :: {:ok, [element()]}
  defdelegate restore(state, text, spans), to: Native, as: :input_restore

  @spec handle_key(reference(), String.t(), [String.t()], non_neg_integer()) :: :ok
  defdelegate handle_key(state, code, modifiers, width), to: Native, as: :input_handle_key

  @spec rows(reference(), non_neg_integer()) :: pos_integer()
  defdelegate rows(state, width), to: Native, as: :input_rows

  @doc """
  Returns the caret's byte offset into the draft.

  Mention completions use it to find the `@token` under the caret.
  """
  @spec cursor(reference()) :: non_neg_integer()
  defdelegate cursor(state), to: Native, as: :input_cursor

  @doc """
  Replaces the byte range `start..end` of the draft with `text` in one edit.

  Offsets are clamped to the nearest character boundary at or before them, so
  a host-computed range can never split a grapheme. The caret moves after the
  inserted text.
  """
  @spec replace_range(reference(), non_neg_integer(), non_neg_integer(), String.t()) :: :ok
  defdelegate replace_range(state, start, stop, text), to: Native, as: :input_replace_range

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
      Native.input_render(
        widget.state,
        inner.width,
        inner.height,
        placeholder,
        widget.focused,
        wire_style(widget.element_style)
      )

    blocks ++ Surface.place(rows, inner)
  end

  # The element style crosses the wire in the same shape every other native
  # surface uses, so the palette stays defined by the theme in one place.
  defp wire_style(nil), do: {nil, nil, nil, 0}
  defp wire_style(%ExRatatui.Style{} = style), do: Conversation.style(style)

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
