defmodule Tackle.CLI.TUI.Layout do
  @moduledoc """
  Responsive fullscreen regions for the transcript-first shell.

  The transcript owns the flexible middle of the screen. The header and the
  composer have fixed or draft-driven heights, and optional reading, status,
  and hint rows appear only when the terminal has rows to spare, in that
  priority order.

  The composer grows with the native editor's measured visual rows, including
  soft wraps and the final insertion cell, up to eight content rows. The two
  chrome rows enclose the input in a rounded box. On tiny terminals the box
  yields to editable content.
  """

  alias ExRatatui.Layout.Rect

  @header_height 1
  @composer_border_height 2
  @composer_min_lines 1
  @composer_max_lines 8
  @min_transcript_height 1

  @type regions :: %{
          header: Rect.t(),
          transcript: Rect.t(),
          sidebar: Rect.t() | nil,
          reading: Rect.t() | nil,
          status: Rect.t() | nil,
          composer: Rect.t(),
          hints: Rect.t() | nil
        }

  @doc """
  Computes screen regions for a terminal of `width` x `height` cells.

  `draft_lines` is the composer's wrapped row count. `reading_active?`
  requests the reading-back affordance row, which takes priority over the
  optional status and hint rows.
  """
  @spec regions(integer(), integer(), pos_integer(), boolean(), boolean()) :: regions()
  def regions(width, height, draft_lines, reading_active?, subagents_active? \\ false) do
    width = max(width, 1)
    height = max(height, 0)

    chrome_height = if composer_box?(width, height), do: @composer_border_height, else: 0

    composer_height =
      min(
        composer_lines(height, draft_lines, chrome_height) + chrome_height,
        max(height - @header_height, 0)
      )

    available = max(height - @header_height - composer_height, 0)

    {reading?, available} = take_optional_row(reading_active?, available)
    {status?, available} = take_optional_row(true, available)
    {hints?, transcript_height} = take_optional_row(true, available)

    header = %Rect{x: 0, y: 0, width: width, height: min(height, @header_height)}
    transcript_area = %Rect{x: 0, y: @header_height, width: width, height: transcript_height}
    {transcript, sidebar} = split_sidebar(transcript_area, subagents_active?)
    y = @header_height + transcript_height

    {reading, y} = optional_rect(reading?, y, width)
    {status, y} = optional_rect(status?, y, width)
    composer = %Rect{x: 0, y: y, width: width, height: composer_height}
    {hints, _y} = optional_rect(hints?, y + composer_height, width)

    %{
      header: header,
      transcript: transcript,
      sidebar: sidebar,
      reading: reading,
      status: status,
      composer: composer,
      hints: hints
    }
  end

  @doc "Returns the composer's content line count for a terminal height."
  @spec composer_lines(integer(), pos_integer()) :: pos_integer()
  def composer_lines(height, draft_lines),
    do: composer_lines(height, draft_lines, @composer_border_height)

  @doc "Whether there is room for input borders, padding, and an editable cell."
  @spec composer_box?(integer(), integer()) :: boolean()
  def composer_box?(width, height), do: width >= 5 and height >= 4

  @doc "Shared content width for composer measurement, navigation, and paint."
  @spec composer_content_width(integer(), integer()) :: pos_integer()
  def composer_content_width(width, height) do
    inset = if composer_box?(width, height), do: 4, else: 0
    max(width - inset, 1)
  end

  defp composer_lines(height, draft_lines, chrome_height) do
    max_lines =
      height
      |> Kernel.-(@header_height + chrome_height + @min_transcript_height)
      |> min(@composer_max_lines)
      |> max(@composer_min_lines)

    draft_lines |> max(@composer_min_lines) |> min(max_lines)
  end

  defp split_sidebar(%Rect{width: width} = rect, true) when width > 1 do
    sidebar_width = width |> div(3) |> max(18) |> min(36) |> min(width - 1)

    {
      %{rect | width: width - sidebar_width},
      %{rect | x: rect.x + width - sidebar_width, width: sidebar_width}
    }
  end

  defp split_sidebar(rect, _active?), do: {rect, nil}

  defp take_optional_row(false, available), do: {false, available}

  defp take_optional_row(true, available) when available > @min_transcript_height,
    do: {true, available - 1}

  defp take_optional_row(true, available), do: {false, available}

  defp optional_rect(true, y, width), do: {%Rect{x: 0, y: y, width: width, height: 1}, y + 1}
  defp optional_rect(false, y, _width), do: {nil, y}
end
