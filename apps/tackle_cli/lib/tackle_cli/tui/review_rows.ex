defmodule Tackle.CLI.TUI.ReviewRows do
  @moduledoc """
  Row primitives shared by the `/review` overlay's views
  (`Tackle.CLI.TUI.ReviewView` and `Tackle.CLI.TUI.ReviewDashboard`):
  styled spans, severity badges, progress bars, and clipping rows to a
  pane's width.

  Rows are `Tackle.CLI.TUI.MessageView` rows, so the views stay plain data
  that tests can read back as text.
  """

  alias ExRatatui.Style
  alias Tackle.CLI.TUI.{MessageView, Theme}

  @spinner ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  @badge_width 7

  @typedoc "A row status drawn as a glyph."
  @type status :: :done | :failed | :running | :pending

  @doc "A span in a theme tone or an explicit style."
  @spec span(String.t(), atom() | Style.t()) :: ExRatatui.Span.t()
  def span(text, style) when is_atom(style), do: MessageView.span(text, Theme.style(style))
  def span(text, %Style{} = style), do: MessageView.span(text, style)

  @doc "A row of one muted text."
  @spec muted_row(String.t()) :: MessageView.row()
  def muted_row(text), do: MessageView.row([span(text, :muted)])

  @doc "An empty row."
  @spec blank() :: MessageView.row()
  def blank, do: MessageView.row([])

  @doc "A bold style in `tone`."
  @spec bold(atom()) :: Style.t()
  def bold(tone), do: Theme.bold(Theme.style(tone))

  @doc """
  A badge: `text` padded by a space on each side, drawn reversed in
  `tone`, so it reads as a colored chip in light and dark themes alike.
  """
  @spec badge(String.t(), atom()) :: ExRatatui.Span.t()
  def badge(text, tone) do
    style = Theme.style(tone)

    span(" " <> text <> " ", %{style | modifiers: Enum.uniq([:reversed, :bold | style.modifiers])})
  end

  @doc "A fixed-width severity badge, such as ` HIGH  `."
  @spec severity_badge(atom()) :: ExRatatui.Span.t()
  def severity_badge(severity) do
    label = severity |> severity_label() |> String.pad_trailing(@badge_width - 2)
    badge(label, severity_tone(severity))
  end

  @doc "Display width of `severity_badge/1`."
  @spec badge_width() :: pos_integer()
  def badge_width, do: @badge_width

  @doc "The short label of a severity."
  @spec severity_label(atom()) :: String.t()
  def severity_label(:blocker), do: "BLOCK"
  def severity_label(:high), do: "HIGH"
  def severity_label(:medium), do: "MED"
  def severity_label(:low), do: "LOW"
  def severity_label(other), do: other |> to_string() |> String.upcase()

  @doc "The theme tone of a severity."
  @spec severity_tone(atom()) :: atom()
  def severity_tone(severity) when severity in [:blocker, :high], do: :error
  def severity_tone(:medium), do: :warning
  def severity_tone(_severity), do: :accent_soft

  @doc "Severities from worst to mildest."
  @spec severities() :: [atom()]
  def severities, do: [:blocker, :high, :medium, :low]

  @doc """
  The glyph for a status; a running one animates with `frame`, or is a
  still `●` without one (for transcript cards, which do not animate).
  """
  @spec glyph(status(), non_neg_integer() | nil) :: String.t()
  def glyph(:done, _frame), do: "✓"
  def glyph(:failed, _frame), do: "✗"
  def glyph(:running, nil), do: "●"
  def glyph(:running, frame), do: Enum.at(@spinner, rem(frame, length(@spinner)))
  def glyph(:pending, _frame), do: "◌"

  @doc "The theme tone of a status glyph."
  @spec glyph_tone(status()) :: atom()
  def glyph_tone(:done), do: :success
  def glyph_tone(:failed), do: :error
  def glyph_tone(:running), do: :accent
  def glyph_tone(:pending), do: :subtle

  @doc "A styled status glyph followed by a space."
  @spec glyph_span(status(), non_neg_integer() | nil) :: ExRatatui.Span.t()
  def glyph_span(status, frame), do: span(glyph(status, frame) <> " ", glyph_tone(status))

  @doc """
  A horizontal bar of `width` cells, `value / total` of it filled in
  `tone`, the rest drawn as a subtle track.
  """
  @spec bar(non_neg_integer(), non_neg_integer(), non_neg_integer(), atom()) ::
          [ExRatatui.Span.t()]
  def bar(_value, _total, width, _tone) when width <= 0, do: []

  def bar(value, total, width, tone) do
    filled = if total > 0, do: round(width * min(value, total) / total), else: 0
    filled = if value > 0 and filled == 0, do: 1, else: filled

    [
      span(String.duplicate("━", filled), tone),
      span(String.duplicate("─", width - filled), :subtle)
    ]
  end

  @doc "A section heading: an accent mark, a bold title, and a rule to `width`."
  @spec heading(String.t(), non_neg_integer(), atom()) :: MessageView.row()
  def heading(title, width, tone \\ :accent_soft) do
    used = MessageView.display_width(title) + 3
    rule = String.duplicate("─", max(width - used, 0))
    MessageView.row([span("▎", :accent), span(title <> " ", bold(tone)), span(rule, :subtle)])
  end

  @doc "Display width of a row's spans."
  @spec row_width(MessageView.row()) :: non_neg_integer()
  def row_width(%{spans: spans}),
    do: spans |> Enum.map(&MessageView.display_width(&1.content)) |> Enum.sum()

  @doc "Clips a row to `width` cells, ending a cut row with an ellipsis."
  @spec fit(MessageView.row(), non_neg_integer()) :: MessageView.row()
  def fit(%{spans: spans} = row, width) do
    if row_width(row) <= width do
      row
    else
      {kept, _used} =
        Enum.reduce_while(spans, {[], 0}, fn span, {kept, used} ->
          room = width - 1 - used
          size = MessageView.display_width(span.content)

          cond do
            room <= 0 -> {:halt, {kept, used}}
            size <= room -> {:cont, {[span | kept], used + size}}
            true -> {:halt, {[%{span | content: clip(span.content, room)} | kept], width - 1}}
          end
        end)

      ellipsis = if width > 0, do: [MessageView.span("…", Theme.style(:subtle))], else: []
      %{row | spans: Enum.reverse(kept) ++ ellipsis}
    end
  end

  @doc "Cuts `text` to at most `room` display cells."
  @spec clip(String.t(), non_neg_integer()) :: String.t()
  def clip(text, room) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, used} ->
      size = MessageView.display_width(grapheme)

      if used + size <= room,
        do: {:cont, {acc <> grapheme, used + size}},
        else: {:halt, {acc, used}}
    end)
    |> elem(0)
  end

  @doc "Pads a row with spaces to `width` cells."
  @spec pad(MessageView.row(), non_neg_integer()) :: MessageView.row()
  def pad(%{spans: spans} = row, width) do
    used = row_width(row)

    if used < width,
      do: %{row | spans: spans ++ [MessageView.span(String.duplicate(" ", width - used))]},
      else: row
  end

  @doc """
  Joins a left and a right group of spans into one row of `width` cells,
  the right group flush right. The right group is dropped when both do not
  fit; the left one is then clipped.
  """
  @spec split_row([ExRatatui.Span.t()], [ExRatatui.Span.t()], non_neg_integer()) ::
          MessageView.row()
  def split_row(left, right, width) do
    left_width = row_width(MessageView.row(left))
    right_width = row_width(MessageView.row(right))
    gap = width - left_width - right_width

    if right != [] and gap >= 2,
      do: MessageView.row(left ++ [MessageView.span(String.duplicate(" ", gap))] ++ right),
      else: fit(MessageView.row(left), width)
  end

  @doc "`count` and `noun`, pluralized with an `s`."
  @spec plural(integer(), String.t()) :: String.t()
  def plural(1, noun), do: "1 #{noun}"
  def plural(count, noun), do: "#{count} #{noun}s"

  @doc "A short clock for elapsed milliseconds: `42s`, `3m 05s`, `1h 02m`."
  @spec clock(non_neg_integer()) :: String.t()
  def clock(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"

  def clock(ms) when ms < 3_600_000,
    do: "#{div(ms, 60_000)}m #{pad2(rem(div(ms, 1_000), 60))}s"

  def clock(ms), do: "#{div(ms, 3_600_000)}h #{pad2(rem(div(ms, 60_000), 60))}m"

  defp pad2(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
