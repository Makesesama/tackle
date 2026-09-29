defmodule Tackle.Tools.ReadTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Tool
  alias Tackle.Lib.Tool.Content
  alias Tackle.Tools.{Output, Read}

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

  test "reads bounded selections from large files and still validates the entire text", %{
    dir: dir,
    context: context
  } do
    prefix = :binary.copy("skip\n", 20_000)
    write(dir, "large.txt", prefix <> "chosen\n" <> :binary.copy("after\n", 20_000))

    assert {:ok, "chosen\n\n[20001 more lines in file. Use offset=20002 to continue.]"} =
             Read.run(%{"path" => "large.txt", "offset" => 20_001, "limit" => 1}, context)

    File.write!(Path.join(dir, "large.txt"), prefix <> "chosen\n" <> <<0xFF>>)

    assert {:error, message} =
             Read.run(%{"path" => "large.txt", "offset" => 20_001, "limit" => 1}, context)

    assert message =~ "is not valid UTF-8"
  end

  test "validates multibyte characters across chunks and handles empty final lines", %{
    dir: dir,
    context: context
  } do
    write(dir, "utf8.txt", :binary.copy("a", 64 * 1_024 + 10) <> "\n€\n")
    assert {:ok, "€\n"} = Read.run(%{"path" => "utf8.txt", "offset" => 2}, context)
    assert {:ok, ""} = Read.run(%{"path" => "utf8.txt", "offset" => 3}, context)

    write(dir, "empty.txt", "")
    assert {:ok, ""} = Read.run(%{"path" => "empty.txt"}, context)

    assert {:error, "Offset 2 is beyond end of file (1 lines total)"} =
             Read.run(%{"path" => "empty.txt", "offset" => 2}, context)
  end

  test "large selected line reports the existing byte-limit hint", %{dir: dir, context: context} do
    write(dir, "huge.txt", :binary.copy("x", 2 * 1_024 * 1_024) <> "\nnext")

    assert {:ok,
            "[Line 1 exceeds the 50.0KB read limit. Use bash to inspect a byte range from huge.txt.]"} =
             Read.run(%{"path" => "huge.txt"}, context)

    assert {:ok, "next"} = Read.run(%{"path" => "huge.txt", "offset" => 2}, context)
  end

  test "keeps the trailing empty line at the line limit", %{dir: dir, context: context} do
    write(dir, "lines.txt", :binary.copy("x\n", 2_000))
    assert Read.run(%{"path" => "lines.txt"}, context) == {:ok, :binary.copy("x\n", 2_000)}
    assert {:ok, ""} = Read.run(%{"path" => "lines.txt", "offset" => 2_001}, context)

    write(dir, "lines.txt", :binary.copy("x\n", 2_001))
    assert {:ok, output} = Read.run(%{"path" => "lines.txt"}, context)

    assert output ==
             Enum.join(List.duplicate("x", 2_000), "\n") <>
               "\n\n[Showing lines 1-2000 of 2002. Use offset=2001 to continue.]"
  end

  test "matches whole-file selection at newline and byte boundaries", %{
    dir: dir,
    context: context
  } do
    samples = [
      "",
      "\n",
      "\n\n",
      "one\r\ntwo\n",
      "one\n\ntwo",
      :binary.copy("x\n", 2_000),
      :binary.copy("x\n", 2_001),
      :binary.copy("é", 25_600) <> "\nlast",
      :binary.copy("x", 51_199) <> "\n",
      :binary.copy("x", 51_200) <> "\n"
    ]

    for data <- samples do
      write(dir, "boundaries.txt", data)

      for offset <- [1, 2, 3, 2_000, 2_001], limit <- [nil, 1, 2, 2_000] do
        assert Read.run(
                 %{"path" => "boundaries.txt", "offset" => offset, "limit" => limit},
                 context
               ) ==
                 original_selection(data, "boundaries.txt", offset, limit)
      end
    end
  end

  defp original_selection(data, path, offset, limit) do
    lines = String.split(data, "\n")
    total = length(lines)

    if offset > total do
      {:error, "Offset #{offset} is beyond end of file (#{total} lines total)"}
    else
      selected =
        if limit, do: Enum.slice(lines, offset - 1, limit), else: Enum.drop(lines, offset - 1)

      result = Output.head(Enum.join(selected, "\n"))
      consumed = offset - 1 + length(selected)
      original_result(result, path, offset, limit, consumed, total)
    end
  end

  defp original_result(result, path, offset, limit, consumed, total) do
    cond do
      result.first_line_too_large? ->
        {:ok,
         "[Line #{offset} exceeds the 50.0KB read limit. Use bash to inspect a byte range from #{path}.]"}

      result.truncated? ->
        last = offset + result.output_lines - 1
        note = if result.truncated_by == :bytes, do: " (50KB limit)", else: ""

        {:ok,
         result.content <>
           "\n\n[Showing lines #{offset}-#{last} of #{total}#{note}. Use offset=#{last + 1} to continue.]"}

      limit && consumed < total ->
        {:ok,
         result.content <>
           "\n\n[#{total - consumed} more lines in file. Use offset=#{consumed + 1} to continue.]"}

      true ->
        {:ok, result.content}
    end
  end

  test "reports a missing file", %{context: context} do
    assert {:error, message} = Read.run(%{"path" => "missing.txt"}, context)
    assert message =~ "Could not read missing.txt:"
  end
end
