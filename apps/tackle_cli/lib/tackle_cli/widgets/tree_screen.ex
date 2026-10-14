defmodule Tackle.CLI.Widgets.TreeScreen do
  @moduledoc false

  # The fullscreen `/tree` screen, laid out like `/resume`: a bold header with
  # the view tabs, a live search line, the graph list with a painted selection
  # row, and a footer with position and key hints. Rows arrive pre-laid-out from
  # `Tackle.CLI.TUI.Tree`; this module only paints and windows them.

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Clear, Paragraph}
  alias Tackle.CLI.TUI.{Theme, Util}

  @views [default: "messages", user: "user only", all: "all entries"]

  # Header, search, and the footer's separator and hint rows.
  @fixed_chrome 4
  @min_list_rows 6
  @footer_height 2
  @scroll_margin 2

  defstruct rows: [], selected: 0, scroll_top: 0, query: "", view: :default

  @type t :: %__MODULE__{
          rows: [map()],
          selected: non_neg_integer(),
          scroll_top: non_neg_integer(),
          query: String.t(),
          view: :default | :user | :all
        }

  @doc "Returns the list-area height for a terminal of `size`."
  @spec list_height({non_neg_integer(), non_neg_integer()} | nil) :: non_neg_integer()
  def list_height({_width, height}), do: max(height - @fixed_chrome - gap_rows(height), 1)
  def list_height(_size), do: @min_list_rows

  @doc """
  Returns the scroll top that keeps `selected` visible in a `height`-row list,
  moving the window as little as possible and keeping a small margin.
  """
  @spec scroll_top(non_neg_integer(), non_neg_integer(), non_neg_integer(), pos_integer()) ::
          non_neg_integer()
  def scroll_top(_top, _selected, count, height) when count <= height, do: 0

  def scroll_top(top, selected, count, height) do
    margin = min(@scroll_margin, div(height - 1, 2))

    top
    |> min(selected - margin)
    |> max(selected + margin - height + 1)
    |> Util.clamp(0, count - height)
  end

  @spec render(t(), Rect.t()) :: [{struct(), Rect.t()}]
  def render(%__MODULE__{} = screen, %Rect{} = area) do
    {header, search, list, footer} = areas(area)

    [
      {%Clear{}, area},
      {header_widget(screen, header.width), header},
      {search_widget(screen, search.width), search},
      {list_widget(screen, list), list},
      {footer_widget(screen, footer.width), footer}
    ]
  end

  defimpl ExRatatui.Widget do
    defdelegate render(widget, rect), to: Tackle.CLI.Widgets.TreeScreen
  end

  # -- layout -----------------------------------------------------------------

  defp areas(%Rect{} = area) do
    gaps = gap_rows(area.height)
    gap_after_header = if gaps >= 2, do: 1, else: 0
    gap_after_search = if gaps >= 1, do: 1, else: 0

    search_y = area.y + 1 + gap_after_header
    list_y = search_y + 1 + gap_after_search
    footer_y = max(area.y + area.height - @footer_height, list_y)

    {
      %Rect{area | height: min(area.height, 1)},
      %Rect{area | y: search_y, height: 1},
      %Rect{area | y: list_y, height: max(footer_y - list_y, 0)},
      %Rect{area | y: footer_y, height: max(area.y + area.height - footer_y, 0)}
    }
  end

  # Decorative gaps collapse before the list loses room.
  defp gap_rows(height) do
    height |> Kernel.-(@fixed_chrome + @min_list_rows) |> max(0) |> min(2)
  end

  # -- chrome -----------------------------------------------------------------

  defp header_widget(%__MODULE__{view: current}, width) do
    title = " Conversation tree"

    tabs =
      @views
      |> Enum.map(fn {view, name} ->
        if view == current,
          do: Span.new(name, style: Theme.bold(Theme.style(:accent))),
          else: Span.new(name, style: Theme.style(:subtle))
      end)
      |> Enum.intersperse(Span.new("  ", style: Theme.style(:subtle)))

    tabs_width = tabs |> Enum.map(&String.length(&1.content)) |> Enum.sum()
    gap = width - String.length(title) - tabs_width - 1

    spans =
      if gap >= 2 do
        [
          Span.new(title, style: Theme.bold(Theme.style(:text))),
          Span.new(String.duplicate(" ", gap))
        ] ++
          tabs
      else
        [Span.new(title, style: Theme.bold(Theme.style(:text)))]
      end

    %Paragraph{text: [Line.new(spans)]}
  end

  defp search_widget(%__MODULE__{query: query, rows: rows}, width) do
    count = length(rows)
    noun = if count == 1, do: "entry", else: "entries"

    spans =
      if query == "" do
        [Span.new(" Type to search", style: Theme.style(:muted))]
      else
        [
          Span.new(" Search: ", style: Theme.style(:muted)),
          Span.new(Util.truncate(query, max(width - 24, 1)), style: Theme.style(:accent))
        ]
      end

    %Paragraph{
      text: [Line.new(spans ++ [Span.new("  ·  #{count} #{noun}", style: Theme.style(:subtle))])]
    }
  end

  defp footer_widget(%__MODULE__{} = screen, width) do
    position = if screen.rows == [], do: 0, else: screen.selected + 1
    progress = " #{position} / #{length(screen.rows)} "
    dashes = max(width - String.length(progress) - 1, 0)

    separator =
      Line.new([
        Span.new(String.duplicate("─", dashes) <> " ", style: Theme.style(:subtle)),
        Span.new(progress, style: Theme.style(:muted))
      ])

    %Paragraph{text: [separator, hint_row(hints(screen), width)]}
  end

  defp hints(%__MODULE__{} = screen) do
    [
      {"Enter", accept_label(Enum.at(screen.rows, screen.selected))},
      {"Tab", "view"},
      {"Esc", if(screen.query == "", do: "close", else: "clear search")},
      {"↑/↓", "move"},
      {"type", "search"}
    ]
  end

  defp accept_label(nil), do: "select"
  defp accept_label(%{unsafe?: true}), do: "inspect only"
  defp accept_label(%{kind: :user}), do: "edit from here"
  defp accept_label(%{kind: :root}), do: "start over"
  defp accept_label(%{current?: true}), do: "stay here"
  defp accept_label(_row), do: "continue from here"

  # Drops hints from the end until the row fits.
  defp hint_row(hints, width) do
    {spans, _used} =
      Enum.reduce(hints, {[], 1}, fn {key, label}, {spans, used} ->
        hint_width = 2 + String.length(key) + 1 + String.length(label)

        if spans == [] or used + hint_width < width do
          hint = [
            Span.new("  ", style: Theme.style(:subtle)),
            Span.new(key, style: Theme.style(:accent_soft)),
            Span.new(" " <> label, style: Theme.style(:muted))
          ]

          {spans ++ hint, used + hint_width}
        else
          {spans, width}
        end
      end)

    Line.new([Span.new(" ") | tl(spans)])
  end

  # -- list -------------------------------------------------------------------

  defp list_widget(%__MODULE__{rows: []} = screen, _rect) do
    message = if screen.query == "", do: " Nothing to show", else: " No matching entries"
    %Paragraph{text: [Line.new([Span.new(message, style: Theme.italic(Theme.style(:muted)))])]}
  end

  defp list_widget(%__MODULE__{} = screen, %Rect{} = rect) do
    lines =
      screen.rows
      |> Enum.with_index()
      |> Enum.drop(screen.scroll_top)
      |> Enum.take(rect.height)
      |> Enum.map(fn {row, index} -> row_line(row, index == screen.selected, rect.width) end)

    %Paragraph{text: lines, wrap: false}
  end

  defp row_line(row, selected?, width) do
    background = if selected?, do: Theme.style(:selection_surface), else: %Style{}
    paint = fn tone -> Theme.merge(background, tone) end

    cursor = Span.new(if(selected?, do: " › ", else: "   "), style: paint.(Theme.style(:accent)))
    rails = Span.new(row.prefix, style: paint.(Theme.style(:subtle)))
    glyph = glyph_span(row, paint)
    meta = meta_spans(row, paint)

    used =
      [cursor, rails, glyph | meta]
      |> Enum.map(&String.length(&1.content))
      |> Enum.sum()

    text_width = max(width - used - 1, 1)
    text_style = paint.(text_style(row)) |> then(&if(selected?, do: Theme.bold(&1), else: &1))
    text = Span.new(Util.truncate(row.primary, text_width), style: text_style)

    filler = max(width - used - String.length(text.content), 0)

    Line.new(
      [cursor, rails, glyph, text, Span.new(String.duplicate(" ", filler), style: background)] ++
        meta
    )
  end

  # Body lines under a node have no glyph: their text aligns with the node's.
  defp glyph_span(%{glyph: nil}, _paint), do: Span.new("")

  defp glyph_span(row, paint) do
    tone =
      cond do
        row.current? -> Theme.bold(Theme.style(:accent))
        row.unsafe? -> Theme.style(:subtle)
        row.active? -> Theme.style(:accent_soft)
        true -> Theme.style(:muted)
      end

    Span.new(row.glyph <> " ", style: paint.(tone))
  end

  defp meta_spans(%{secondary: nil}, _paint), do: []

  defp meta_spans(row, paint) do
    tone =
      cond do
        row.unsafe? -> Theme.style(:warning)
        row.current? -> Theme.style(:accent)
        true -> Theme.style(:subtle)
      end

    [Span.new("  " <> row.secondary <> " ", style: paint.(tone))]
  end

  defp text_style(%{unsafe?: true}), do: Theme.italic(Theme.style(:subtle))

  defp text_style(%{kind: kind, active?: true}) when kind in [:user, :root],
    do: Theme.style(:text)

  defp text_style(%{kind: kind}) when kind in [:user, :root], do: Theme.style(:muted)
  defp text_style(%{active?: true}), do: Theme.style(:muted)
  defp text_style(_row), do: Theme.style(:subtle)
end
