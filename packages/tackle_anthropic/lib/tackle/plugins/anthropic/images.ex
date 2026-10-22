defmodule Tackle.Plugins.Anthropic.Images do
  @moduledoc false

  # Keeps the image blocks of a Messages request within Anthropic's request
  # limits. Sessions keep every image they have seen, so one image the API
  # rejects would otherwise fail every later request and make the session
  # impossible to resume. Images that would break a limit are replaced with a
  # text block explaining why, deterministically, so the prompt cache prefix
  # stays stable from one request to the next.
  #
  # Limits (https://platform.claude.com/docs/en/build-with-claude/vision):
  #   * each image is at most 8000x8000 px;
  #   * when a request carries more than 20 images, every image must also fit
  #     a stricter "many-image" limit; 2000 px per side is safe everywhere;
  #   * a request carries at most 100 images (600 on some models).

  import Bitwise

  @max_side 8000
  @many_images 20
  @many_images_max_side 2000
  @max_images 100

  # Enough decoded bytes to find the dimensions of a PNG, GIF, or WebP; JPEG
  # frame headers can follow large metadata segments, so they get a larger
  # prefix before falling back to decoding the whole image.
  @header_bytes 64
  @jpeg_prefix_bytes 64 * 1_024

  @type dimensions :: {pos_integer(), pos_integer()} | :unknown

  @doc """
  Replaces the image blocks of Anthropic message params that would exceed the
  request's image limits with explanatory text blocks.
  """
  @spec fit_limits([map()]) :: [map()]
  def fit_limits(params) when is_list(params) do
    {_params, sizes} = map_images(params, [], fn block, acc -> {block, [size(block) | acc]} end)
    decisions = sizes |> Enum.reverse() |> decisions()

    if Enum.all?(decisions, &(&1 == :keep)) do
      params
    else
      {params, []} = map_images(params, decisions, &apply_decision/2)
      params
    end
  end

  @doc "Reads an image's pixel dimensions from its base64 data."
  @spec dimensions(String.t()) :: dimensions()
  def dimensions(data) when is_binary(data) do
    with {:ok, bytes} <- decode_prefix(data, @header_bytes),
         :jpeg <- header_dimensions(bytes) do
      jpeg_dimensions(data)
    else
      :error -> :unknown
      result -> result
    end
  end

  def dimensions(_data), do: :unknown

  # Decides `:keep` or an omission reason for every image, oldest first.
  defp decisions(dimensions) do
    first =
      Enum.map(dimensions, fn dims ->
        if exceeds?(dims, @max_side), do: {:omit, :too_large, dims}, else: {:keep, dims}
      end)

    second =
      if count_kept(first) > @many_images do
        Enum.map(first, fn
          {:keep, dims} = kept ->
            if dims == :unknown or exceeds?(dims, @many_images_max_side),
              do: {:omit, :many_images, dims},
              else: kept

          omitted ->
            omitted
        end)
      else
        first
      end

    excess = count_kept(second) - @max_images

    {third, _excess} =
      Enum.map_reduce(second, excess, fn
        {:keep, dims}, excess when excess > 0 -> {{:omit, :too_many, dims}, excess - 1}
        decision, excess -> {decision, excess}
      end)

    Enum.map(third, fn
      {:keep, _dims} -> :keep
      omitted -> omitted
    end)
  end

  defp count_kept(decisions), do: Enum.count(decisions, &match?({:keep, _}, &1))

  defp exceeds?({width, height}, limit), do: width > limit or height > limit
  defp exceeds?(:unknown, _limit), do: false

  defp apply_decision(block, [:keep | rest]), do: {block, rest}

  defp apply_decision(_block, [{:omit, reason, dims} | rest]),
    do: {%{"type" => "text", "text" => omitted_text(reason, dims)}, rest}

  defp omitted_text(:too_large, dims) do
    "[Image omitted: #{describe(dims)} exceeds Anthropic's #{@max_side} px per-side image " <>
      "limit. Downscale it and read it again to view it.]"
  end

  defp omitted_text(:many_images, dims) do
    "[Image omitted: #{describe(dims)} exceeds the #{@many_images_max_side} px per-side limit " <>
      "Anthropic applies when a request carries more than #{@many_images} images. Downscale it " <>
      "to at most #{@many_images_max_side}x#{@many_images_max_side} px and read it again to view it.]"
  end

  defp omitted_text(:too_many, _dims) do
    "[Image omitted: the conversation carries more than #{@max_images} images, Anthropic's " <>
      "per-request limit, so the oldest images are no longer sent.]"
  end

  defp describe({width, height}), do: "the #{width}x#{height} px image"
  defp describe(:unknown), do: "an image of unknown size"

  defp size(%{"source" => %{"data" => data}}), do: dimensions(data)
  defp size(_block), do: :unknown

  # Walks every image block of the params in order, including those nested in
  # tool results, threading an accumulator through `fun`.
  defp map_images(params, acc, fun) do
    Enum.map_reduce(params, acc, fn
      %{"content" => blocks} = param, acc when is_list(blocks) ->
        {blocks, acc} = map_blocks(blocks, acc, fun)
        {%{param | "content" => blocks}, acc}

      param, acc ->
        {param, acc}
    end)
  end

  defp map_blocks(blocks, acc, fun) do
    Enum.map_reduce(blocks, acc, fn
      %{"type" => "image"} = block, acc ->
        fun.(block, acc)

      %{"type" => "tool_result", "content" => nested} = block, acc when is_list(nested) ->
        {nested, acc} = map_blocks(nested, acc, fun)
        {%{block | "content" => nested}, acc}

      block, acc ->
        {block, acc}
    end)
  end

  defp decode_prefix(data, bytes) do
    chars = prefix_chars(bytes)

    if byte_size(data) <= chars,
      do: Base.decode64(data),
      else: Base.decode64(binary_part(data, 0, chars))
  end

  defp prefix_chars(bytes), do: div(bytes + 2, 3) * 4

  defp header_dimensions(
         <<0x89, "PNG\r\n", 0x1A, "\n", _length::32, "IHDR", width::32, height::32, _::binary>>
       ),
       do: valid(width, height)

  defp header_dimensions(<<"GIF8", version, "a", width::little-16, height::little-16, _::binary>>)
       when version in [?7, ?9],
       do: valid(width, height)

  defp header_dimensions(
         <<"RIFF", _::32, "WEBP", "VP8 ", _::32, _frame::24, 0x9D, 0x01, 0x2A, width::little-16,
           height::little-16, _::binary>>
       ),
       do: valid(width &&& 0x3FFF, height &&& 0x3FFF)

  defp header_dimensions(
         <<"RIFF", _::32, "WEBP", "VP8L", _::32, 0x2F, bits::little-32, _::binary>>
       ),
       do: valid((bits &&& 0x3FFF) + 1, (bits >>> 14 &&& 0x3FFF) + 1)

  defp header_dimensions(
         <<"RIFF", _::32, "WEBP", "VP8X", _::32, _flags::32, width::little-24, height::little-24,
           _::binary>>
       ),
       do: valid(width + 1, height + 1)

  defp header_dimensions(<<0xFF, 0xD8, 0xFF, _::binary>>), do: :jpeg
  defp header_dimensions(_bytes), do: :unknown

  defp jpeg_dimensions(data) do
    with {:ok, bytes} <- decode_prefix(data, @jpeg_prefix_bytes),
         :incomplete <- jpeg_frame(bytes),
         true <- byte_size(data) > prefix_chars(@jpeg_prefix_bytes),
         {:ok, bytes} <- Base.decode64(data),
         {_width, _height} = dims <- jpeg_frame(bytes) do
      dims
    else
      {_width, _height} = dims -> dims
      _incomplete_or_invalid -> :unknown
    end
  end

  # Walks the JPEG marker segments up to the first start-of-frame header.
  defp jpeg_frame(<<0xFF, 0xD8, rest::binary>>), do: jpeg_segments(rest)
  defp jpeg_frame(_bytes), do: :unknown

  defp jpeg_segments(<<0xFF, 0xFF, rest::binary>>), do: jpeg_segments(<<0xFF, rest::binary>>)

  defp jpeg_segments(<<0xFF, marker, _length::16, _precision, height::16, width::16, _::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC],
       do: valid(width, height)

  defp jpeg_segments(<<0xFF, marker, rest::binary>>) when marker in 0xD0..0xD7 or marker == 0x01,
    do: jpeg_segments(rest)

  defp jpeg_segments(<<0xFF, marker, length::16, rest::binary>>)
       when marker not in [0xD9, 0xDA] and length >= 2 do
    skip = length - 2

    case rest do
      <<_::binary-size(^skip), rest::binary>> -> jpeg_segments(rest)
      _truncated -> :incomplete
    end
  end

  defp jpeg_segments(<<0xFF, marker, _::binary>>) when marker in [0xD9, 0xDA], do: :unknown
  defp jpeg_segments(<<0xFF, _::binary>> = bytes) when byte_size(bytes) < 10, do: :incomplete
  defp jpeg_segments(<<>>), do: :incomplete
  defp jpeg_segments(_bytes), do: :unknown

  defp valid(width, height) when width > 0 and height > 0, do: {width, height}
  defp valid(_width, _height), do: :unknown
end
