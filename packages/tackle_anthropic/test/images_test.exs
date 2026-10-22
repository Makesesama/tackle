defmodule Tackle.Plugins.Anthropic.ImagesTest do
  use ExUnit.Case, async: true

  alias Tackle.Plugins.Anthropic.{Convert, Images}

  @model "claude-opus-5-5"

  describe "dimensions/1" do
    test "reads PNG, GIF, and WebP headers" do
      assert Images.dimensions(png(2556, 1394)) == {2556, 1394}
      assert Images.dimensions(gif(887, 540)) == {887, 540}
      assert Images.dimensions(webp_vp8(360, 640)) == {360, 640}
      assert Images.dimensions(webp_vp8l(4000, 3)) == {4000, 3}
      assert Images.dimensions(webp_vp8x(9000, 1200)) == {9000, 1200}
    end

    test "walks JPEG segments to the frame header, past large metadata" do
      assert Images.dimensions(jpeg(5120, 2880)) == {5120, 2880}
      assert Images.dimensions(jpeg(640, 480, metadata_bytes: 200_000)) == {640, 480}
    end

    test "returns :unknown for unrecognised, truncated, or invalid data" do
      assert Images.dimensions("AAA") == :unknown
      assert Images.dimensions("not base64!") == :unknown
      assert Images.dimensions(Base.encode64(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 200>>)) == :unknown
      assert Images.dimensions(Base.encode64(<<0x89, "PNG\r\n", 0x1A, "\n">>)) == :unknown
    end
  end

  describe "fit_limits/1" do
    test "keeps up to 20 images of any size within the single-image limit" do
      params = [user_images(List.duplicate(png(7000, 4000), 20))]

      assert Images.fit_limits(params) == params
    end

    test "omits images over 8000 px even in a small request" do
      [%{"content" => [kept, omitted]}] =
        Images.fit_limits([user_images([png(100, 100), png(8001, 10)])])

      assert kept["type"] == "image"
      assert %{"type" => "text", "text" => "[Image omitted: the 8001x10 px image" <> _} = omitted
    end

    test "over 20 images, omits those over 2000 px or of unknown size" do
      small = List.duplicate(png(2000, 2000), 19)
      params = [user_images(small ++ [png(2556, 1394), "AAA", png(10, 10)])]

      [%{"content" => blocks}] = Images.fit_limits(params)

      assert Enum.count(blocks, &(&1["type"] == "image")) == 20
      assert [large, unknown] = Enum.filter(blocks, &(&1["type"] == "text"))
      assert large["text"] =~ "2556x1394 px"
      assert large["text"] =~ "more than 20 images"
      assert unknown["text"] =~ "unknown size"
    end

    test "omits the oldest images beyond 100" do
      params = [user_images(List.duplicate(png(10, 10), 102))]

      [%{"content" => blocks}] = Images.fit_limits(params)

      assert [first, second | rest] = blocks
      assert first["text"] =~ "more than 100 images"
      assert second["text"] =~ "more than 100 images"
      assert length(rest) == 100 and Enum.all?(rest, &(&1["type"] == "image"))
    end
  end

  test "Convert counts images across user messages and tool results" do
    user_parts =
      [%{"type" => "text", "text" => "look"}] ++
        Enum.map(1..20, fn _ -> part(png(100, 100)) end)

    messages = [
      %{role: :user, content: user_parts},
      %{
        role: :assistant,
        content: nil,
        tool_calls: [%{id: "t1", function: %{name: "read", arguments: "{}"}}]
      },
      %{
        role: :tool,
        tool_call_id: "t1",
        name: "read",
        content: [%{"type" => "text", "text" => "Read image"}, part(png(3000, 1500))]
      }
    ]

    assert {:ok, [user, _assistant, %{"content" => [tool_result]}]} =
             Convert.messages(messages, @model, false)

    assert Enum.count(user["content"], &(&1["type"] == "image")) == 20

    assert [%{"type" => "text", "text" => "Read image"}, %{"type" => "text", "text" => text}] =
             tool_result["content"]

    assert text =~ "3000x1500 px"
    assert tool_result["cache_control"] == %{"type" => "ephemeral"}
  end

  defp user_images(images) do
    %{
      "role" => "user",
      "content" =>
        Enum.map(images, fn data ->
          %{
            "type" => "image",
            "source" => %{"type" => "base64", "media_type" => "image/png", "data" => data}
          }
        end)
    }
  end

  defp part(data), do: %{"type" => "image", "media_type" => "image/png", "data" => data}

  defp png(width, height) do
    Base.encode64(
      <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", width::32, height::32, 8, 6, 0, 0, 0, 0::32,
        0::size(800)>>
    )
  end

  defp gif(width, height),
    do: Base.encode64(<<"GIF89a", width::little-16, height::little-16, 0::size(800)>>)

  defp webp_vp8(width, height) do
    Base.encode64(
      <<"RIFF", 0::32, "WEBP", "VP8 ", 0::32, 0::24, 0x9D, 0x01, 0x2A, width::little-16,
        height::little-16, 0::size(800)>>
    )
  end

  defp webp_vp8l(width, height) do
    import Bitwise
    bits = width - 1 ||| (height - 1) <<< 14

    Base.encode64(<<"RIFF", 0::32, "WEBP", "VP8L", 0::32, 0x2F, bits::little-32, 0::size(800)>>)
  end

  defp webp_vp8x(width, height) do
    Base.encode64(
      <<"RIFF", 0::32, "WEBP", "VP8X", 10::little-32, 0::32, width - 1::little-24,
        height - 1::little-24, 0::size(800)>>
    )
  end

  defp jpeg(width, height, opts \\ []) do
    metadata = :binary.copy(<<0>>, Keyword.get(opts, :metadata_bytes, 16))

    # A real APP1 segment holds at most 65533 bytes; split large metadata.
    segments =
      for chunk <- chunks(metadata, 65_533), into: <<>> do
        <<0xFF, 0xE1, byte_size(chunk) + 2::16, chunk::binary>>
      end

    Base.encode64(
      <<0xFF, 0xD8, 0xFF, 0xE0, 16::16, "JFIF", 0, 1, 1, 0, 0::32, 0::16, segments::binary, 0xFF,
        0xC2, 17::16, 8, height::16, width::16, 3, 0::size(72), 0xFF, 0xDA, 0::size(800)>>
    )
  end

  defp chunks(<<>>, _size), do: []

  defp chunks(binary, size) when byte_size(binary) <= size, do: [binary]

  defp chunks(binary, size) do
    <<chunk::binary-size(^size), rest::binary>> = binary
    [chunk | chunks(rest, size)]
  end
end
