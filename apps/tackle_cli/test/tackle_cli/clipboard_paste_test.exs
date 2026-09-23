defmodule Tackle.CLI.TUI.ClipboardPasteTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI
  alias Tackle.CLI.TUI.{ClipboardPaste, Composer, State, Viewport}
  alias Tackle.CLI.Widgets.Input

  setup do
    dir = Path.join(System.tmp_dir!(), "tackle-paste-test-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)

    on_exit(fn ->
      for file <- File.ls!(dir), do: File.rm!(Path.join(dir, file))
      File.rmdir!(dir)
    end)

    input = Input.new()

    %{
      dir: dir,
      input: input,
      state: %State{
        input: input,
        clipboard_paste_dir: dir,
        size: {80, 24},
        conversation: Viewport.new_conversation(80, 24)
      }
    }
  end

  test "Ctrl+V requests the host asynchronously and pastes its published image", %{
    dir: dir,
    input: input,
    state: state
  } do
    command = Path.join(dir, "request")
    File.write!(command, "#!/bin/sh\nprintf 'ok\\n'\n")
    File.chmod!(command, 0o700)
    state = %{state | clipboard_paste_command: command}
    assert {:noreply, pending, commands: [_command]} = Composer.paste_clipboard(state)
    assert is_reference(pending.clipboard_paste_pending)
    assert {:noreply, duplicate} = Composer.paste_clipboard(pending)
    assert duplicate.notice =~ "already requested"

    File.write!(Path.join(dir, "image-100-1.png"), <<137, 80, 78, 71, 13, 10, 26, 10, 0>>)
    assert :ok = ClipboardPaste.request(command)

    assert {:noreply, pasted} =
             TUI.handle_info(
               {:host_clipboard_paste_result, pending.clipboard_paste_pending, :ok},
               pending
             )

    assert pasted.clipboard_paste_pending == nil
    assert [saved] = pasted.image_paths
    assert Input.get_value(input) == "[image-1]"
    File.rm!(saved)
    File.rmdir!(Path.dirname(saved))
  end

  test "failed host request preserves draft and permits retry", %{dir: dir, state: state} do
    command = Path.join(dir, "request")
    File.write!(command, "#!/bin/sh\nprintf 'unavailable\\n'\n")
    File.chmod!(command, 0o700)
    state = %{state | clipboard_paste_command: command}
    assert {:noreply, pending, commands: [_command]} = Composer.paste_clipboard(state)
    assert {:error, :host_clipboard_unavailable} = ClipboardPaste.request(command)
    ref = pending.clipboard_paste_pending

    assert {:noreply, ^pending, render?: false} =
             TUI.handle_info({:host_clipboard_paste_result, make_ref(), :ok}, pending)

    assert {:noreply, failed} =
             TUI.handle_info(
               {:host_clipboard_paste_result, ref, {:error, :host_clipboard_unavailable}},
               pending
             )

    assert failed.clipboard_paste_pending == nil
    assert failed.notice =~ "Host image paste failed"
    assert {:noreply, _retry, commands: [_command]} = Composer.paste_clipboard(failed)
  end

  test "host-published image pastes once into composer", %{dir: dir, input: input, state: state} do
    bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 0>>
    File.write!(Path.join(dir, "image-100-1.png"), bytes)

    state = ClipboardPaste.poll(state)
    assert [saved] = state.image_paths
    assert File.read!(saved) == bytes
    assert Input.get_value(input) == "[image-1]"
    assert ClipboardPaste.poll(state).image_paths == [saved]

    File.write!(Path.join(dir, "image-101-1.png"), bytes)
    state = ClipboardPaste.poll(state)
    assert length(state.image_paths) == 2

    Enum.each(state.image_paths, fn path ->
      File.rm!(path)
      File.rmdir!(Path.dirname(path))
    end)
  end

  test "defers when transcript owns input; rejects invalid and oversized images", %{
    dir: dir,
    input: input,
    state: state
  } do
    state = %{state | focus: :transcript}
    File.write!(Path.join(dir, "image-100-1.png"), "not an image")
    assert ClipboardPaste.poll(state) == state
    result = ClipboardPaste.poll(%{state | focus: :composer})
    assert result.notice =~ "failed"
    assert Input.get_value(input) == ""
    assert ClipboardPaste.poll(result) == result

    File.write!(Path.join(dir, "image-101-1.png"), :binary.copy("x", 5 * 1024 * 1024 + 1))
    assert ClipboardPaste.poll(result).notice =~ "failed"
  end
end
