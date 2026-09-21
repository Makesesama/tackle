defmodule Tackle.CLI.Widgets.Browse do
  @moduledoc """
  Tackle-owned native Browse viewport. Rust paints responsive page tabs, wraps
  plain diagnostic documents, clamps scrolling and clips visible rows. Transcript
  pages reuse immutable Conversation resources and their existing selection.
  Elixir retains source for copying and owns page selection and runtime data.
  Resources are local, immutable, and must not be persisted or shared across nodes.
  """

  alias ExRatatui.Layout.Rect
  alias Tackle.CLI.Native
  alias Tackle.CLI.TUI.Theme
  alias Tackle.CLI.Widgets.{Conversation, Surface}

  defstruct [:state, page: 0, scroll_offset: 0, selected: []]

  @type t :: %__MODULE__{
          state: reference(),
          page: non_neg_integer(),
          scroll_offset: non_neg_integer(),
          selected: [non_neg_integer()]
        }

  @doc "Measures a frozen plain-text document at the given width."
  @spec document(String.t(), pos_integer()) :: {reference(), non_neg_integer()}
  def document(text, width),
    do: Native.browse_document(text, width, Conversation.style(Theme.style(:text)))

  @doc "Clamps row movement using the native viewport's chrome and content height."
  @spec scroll(non_neg_integer(), non_neg_integer(), non_neg_integer(), integer()) ::
          non_neg_integer()
  defdelegate scroll(offset, total, height, delta), to: Native, as: :browse_scroll

  @doc "Renders tabs and the selected page through the owned surface wire format."
  @spec render(t(), Rect.t()) :: [{struct(), Rect.t()}]
  def render(widget, rect) do
    styles =
      {Conversation.style(Theme.style(:accent)), Conversation.style(Theme.style(:muted)),
       Conversation.style(Theme.style(:selection_surface))}

    {:ok, rows} =
      Native.browse_render(
        widget.state,
        widget.page,
        rect.width,
        rect.height,
        widget.scroll_offset,
        widget.selected,
        styles
      )

    Surface.place(rows, rect)
  end

  defimpl ExRatatui.Widget do
    defdelegate render(widget, rect), to: Tackle.CLI.Widgets.Browse
  end
end
