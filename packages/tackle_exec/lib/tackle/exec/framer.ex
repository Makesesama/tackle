defmodule Tackle.Exec.Framer do
  @moduledoc """
  Incremental decoder for 4-byte big-endian length-prefixed frames.

  The host reads the exec-server port in `:stream` mode and frames the data
  itself, because port `{:packet, 4}` framing has no maximum size: a forged
  length header could make the host allocate an arbitrary amount of memory.
  This framer rejects any length above its configured maximum before buffering
  the frame body.

  Chunks are kept in a list until a frame is complete, so a large frame that
  arrives in many small chunks is copied once instead of once per chunk.
  """

  @enforce_keys [:max]
  defstruct max: nil, chunks: [], size: 0, need: nil

  @typedoc "Framer state."
  @type t :: %__MODULE__{
          max: pos_integer(),
          chunks: [binary()],
          size: non_neg_integer(),
          need: non_neg_integer() | nil
        }

  @doc "Creates a framer that rejects frames larger than `max` bytes."
  @spec new(pos_integer()) :: t()
  def new(max) when is_integer(max) and max > 0, do: %__MODULE__{max: max}

  @doc """
  Adds received bytes and returns every completed frame in arrival order.

  Returns `{:error, {:frame_too_large, length}}` as soon as a header announces
  a frame above the maximum. The framer must not be used after an error.
  """
  @spec push(t(), binary()) ::
          {:ok, [binary()], t()} | {:error, {:frame_too_large, non_neg_integer()}}
  def push(%__MODULE__{} = framer, ""), do: {:ok, [], framer}

  def push(%__MODULE__{} = framer, data) when is_binary(data) do
    collect(%{framer | chunks: [data | framer.chunks], size: framer.size + byte_size(data)}, [])
  end

  defp collect(%{need: nil, size: size} = framer, frames) when size < 4 do
    {:ok, Enum.reverse(frames), framer}
  end

  defp collect(%{need: nil} = framer, frames) do
    <<length::32, rest::binary>> = flatten(framer.chunks)

    if length > framer.max do
      {:error, {:frame_too_large, length}}
    else
      collect(%{framer | need: length, chunks: [rest], size: byte_size(rest)}, frames)
    end
  end

  defp collect(%{need: need, size: size} = framer, frames) when size < need do
    {:ok, Enum.reverse(frames), framer}
  end

  defp collect(%{need: need} = framer, frames) do
    <<frame::binary-size(^need), rest::binary>> = flatten(framer.chunks)
    collect(%{framer | need: nil, chunks: [rest], size: byte_size(rest)}, [frame | frames])
  end

  defp flatten([chunk]), do: chunk
  defp flatten(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()
end
