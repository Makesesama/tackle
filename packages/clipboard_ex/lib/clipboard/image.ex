defmodule Clipboard.Image do
  @moduledoc """
  Clipboard image pixels: `width * height` RGBA pixels, 8 bits per channel,
  row-major, no padding.

  Encoding to or from PNG or other file formats is left to the caller.
  """

  @enforce_keys [:width, :height, :rgba]
  defstruct [:width, :height, :rgba]

  @type t :: %__MODULE__{width: pos_integer(), height: pos_integer(), rgba: binary()}

  @doc "Whether the pixel buffer matches the dimensions."
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{width: width, height: height, rgba: rgba})
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 and
             is_binary(rgba),
      do: byte_size(rgba) == width * height * 4

  def valid?(%__MODULE__{}), do: false
end
