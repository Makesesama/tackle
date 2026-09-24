defmodule Tackle.CLI.TUI.Glyph do
  @moduledoc """
  A seven-by-six pixel Tackle mark for the terminal welcome screen.

  Each palette letter is one square pixel, painted as two terminal columns of
  `█`. Dots are transparent; no terminal background color is assumed. The
  small square on the right is intentionally detached from the stem.
  """

  alias ExRatatui.Style
  alias Tackle.CLI.TUI.MessageView

  @pixels [
    "ab...ef",
    "abccdef",
    ".bbcde.",
    "..cd...",
    "..gd.f.",
    "..gg..."
  ]

  @colors %{
    ?a => {:rgb, 0, 205, 223},
    ?b => {:rgb, 5, 174, 235},
    ?c => {:rgb, 8, 111, 239},
    ?d => {:rgb, 42, 70, 190},
    ?e => {:rgb, 101, 77, 242},
    ?f => {:rgb, 156, 58, 242},
    ?g => {:rgb, 53, 43, 175}
  }

  @width 14

  @doc "Encodes the pixel grid as a transparent PNG for graphics-capable terminals."
  @spec png() :: binary()
  def png do
    # Eight source pixels per grid cell; the image widget scales this to the
    # terminal's cell dimensions while keeping its aspect ratio.
    scale = 8
    width = 7 * scale
    height = length(@pixels) * scale

    scanlines =
      @pixels
      |> Enum.flat_map(fn line ->
        pixels =
          line
          |> String.to_charlist()
          |> Enum.map(fn
            ?. ->
              <<0, 0, 0, 0>>

            color ->
              {:rgb, r, g, b} = Map.fetch!(@colors, color)
              <<r, g, b, 255>>
          end)
          |> Enum.map_join(&String.duplicate(&1, scale))

        List.duplicate(<<0, pixels::binary>>, scale)
      end)
      |> IO.iodata_to_binary()

    signature = <<137, 80, 78, 71, 13, 10, 26, 10>>
    header = <<width::32, height::32, 8, 6, 0, 0, 0>>

    signature <>
      chunk("IHDR", header) <>
      chunk("IDAT", :zlib.compress(scanlines)) <>
      chunk("IEND", <<>>)
  end

  defp chunk(type, data) do
    checksum = :erlang.crc32(type <> data)
    <<byte_size(data)::32, type::binary, data::binary, checksum::32>>
  end

  @doc "Width of the glyph in terminal columns."
  @spec width() :: pos_integer()
  def width, do: @width

  @doc "Returns six styled rows, each containing seven equal-sized pixels."
  @spec rows() :: [MessageView.row()]
  def rows do
    Enum.map(@pixels, fn pixels ->
      pixels
      |> String.to_charlist()
      |> Enum.map(fn
        ?. -> MessageView.span("  ")
        color -> MessageView.span("██", %Style{fg: Map.fetch!(@colors, color)})
      end)
      |> MessageView.row()
    end)
  end
end
