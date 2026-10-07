defmodule Tackle.CLI.Widgets.ResumeScreen do
  @moduledoc false

  # The fullscreen `/resume` picker, laid out like Codex's session picker:
  # a bold header, a live search line, a comfortable two-line session list
  # with an expandable transcript preview, and a footer with scroll progress
  # and key hints. The windowing in `window/4` is shared with
  # `Tackle.CLI.TUI.Resume`, which uses it to keep the selection visible.

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Clear, Paragraph}
  alias Tackle.CLI.TUI.{Theme, Util}

  defstruct rows: [],
            selected: 0,
            scroll_top: 0,
            query: "",
            count: 0,
            loading?: false,
            error: nil

  @type preview :: [%{speaker: :user | :assistant, text: String.t()}]

  @type row :: %{
          id: String.t(),
          title: String.t(),
          meta: String.t() | nil,
          preview: nil | :loading | {:ok, preview()} | {:error, term()},
          expanded?: boolean()
        }

  @type t :: %__MODULE__{
          rows: [row()],
          selected: non_neg_integer(),
          scroll_top: non_neg_integer(),
          query: String.t(),
          count: non_neg_integer(),
          loading?: boolean(),
          error: String.t() | nil
        }

  @fixed_chrome 5
  @min_list_rows 6
  @footer_height 3

  @doc "Returns the list-area height for a terminal of `size`."
  @spec list_height({non_neg_integer(), non_neg_integer()}) :: non_neg_integer()
  def list_height({_width, height}) do
    height
    |> Kernel.-(@fixed_chrome + gap_rows(height))
    |> max(0)
  end

  @doc """
  Windows `rows` into `height` lines starting at `scroll_top`, keeping the
  `selected` row visible.

  Returns the visible rows, the adjusted scroll top, and whether content
  continues above or below the window. One line is reserved at each edge for
  the `↑ more` / `↓ more` indicators whenever the list continues there.
  """
  @spec window([row()], non_neg_integer(), non_neg_integer(), non_neg_integer()) :: %{
          visible: [row()],
          scroll_top: non_neg_integer(),
          more_above?: boolean(),
          more_below?: boolean()
        }
  def window([], _scroll_top, _selected, _height) do
    %{visible: [], scroll_top: 0, more_above?: false, more_below?: false}
  end

  def window(rows, scroll_top, selected, height) when height > 0 do
    last = max(length(rows) - 1, 0)
    top = scroll_top |> Kernel.min(selected) |> Util.clamp(0, last)
    {top, visible, leftover} = converge(rows, top, selected, height, false)

    %{visible: visible, scroll_top: top, more_above?: top > 0, more_below?: leftover != []}
  end

  def window(_rows, _scroll_top, _selected, _height) do
    %{visible: [], scroll_top: 0, more_above?: false, more_below?: false}
  end

  @doc "The rendered height of one row: title, meta, preview, separator."
  @spec row_height(row()) :: pos_integer()
  def row_height(%{expanded?: true} = row), do: 2 + preview_height(row.preview) + 1
  def row_height(_row), do: 3

  @spec render(t(), Rect.t()) :: [{struct(), Rect.t()}]
  def render(%__MODULE__{} = screen, %Rect{} = area) do
    {header, search, list, footer} = areas(area)

    [
      {%Clear{}, area},
      {header_widget(), header},
      {search_widget(screen, search.width), search},
      {list_widget(screen, list), list},
      {footer_widget(screen, footer, list), footer}
    ]
  end

  defimpl ExRatatui.Widget do
    defdelegate render(widget, rect), to: Tackle.CLI.Widgets.ResumeScreen
  end

  # -- layout ---------------------------------------------------------------

  defp areas(%Rect{} = area) do
    gap_after_header = if gap_rows(area.height) >= 2, do: 1, else: 0
    gap_after_search = if gap_rows(area.height) >= 1, do: 1, else: 0

    search_y = area.y + 1 + gap_after_header
    list_y = search_y + 1 + gap_after_search
    footer_y = area.y + area.height - @footer_height

    {
      %Rect{area | y: area.y, height: 1},
      %Rect{area | y: search_y, height: 1},
      %Rect{area | y: list_y, height: max(footer_y - list_y, 0)},
      %Rect{
        area
        | y: footer_y,
          height: max(min(area.height - (footer_y - area.y), @footer_height), 0)
      }
    }
  end

  # Decorative gaps collapse before the list loses room for two rows.
  defp gap_rows(height) do
    height |> Kernel.-(@fixed_chrome + @min_list_rows) |> max(0) |> min(2)
  end

  # -- windowing ------------------------------------------------------------

  # Fits the window, then re-fits once when the bottom indicator's reservation
  # changes: reserving its line can push the scroll top further down, which in
  # turn decides whether the indicator shows at all. The passes converge
  # because a smaller budget can only keep or grow the rows below the window.
  defp converge(rows, top, selected, height, reserve_bottom?) do
    budget = window_budget(height, top, reserve_bottom?)
    top = fit(rows, top, selected, budget, height)
    {visible, leftover} = collect(rows, top, selected, budget)

    if leftover != [] != reserve_bottom? do
      converge(rows, top, selected, height, leftover != [])
    else
      {top, visible, leftover}
    end
  end

  defp window_budget(height, top, reserve_bottom?) do
    height - if(top > 0, do: 1, else: 0) - if reserve_bottom?, do: 1, else: 0
  end

  # Advances the scroll top until the selected row fits fully in the window
  # budget. A row taller than the window can never fit; the window then starts
  # at the selection and the paragraph clips the overflow.
  defp fit(rows, top, selected, budget, height) do
    selected_row = Enum.at(rows, selected)

    cond do
      is_nil(selected_row) -> top
      row_height(selected_row) > height - 2 -> selected
      true -> advance_until_fits(rows, Util.clamp(top, 0, selected), selected, budget)
    end
  end

  defp advance_until_fits(rows, top, selected, budget) do
    if selected_fits?(rows, top, selected, budget) do
      top
    else
      # Scrolling one row down frees that row's height; the guard above
      # guarantees the selection fits once the window starts at it.
      advance_until_fits(rows, top + 1, selected, budget)
    end
  end

  # The selection is visible when every row from `top` through `selected`
  # fits in the window budget.
  defp selected_fits?(rows, top, selected, budget) do
    rows
    |> Enum.slice(top, selected - top + 1)
    |> Enum.reduce_while(budget, fn row, left ->
      if row_height(row) <= left, do: {:cont, left - row_height(row)}, else: {:halt, :overflow}
    end)
    |> case do
      :overflow -> false
      _left -> true
    end
  end

  defp collect(rows, top, selected, budget) do
    rows
    |> Enum.drop(top)
    |> Enum.with_index()
    |> Enum.reduce_while({[], budget}, fn {row, index}, {visible, left} ->
      height = row_height(row)

      cond do
        height <= left -> {:cont, {[row | visible], left - height}}
        top + index == selected -> {:halt, {[row | visible], left}}
        true -> {:halt, {visible, left}}
      end
    end)
    |> case do
      {visible, _left} ->
        visible = Enum.reverse(visible)
        {visible, Enum.drop(rows, top + length(visible))}
    end

    # The selected row may overflow the budget; the paragraph clips it.
  end

  defp lines(rows), do: rows |> Enum.map(&row_height/1) |> Enum.sum()

  defp preview_height(:loading), do: 1
  defp preview_height({:error, _reason}), do: 1
  defp preview_height({:ok, []}), do: 1
  defp preview_height({:ok, preview}) when is_list(preview), do: length(preview)
  defp preview_height(_other), do: 1

  # -- chrome ----------------------------------------------------------------

  defp header_widget do
    title = Span.new(" Resume a previous session", style: Theme.bold(Theme.style(:text)))
    %Paragraph{text: [Line.new([title])]}
  end

  defp search_widget(%__MODULE__{error: error}, width) when is_binary(error) do
    text = Span.new(" " <> Util.truncate(error, max(width - 2, 0)), style: Theme.style(:error))
    %Paragraph{text: [Line.new([text])]}
  end

  defp search_widget(%__MODULE__{query: query, count: count}, width) do
    noun = if count == 1, do: "session", else: "sessions"

    spans =
      if query == "" do
        [
          Span.new(" Type to search", style: Theme.style(:muted)),
          Span.new("  ·  #{count} #{noun}", style: Theme.style(:subtle))
        ]
      else
        [
          Span.new(" Search: ", style: Theme.style(:muted)),
          Span.new(Util.truncate(query, max(width - 14, 1)), style: Theme.style(:accent)),
          Span.new("  ·  #{count} #{noun}", style: Theme.style(:subtle))
        ]
      end

    %Paragraph{text: [Line.new(spans)]}
  end

  # -- list -------------------------------------------------------------------

  defp list_widget(%__MODULE__{} = screen, %Rect{} = rect) do
    lines =
      if screen.rows == [] do
        empty_lines(screen)
      else
        win = window(screen.rows, screen.scroll_top, screen.selected, rect.height)
        visible_lines(screen, win, rect.width, rect.height)
      end

    %Paragraph{text: lines, wrap: false}
  end

  defp empty_lines(%__MODULE__{loading?: true}) do
    [Line.new([Span.new(" Loading sessions…", style: Theme.italic(Theme.style(:muted)))])]
  end

  defp empty_lines(%__MODULE__{}) do
    [
      Line.new([
        Span.new(" No saved sessions in this project", style: Theme.italic(Theme.style(:muted)))
      ])
    ]
  end

  defp visible_lines(screen, win, width, height) do
    top_line = if win.more_above?, do: more_line("↑ more"), else: []
    bottom_line = if win.more_below?, do: more_line(bottom_label(screen)), else: []

    rows =
      win.visible
      |> Enum.with_index(fn row, index ->
        row_lines(row, index + win.scroll_top, screen.selected, width)
      end)

    lines = Enum.flat_map(rows, & &1)

    # When the window exactly fills the list area, the bottom indicator takes
    # the deepest row's trailing separator line — a blank line — instead of
    # adding one, so no session row ever gives up its slot.
    if length(lines) + length(top_line) + length(bottom_line) > height and lines != [] do
      top_line ++ Enum.drop(lines, -1) ++ bottom_line
    else
      top_line ++ lines ++ bottom_line
    end
  end

  defp bottom_label(%__MODULE__{loading?: true}), do: "↓ loading more…"
  defp bottom_label(%__MODULE__{}), do: "↓ more"

  defp more_line(label) do
    [Line.new([Span.new(" " <> label, style: Theme.style(:accent))])]
  end

  defp row_lines(row, index, selected, width) do
    selected? = index == selected
    zebra? = rem(index, 2) == 1
    background = row_background(selected?, zebra?)

    title_style =
      background
      |> Theme.merge(Theme.style(:text))
      |> then(fn style -> if selected?, do: Theme.bold(style), else: style end)

    marker = if selected?, do: if(row.expanded?, do: "⌄ ", else: "› "), else: "  "

    title =
      [
        Span.new(marker, style: title_style),
        Span.new(Util.truncate(row.title, max(width - 4, 1)), style: title_style)
      ]
      |> pad(background, width)

    meta =
      case row.meta do
        nil ->
          blank(background, width)

        meta ->
          [
            Span.new("  ", style: background),
            Span.new(Util.truncate(meta, max(width - 4, 1)), style: meta_style(background))
          ]
          |> pad(background, width)
      end

    preview = if row.expanded?, do: preview_lines(row.preview, background, width), else: []

    [title, meta] ++ preview ++ [blank(background, width)]
  end

  defp blank(background, width), do: pad([Span.new("", style: background)], background, width)

  defp meta_style(background), do: Theme.merge(background, Theme.style(:subtle))

  defp preview_lines(:loading, background, width) do
    [
      pad(
        [
          Span.new("  │ ", style: Theme.merge(background, Theme.style(:subtle))),
          Span.new("loading transcript…",
            style: Theme.italic(Theme.merge(background, Theme.style(:muted)))
          )
        ],
        background,
        width
      )
    ]
  end

  defp preview_lines({:error, _reason}, background, width) do
    [
      pad(
        [
          Span.new("  └ ", style: Theme.merge(background, Theme.style(:subtle))),
          Span.new("preview unavailable",
            style: Theme.italic(Theme.merge(background, Theme.style(:muted)))
          )
        ],
        background,
        width
      )
    ]
  end

  defp preview_lines({:ok, []}, background, width) do
    [
      pad(
        [
          Span.new("  └ ", style: Theme.merge(background, Theme.style(:subtle))),
          Span.new("No transcript preview available",
            style: Theme.italic(Theme.merge(background, Theme.style(:muted)))
          )
        ],
        background,
        width
      )
    ]
  end

  defp preview_lines({:ok, turns}, background, width) do
    count = length(turns)

    Enum.with_index(turns, 1)
    |> Enum.map(fn {turn, index} ->
      prefix = if index == count, do: "  └ ", else: "  │ "

      [
        Span.new(prefix, style: Theme.merge(background, Theme.style(:subtle))),
        Span.new(Util.truncate("#{turn.speaker}: #{turn.text}", max(width - 6, 1)),
          style: turn_style(turn.speaker, background)
        )
      ]
      |> pad(background, width)
    end)
  end

  defp preview_lines(_other, _background, _width), do: []

  defp turn_style(:user, background), do: Theme.merge(background, Theme.style(:muted))

  defp turn_style(_speaker, background),
    do: Theme.merge(background, Theme.style(:subtle))

  defp row_background(true, _zebra?), do: Theme.style(:selection_surface)
  defp row_background(false, true), do: Theme.style(:surface)
  defp row_background(false, false), do: %Style{}

  # Paints the row background to the full width so selection and zebra
  # striping cover whole lines, like Codex's painted session rows.
  defp pad(spans, background, width) do
    used = spans |> Enum.map(& &1.content) |> Enum.join() |> String.length()
    padding = max(width - used, 0)

    Line.new(spans ++ [Span.new(String.duplicate(" ", padding), style: background)])
  end

  # -- footer -----------------------------------------------------------------

  defp footer_widget(%__MODULE__{} = screen, %Rect{} = footer, %Rect{} = list) do
    separator = separator_line(screen, list.height, footer.width)

    %Paragraph{
      text: [
        separator,
        hint_row(hints(screen, 0), footer.width),
        hint_row(hints(screen, 1), footer.width)
      ]
    }
  end

  defp separator_line(screen, list_height, width) do
    progress = progress_label(screen, list_height, width)
    progress_width = String.length(progress)
    dashes = max(width - progress_width - 1, 0)

    Line.new([
      Span.new(String.duplicate("─", dashes), style: Theme.style(:subtle)),
      Span.new(String.duplicate(" ", max(width - dashes - progress_width, 0)),
        style: Theme.style(:subtle)
      ),
      Span.new(progress, style: Theme.style(:muted))
    ])
  end

  defp progress_label(screen, list_height, width) do
    position = if screen.count == 0, do: 0, else: screen.selected + 1
    percent = scroll_percent(screen, list_height)

    [
      " #{position} / #{screen.count} · #{percent}% ",
      " #{position}/#{screen.count} · #{percent}% "
    ]
    |> Enum.find(&(String.length(&1) < width))
    |> case do
      nil -> ""
      label -> label
    end
  end

  defp scroll_percent(%__MODULE__{rows: []}, _height), do: 100

  defp scroll_percent(%__MODULE__{} = screen, height) do
    total = lines(screen.rows)

    if total <= height do
      100
    else
      above = screen.rows |> Enum.take(screen.scroll_top) |> lines()
      percent = round(above / max(total - height, 1) * 100)
      Util.clamp(percent, 0, 100)
    end
  end

  defp hints(%__MODULE__{query: query}, 0) do
    [
      {"Enter", "resume"},
      {"Esc", if(query == "", do: "close", else: "clear search")},
      {"Ctrl+C", "quit"}
    ]
  end

  defp hints(_screen, 1) do
    [
      {"↑/↓", "browse"},
      {"→", "preview"},
      {"type", "filter"}
    ]
  end

  # Drops hints from the end until the row fits, like Codex's priority-based
  # footer hints.
  defp hint_row(hints, width) do
    hints
    |> Enum.reverse()
    |> Enum.reduce([], fn hint, acc -> maybe_keep_hint(hint, acc, width) end)
    |> Enum.flat_map(fn {key, label} ->
      [
        Span.new(" ", style: Theme.style(:subtle)),
        Span.new(key, style: Theme.style(:accent_soft)),
        Span.new(" " <> label, style: Theme.style(:muted))
      ]
    end)
    |> then(&Line.new([Span.new(" ", style: Theme.style(:subtle)) | &1]))
  end

  defp maybe_keep_hint(hint, [], _width), do: [hint]

  defp maybe_keep_hint({key, label} = hint, acc, width) do
    used = hint_width(acc) + 1 + String.length(key) + 1 + String.length(label)

    if used < width, do: [hint | acc], else: acc
  end

  defp hint_width(hints) do
    Enum.reduce(hints, 1, fn {key, label}, acc ->
      acc + 1 + String.length(key) + 1 + String.length(label)
    end)
  end
end
