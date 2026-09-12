defmodule Tackle.Tools.ReadTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.Content
  alias Tackle.Tools.Read

  @png <<0x89, "PNG\r\n", 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0, 0, 0, 1>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, "JFIF", 0>>
  @gif <<"GIF89a", 1, 0, 1, 0>>
  @webp <<"RIFF", 0, 0, 0, 0, "WEBP", "VP8 ", 0>>

  setup do
    dir = Path.join(System.tmp_dir!(), "tackle-read-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir, context: %{cwd: dir}}
  end

  defp write(dir, name, data) do
    path = Path.join(dir, name)
    File.write!(path, data)
    path
  end

  test "reads a UTF-8 text file", %{dir: dir, context: context} do
    write(dir, "notes.txt", "one\ntwo\nthree\n")

    assert {:ok, "one\ntwo\nthree\n"} = Read.run(%{"path" => "notes.txt"}, context)
  end

  test "honours offset and limit for text files", %{dir: dir, context: context} do
    write(dir, "notes.txt", "one\ntwo\nthree\n")

    assert {:ok, content} =
             Read.run(%{"path" => "notes.txt", "offset" => 2, "limit" => 1}, context)

    assert content =~ "two"
    assert content =~ "Use offset=3 to continue."
  end

  test "returns a PNG as an image content part", %{dir: dir, context: context} do
    write(dir, "shot.png", @png)

    assert {:ok, %Content{} = content} = Read.run(%{"path" => "shot.png"}, context)

    assert content.text =~ "Read image shot.png (image/png,"
    assert content.text =~ "The image is attached"

    assert [%{"type" => "image", "media_type" => "image/png", "data" => data}] = content.parts
    assert Base.decode64!(data) == @png
  end

  test "settle/3 carries image parts onto the tool result", %{dir: dir, context: context} do
    write(dir, "shot.png", @png)

    call = %Tool.Call{id: "call_1", name: "read", arguments: %{"path" => "shot.png"}}

    assert {:ok, %Tool.Result{} = result} = Tool.settle(Read, call, context)
    assert result.content =~ "Read image shot.png (image/png,"
    assert [%{"type" => "image"}] = result.parts
  end

  test "detects other supported image formats", %{dir: dir, context: context} do
    for {name, bytes, media_type} <- [
          {"shot.jpeg", @jpeg, "image/jpeg"},
          {"shot.gif", @gif, "image/gif"},
          {"shot.webp", @webp, "image/webp"}
        ] do
      write(dir, name, bytes)

      assert {:ok, %Content{parts: [part]}} = Read.run(%{"path" => name}, context)
      assert part["media_type"] == media_type
    end
  end

  test "rejects offset and limit for images", %{dir: dir, context: context} do
    write(dir, "shot.png", @png)

    assert {:error, message} =
             Read.run(%{"path" => "shot.png", "limit" => 10}, context)

    assert message == "offset and limit apply only to text files"
  end

  test "rejects an image larger than the read limit", %{dir: dir, context: context} do
    write(dir, "huge.png", @png <> :binary.copy(<<0>>, 5 * 1_024 * 1_024))

    assert {:error, message} = Read.run(%{"path" => "huge.png"}, context)
    assert message =~ "larger than the 5.0MB image read limit"
  end

  test "rejects binary data that is not a supported image", %{dir: dir, context: context} do
    write(dir, "blob.bin", <<0, 1, 2, 3, 0xFF>>)

    assert {:error, message} = Read.run(%{"path" => "blob.bin"}, context)
    assert message =~ "is not valid UTF-8 and is not a supported image"
  end

  test "reports a missing file", %{context: context} do
    assert {:error, message} = Read.run(%{"path" => "missing.txt"}, context)
    assert message =~ "Could not read missing.txt:"
  end
end
