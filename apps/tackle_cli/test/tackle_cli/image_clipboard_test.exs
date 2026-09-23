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

  test "saves supported images in a private temporary directory" do
    bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 0>>
    assert {:ok, path} = ImageClipboard.save(bytes)

    on_exit(fn ->
      File.rm(path)
      File.rmdir(Path.dirname(path))
    end)

    assert File.read!(path) == bytes
    assert File.stat!(path).mode == 0o100600
    assert File.stat!(Path.dirname(path)).mode == 0o40700
  end

  test "rejects unsupported and oversized data without writing a file" do
    assert {:error, :unsupported_or_invalid_image} = ImageClipboard.save("not an image")

    assert {:error, :image_too_large} =
             ImageClipboard.save(:binary.copy(<<0>>, 5 * 1024 * 1024 + 1))
  end
end
