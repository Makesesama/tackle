defmodule Tackle.CLI.ExternalEditorTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.ExternalEditor

  describe "command/1" do
    test "prefers $VISUAL over $EDITOR and ignores blank values" do
      assert ExternalEditor.command(%{"VISUAL" => "nvim", "EDITOR" => "vi"}) == {:ok, "nvim"}
      assert ExternalEditor.command(%{"VISUAL" => "  ", "EDITOR" => "vi"}) == {:ok, "vi"}

      assert ExternalEditor.command(%{"EDITOR" => " code --wait "}) == {:ok, "code --wait"}
      assert ExternalEditor.command(%{}) == {:error, :no_editor}
      assert ExternalEditor.command(%{"EDITOR" => ""}) == {:error, :no_editor}
    end
  end

  describe "edit/2" do
    test "hands the runner a private temporary file and returns what it saved" do
      test_pid = self()

      run = fn command, path ->
        send(test_pid, {:ran, command, path, File.read!(path), File.stat!(path).mode})
        # The file sits alone in a private directory, with room for swap files.
        assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
        File.write!(path <> ".swp", "editor state")
        File.write!(path, "edited ✓\n")
      end

      assert ExternalEditor.edit("draft", command: "my-editor", run: run) ==
               {:ok, "edited ✓\n"}

      assert_received {:ran, "my-editor", path, "draft", mode}
      assert Path.extname(path) == ".md"
      assert Bitwise.band(mode, 0o777) == 0o600
      refute File.exists?(Path.dirname(path))
    end

    test "uses the requested extension, so later callers can edit other kinds of text" do
      run = fn _command, path ->
        assert Path.extname(path) == ".lua"
        :ok
      end

      assert ExternalEditor.edit("return 1", command: "e", extension: ".lua", run: run) ==
               {:ok, "return 1"}
    end

    test "an unsuccessful editor, missing editor, or binary file yields no text" do
      test_pid = self()

      failing = fn _command, path ->
        send(test_pid, {:path, path})
        {:error, {:exit_status, 1}}
      end

      assert ExternalEditor.edit("draft", command: "e", run: failing) ==
               {:error, {:exit_status, 1}}

      assert_received {:path, path}
      refute File.exists?(Path.dirname(path))

      binary = fn _command, path -> File.write!(path, <<0xFF, 0xFE>>) end
      assert ExternalEditor.edit("draft", command: "e", run: binary) == {:error, :invalid_utf8}
    end
  end

  describe "run/3" do
    # These run a real shell through the native spawn, with /dev/null standing
    # in for the terminal. The "editor" is a shell fragment that ends in a
    # redirect, so the appended path is its target.
    test "runs the command through sh with the path as one argument" do
      dir = Path.join(System.tmp_dir!(), "tackle edit #{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      # A path with a space and shell syntax must arrive as one argument.
      path = Path.join(dir, "draft $(touch pwned).md")
      File.write!(path, "before")

      assert ExternalEditor.run("printf 'after' >", path, "/dev/null") == :ok
      assert File.read!(path) == "after"
      assert File.ls!(dir) == [Path.basename(path)]
    end

    test "reports the editor's exit status, and a shell that could not report one" do
      assert ExternalEditor.run("sh -c 'exit 3' sh", "file", "/dev/null") ==
               {:error, {:exit_status, 3}}

      # Output meant for the terminal never reaches the status pipe.
      assert ExternalEditor.run("echo noise; true", "file", "/dev/null") == :ok

      # A shell killed before it can report has no status to give.
      assert ExternalEditor.run("kill -KILL $$;", "file", "/dev/null") == {:error, :no_status}
    end
  end

  describe "Tackle.CLI.TUI.ExternalEditor.handoff/2" do
    alias Tackle.CLI.TUI.ExternalEditor, as: Handoff

    setup do
      tty = Path.join(System.tmp_dir!(), "tackle-tty-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(tty) end)
      %{tty: tty}
    end

    test "leaves the alternate screen around the work and restores the shell's modes", %{
      tty: tty
    } do
      assert Handoff.handoff(fn -> File.read!(tty) end, tty: tty, note: "waiting") =~
               "\e[?1049l"

      output = File.read!(tty)
      [suspended, resumed] = String.split(output, "waiting")

      for mode <- ["\e[?1000l", "\e[?1004l", "\e[?2004l", "\e[?1049l", "\e[?25h"],
          do: assert(suspended =~ mode)

      assert resumed =~ ~r/\e\[\?1049h.*\e\[2J.*\e\[\?2004h.*\e\[\?1004h.*\e\[\?1000h/s
    end

    test "restores only the modes the shell had, even when the work raises", %{tty: tty} do
      assert_raise RuntimeError, fn ->
        Handoff.handoff(fn -> raise "editor crashed" end,
          tty: tty,
          mouse_capture: false,
          focus_events: false
        )
      end

      [_suspended, resumed] = String.split(File.read!(tty), "\e[?1049l")
      assert resumed =~ "\e[?1049h"
      refute resumed =~ "\e[?1000h"
      refute resumed =~ "\e[?1004h"
    end
  end
end
