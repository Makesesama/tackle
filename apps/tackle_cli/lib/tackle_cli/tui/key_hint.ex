defmodule Tackle.CLI.TUI.KeyHint do
  @moduledoc """
  Uniform key hints and whole-hint width selection.

  A hint is a bold key token followed by a muted label (`esc interrupt`), so
  every hint in the shell reads the same way. Hints are always selected
  whole: one that does not fit is dropped entirely rather than truncated, so
  a key is never shown without its meaning. The pattern is ported from
  codex's `footer_hint.rs` (`first_fitting_line`).
  """

  alias Tackle.CLI.TUI.{MessageView, Theme}

  @typedoc "A key token and the action it performs."
  @type hint :: {key :: String.t(), label :: String.t()}

  @separator_width 3

  @doc "Builds the spans for one hint: bold key token, muted label."
  @spec spans(hint()) :: [ExRatatui.Span.t()]
  def spans({key, label}) do
    [
      MessageView.span(key, Theme.bold(Theme.style(:text))),
      MessageView.span(" " <> label, Theme.style(:muted))
    ]
  end

  @doc "The spans joining `hints` with the muted separator used between them."
  @spec row_spans([hint()]) :: [ExRatatui.Span.t()]
  def row_spans([]), do: []

  def row_spans([hint | rest]) do
    spans(hint) ++
      Enum.flat_map(rest, &[MessageView.span(" · ", Theme.style(:subtle)) | spans(&1)])
  end

  @doc "Display width of one hint including the space between key and label."
  @spec width(hint()) :: non_neg_integer()
  def width({key, label}),
    do: MessageView.display_width(key) + 1 + MessageView.display_width(label)

  @doc "Display width of a joined hint row, separators included."
  @spec row_width([hint()]) :: non_neg_integer()
  def row_width([]), do: 0
  def row_width([_ | _] = hints), do: row_width(hints, 0)

  defp row_width([hint], total), do: total + width(hint)

  defp row_width([hint | rest], total),
    do: row_width(rest, total + width(hint) + @separator_width)

  @doc """
  Picks the first candidate hint row that fits `width`, or the last one.

  Candidates are ordered fullest-first and each is measured as a whole row:
  a candidate that does not fit is skipped, never truncated. The final
  candidate is the empty row, so the result always fits.
  """
  @spec first_fitting([[hint()]], integer()) :: [hint()]
  def first_fitting([_ | _] = candidates, width) do
    width = max(width, 0)
    Enum.find(candidates, List.last(candidates), &(row_width(&1) <= width))
  end
end
