defmodule Tackle.CLI.Widgets.Surface do
  @moduledoc false

  import Bitwise

  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  @modifiers [
    {1, :bold},
    {2, :dim},
    {4, :italic},
    {8, :underlined},
    {64, :reversed},
    {256, :crossed_out}
  ]

  # One unwrapped paragraph, not one widget per cell. ExRatatui still owns
  # terminal lifecycle, final clipping, layering, and drawing the frame.
  def place([], %Rect{}), do: []

  def place(rows, %Rect{} = rect) do
    lines = Enum.map(rows, fn runs -> %Line{spans: Enum.map(runs, &span/1)} end)
    [{%Paragraph{text: lines, wrap: false}, rect}]
  end

  defp span({text, fg, bg, underline_color, bits}) do
    %Span{
      content: text,
      style: %Style{
        fg: color(fg),
        bg: color(bg),
        underline_color: color(underline_color),
        modifiers: for({mask, name} <- @modifiers, (bits &&& mask) != 0, do: name)
      }
    }
  end

  defp color(nil), do: :reset
  defp color(index) when is_integer(index), do: {:indexed, index}
  defp color({r, g, b}), do: {:rgb, r, g, b}
end
