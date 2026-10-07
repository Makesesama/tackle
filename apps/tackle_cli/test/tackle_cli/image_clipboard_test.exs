defmodule Tackle.CLI.ImageClipboardTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.ImageClipboard

  describe "native clipboard reads" do
    test "encodes RGBA clipboard pixels as a PNG image" do
      # Two transparent-red pixels side by side.
      rgba = <<255, 0, 0, 0, 255, 0, 0, 0>>
      reader = fn -> {:ok, %Clipboard.Image{width: 2, height: 1, rgba: rgba}} end

      assert {:ok, png} = ImageClipboard.read(reader)
      assert {:ok, ".png"} = ImageClipboard.image_extension(png)

      assert {:ok, path} = ImageClipboard.save(png)
      assert File.read!(path) == png
      File.rm!(path)
    end

    test "reports no image when the clipboard holds other content" do
      reader = fn -> {:error, :content_not_available} end
      assert {:error, :no_image_in_clipboard} = ImageClipboard.read(reader)
    end

    test "passes other native clipboard errors through" do
      reader = fn -> {:error, :clipboard_not_supported} end
      assert {:error, :clipboard_not_supported} = ImageClipboard.read(reader)
      assert {:error, :clipboard_not_supported} = ImageClipboard.read_text(reader)
    end

    test "reads text through the native clipboard" do
      reader = fn -> {:ok, "pasted text"} end
      assert {:ok, "pasted text"} = ImageClipboard.read_text(reader)
    end
  end

  describe "PNG encoding" do
    test "produces a decodable filter-0 RGBA PNG" do
      # A single opaque blue pixel.
      assert {:ok, png} = ImageClipboard.encode_png(1, 1, <<0, 0, 255, 255>>)

      assert <<137, 80, 78, 71, 13, 10, 26, 10, rest::binary>> = png
      assert {:ok, %{width: 1, height: 1}, ihdr_rest} = ihdr(rest)
      assert {:ok, idat} = idat(ihdr_rest)
      assert :zlib.uncompress(idat) == <<0, 0, 0, 255, 255>>
    end

    test "rejects pixel buffers that do not match the dimensions" do
      assert {:error, :invalid_image} = ImageClipboard.encode_png(2, 1, <<0, 0, 0, 255>>)
      assert {:error, :invalid_image} = ImageClipboard.encode_png(0, 1, <<>>)
    end

    test "rejects absurdly large clipboard images before encoding" do
      # One column of 64 MiB + 4 bytes of RGBA exceeds the raw-pixel cap while
      # still matching its dimensions, so the size guard is what refuses it.
      height = 16_777_217
      rgba = :binary.copy(<<0>>, 4 * height)

      assert {:error, :image_too_large} = ImageClipboard.encode_png(1, height, rgba)
    end
  end

  describe "saving" do
    test "writes a validated image to an owner-only file" do
      bytes = <<137, 80, 78, 71, 13, 10, 26, 10, "rest">>
      assert {:ok, path} = ImageClipboard.save(bytes)
      assert Path.extname(path) == ".png"
      assert File.read!(path) == bytes
      File.rm!(path)
    end

    test "writes through the session's executor" do
      bytes = <<255, 216, 255, "jpeg">>

      assert {:ok, path} =
               ImageClipboard.save(bytes, Tackle.CLI.TestExecutor.new(System.tmp_dir!()))

      assert Path.extname(path) == ".jpg"
      File.rm!(path)
    end

    test "rejects unsupported content and oversized images" do
      assert {:error, :unsupported_or_invalid_image} = ImageClipboard.save("not an image")

      assert {:error, :image_too_large} =
               ImageClipboard.save(:binary.copy(<<0>>, 5 * 1024 * 1024 + 1))
    end
  end

  # -- PNG parsing helpers ---------------------------------------------------

  defp ihdr(binary) do
    assert <<13::32-big, "IHDR", data::binary-size(13), crc::32-big, rest::binary>> = binary
    assert :erlang.crc32("IHDR" <> data) == crc
    assert <<width::32-big, height::32-big, 8, 6, 0, 0, 0>> = data
    {:ok, %{width: width, height: height}, rest}
  end

  defp idat(binary) do
    assert <<length::32-big, "IDAT", data::binary-size(length), _crc::32-big, rest::binary>> =
             binary

    assert <<0::32-big, "IEND", _crc::32-big>> = rest
    {:ok, data}
  end
end
