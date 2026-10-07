defmodule Tackle.CLI.ImageClipboardTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Tackle.CLI.ImageClipboard

  test "Wayland clipboard reads images and text without unsupported flags" do
    with_wl_paste(
      ~S"""
      #!/bin/sh
      case "$*" in
        "--type image/png") printf 'image-bytes' ;;
        "--type text/plain;charset=utf-8") printf 'pasted text' ;;
        *) printf 'wl-paste usage: invalid arguments\n' >&2; exit 2 ;;
      esac
      """,
      fn ->
        assert {:ok, "image-bytes"} = ImageClipboard.read()
        assert {:ok, "pasted text"} = ImageClipboard.read_text()
      end
    )
  end

  test "clipboard utility errors do not write to the terminal" do
    with_wl_paste(
      ~S"""
      #!/bin/sh
      printf 'wl-paste usage: invalid arguments\n' >&2
      exit 2
      """,
      fn ->
        assert capture_io(:stderr, fn ->
                 assert {:error, :no_image_in_clipboard} = ImageClipboard.read()
                 assert {:error, :no_image_in_clipboard} = ImageClipboard.read_text()
               end) == ""
      end
    )
  end

  defp with_wl_paste(script, fun) do
    directory =
      Path.join(System.tmp_dir!(), "tackle-clipboard-test-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    path = Path.join(directory, "wl-paste")
    File.write!(path, script)
    File.chmod!(path, 0o700)
    original_path = System.get_env("PATH")
    System.put_env("PATH", directory)

    try do
      fun.()
    after
      if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
      File.rm!(path)
      File.rmdir!(directory)
    end
  end

  test "saves supported images to a new owner-only file" do
    bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 0>>
    assert {:ok, path} = ImageClipboard.save(bytes)
    on_exit(fn -> File.rm(path) end)

    assert Path.dirname(path) == System.tmp_dir!()
    assert Path.basename(path) =~ ~r/^tackle-image-[0-9a-f]{24}\.png$/
    assert File.read!(path) == bytes
    assert File.stat!(path).mode == 0o100600
  end

  test "saves through the given executor" do
    dir = Path.join(System.tmp_dir!(), "tackle-image-exec-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    bytes = <<"GIF89a", 1, 0>>
    assert {:ok, path} = ImageClipboard.save(bytes, Tackle.CLI.TestExecutor.new(dir))
    assert Path.dirname(path) == dir
    assert String.ends_with?(path, ".gif")
    assert File.read!(path) == bytes
  end

  test "rejects unsupported and oversized data without writing a file" do
    assert {:error, :unsupported_or_invalid_image} = ImageClipboard.save("not an image")

    assert {:error, :image_too_large} =
             ImageClipboard.save(:binary.copy(<<0>>, 5 * 1024 * 1024 + 1))
  end
end
