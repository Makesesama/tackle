defmodule Tackle.CLI.Widgets.Tree do
  @moduledoc """
  Native conversation-tree viewport.

  Rows carry tree structure separately from their labels. Rust paints branch
  connectors, active-path markers, selection, vertical clipping, and horizontal
  panning for deep branches. The two-column cursor gutter remains visible while
  row bodies pan, following pi's tree-selector layout. Single-child history stays
  flat; after a fork, junctions and vertical rails keep both sibling paths
  connected, with an elbow closing each branch. Layout looks ahead in the full
  row list so viewport clipping does not create false branch ends.
  """

  alias ExRatatui.Layout.Rect
  alias Tackle.CLI.Native
  alias Tackle.CLI.TUI.Theme
  alias Tackle.CLI.Widgets.{Conversation, Surface}

  @type tree_node :: %{
          required(:text) => String.t(),
          optional(:secondary) => String.t() | nil,
          required(:depth) => non_neg_integer(),
          required(:connector?) => boolean(),
          required(:last?) => boolean(),
          required(:ancestor_continues) => [boolean()],
          optional(:active?) => boolean(),
          optional(:unsafe?) => boolean()
        }

  defstruct nodes: [], selected: 0

  @type t :: %__MODULE__{nodes: [tree_node()], selected: non_neg_integer()}

  @doc "Renders the visible native tree rows into ExRatatui primitives."
  @spec render(t(), Rect.t()) :: [{struct(), Rect.t()}]
  def render(%__MODULE__{nodes: []}, %Rect{}), do: []

  def render(%__MODULE__{} = widget, %Rect{} = rect) do
    {:ok, rows} =
      Native.tree_render(
        Enum.map(widget.nodes, &wire_node/1),
        widget.selected,
        rect.width,
        rect.height,
        style(:accent_soft),
        style(:muted),
        style(:selection_surface),
        style(:text)
      )

    Surface.place(rows, rect)
  end

  defp wire_node(node) do
    {
      node.text,
      node[:secondary],
      node.depth,
      {node[:connector?] || false, node[:last?] || false},
      node.ancestor_continues,
      node[:active?] || false,
      node[:unsafe?] || false
    }
  end

  defp style(tone), do: tone |> Theme.style() |> Conversation.style()

  defimpl ExRatatui.Widget do
    defdelegate render(widget, rect), to: Tackle.CLI.Widgets.Tree
  end
end
