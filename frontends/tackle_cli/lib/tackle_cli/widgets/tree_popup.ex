defmodule Tackle.CLI.Widgets.TreePopup do
  @moduledoc false

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Clear, Paragraph}
  alias Tackle.CLI.TUI.Theme
  alias Tackle.CLI.Widgets.Tree

  defstruct nodes: [], selected: 0, query: "", count: 0

  @type t :: %__MODULE__{
          nodes: [Tree.tree_node()],
          selected: non_neg_integer(),
          query: String.t(),
          count: non_neg_integer()
        }

  @spec render(t(), Rect.t()) :: [{struct(), Rect.t()}]
  def render(%__MODULE__{} = popup, %Rect{} = area) do
    panel = centered(area, 86, 72)
    inner = inset(panel)
    {search, tree, help} = rows(inner)
    count = "#{popup.count} #{if popup.count == 1, do: "entry", else: "entries"}"

    search_text =
      if popup.query == "" do
        [
          Span.new(" Type to search", style: Theme.style(:muted)),
          Span.new("  ·  " <> count, style: Theme.style(:subtle))
        ]
      else
        [
          Span.new(" Search: ", style: Theme.style(:muted)),
          Span.new(popup.query, style: Theme.style(:accent)),
          Span.new("  ·  " <> count, style: Theme.style(:subtle))
        ]
      end

    help_text = [
      Line.new([
        Span.new(" ↑/↓", style: Theme.style(:accent_soft)),
        Span.new(" move  ", style: Theme.style(:muted)),
        Span.new("Enter", style: Theme.style(:accent_soft)),
        Span.new(" select  ", style: Theme.style(:muted)),
        Span.new("Esc", style: Theme.style(:accent_soft)),
        Span.new(" close", style: Theme.style(:muted))
      ]),
      Line.new([
        Span.new(" Navigation does not undo workspace changes",
          style: Theme.style(:subtle)
        )
      ])
    ]

    [
      {%Clear{}, panel},
      {
        %Block{
          title: " Conversation tree ",
          borders: [:all],
          border_type: :rounded,
          border_style: %Style{fg: :cyan},
          title_style: Theme.style(:accent)
        },
        panel
      },
      {%Paragraph{text: [Line.new(search_text)]}, search},
      {%Tree{nodes: popup.nodes, selected: popup.selected}, tree},
      {%Paragraph{text: help_text}, help}
    ]
  end

  defp centered(%Rect{} = area, width_percent, height_percent) do
    width = min(area.width, max(div(area.width * width_percent, 100), min(area.width, 24)))
    height = min(area.height, max(div(area.height * height_percent, 100), min(area.height, 9)))

    %Rect{
      x: area.x + div(area.width - width, 2),
      y: area.y + div(area.height - height, 2),
      width: width,
      height: height
    }
  end

  defp inset(%Rect{} = rect) do
    %Rect{
      x: rect.x + min(rect.width, 1),
      y: rect.y + min(rect.height, 1),
      width: max(rect.width - 2, 0),
      height: max(rect.height - 2, 0)
    }
  end

  defp rows(%Rect{} = inner) do
    search_height = min(inner.height, 1)
    help_height = min(max(inner.height - search_height, 0), 2)
    tree_height = max(inner.height - search_height - help_height, 0)

    {
      %Rect{inner | height: search_height},
      %Rect{inner | y: inner.y + search_height, height: tree_height},
      %Rect{inner | y: inner.y + search_height + tree_height, height: help_height}
    }
  end

  defimpl ExRatatui.Widget do
    defdelegate render(widget, rect), to: Tackle.CLI.Widgets.TreePopup
  end
end
