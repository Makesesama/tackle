defmodule Tackle.CLI.TUI.ExternalEditor do
  @moduledoc """
  Edits the composer draft in `$VISUAL` or `$EDITOR` (Ctrl+G).

  Opening the editor hands the terminal over and takes it back afterwards:

    1. The draft goes to the editor with its text pastes expanded, so the whole
       prompt can be edited. Image labels stay as written (`Pastes.editable/2`).
    2. Mouse reporting, focus reporting, and bracketed paste are switched off,
       and the shell leaves the alternate screen. A terminal editor then draws
       on an ordinary screen, and a windowed one (`code --wait`) leaves a
       short note saying what the shell is waiting for. Raw mode stays on, as
       in Codex: editors set and restore their own terminal modes, and Ctrl+C
       cannot reach the BEAM as a signal.
    3. The editor runs while the shell's process waits for it. That also stops
       the shell's input poll, so no keystroke is read by both.
    4. The modes come back, and the next frame is drawn over a blank one
       (`full_repaint?`), because the screen no longer shows what ratatui
       last drew.

  The saved text replaces the draft with trailing whitespace trimmed, and an
  image label still in it is reattached to its image. An editor that exits
  unsuccessfully (`:cq` in Vim) keeps the draft as it was.

  The shell's state carries the editing function (`:external_editor`), so tests
  substitute one that never touches the terminal. `edit/2` is the real one,
  and its `:extension` option lets other kinds of text use the same handoff.
  """

  alias ExRatatui.Command
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Clear
  alias Tackle.CLI.ExternalEditor
  alias Tackle.CLI.TUI.{Composer, Pastes, State}

  @typedoc "Edits text, returning what the user saved."
  @type editor :: (String.t() -> {:ok, String.t()} | {:error, ExternalEditor.error() | term()})

  # The message that ends the blank frame and lets the shell redraw itself.
  @repainted :tui_external_editor_repainted

  # crossterm's EnableMouseCapture and DisableMouseCapture, in its order.
  @mouse_on "\e[?1000h\e[?1002h\e[?1003h\e[?1015h\e[?1006h"
  @mouse_off "\e[?1006l\e[?1015l\e[?1003l\e[?1002l\e[?1000l"

  @doc """
  Opens the draft in the external editor and loads what the user saved.

  Returns the follow-up command that ends the blank repaint frame, unless no
  editor is configured, in which case the terminal was never handed over.
  """
  @spec open(State.t()) :: {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def open(%State{} = state) do
    {text, labels} = Pastes.editable(Pastes.draft(state), state)

    run(state, text, state.external_editor, fn state, edited ->
      draft = Pastes.reattach(String.trim_trailing(edited), labels)
      Composer.replace(state, draft)
    end)
  end

  @doc "Runs an injected editor with shared failure notices and terminal repaint."
  @spec run(State.t(), String.t(), editor(), (State.t(), String.t() -> State.t()), String.t()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def run(state, text, editor, on_save, subject \\ "draft") do
    case editor.(text) do
      {:ok, edited} ->
        repaint(on_save.(state, edited))

      {:error, :no_editor} ->
        {:noreply,
         %{state | notice: "Set $VISUAL or $EDITOR to edit the #{subject} in an editor"}}

      {:error, reason} ->
        repaint(%{state | notice: error_notice(reason, subject)})
    end
  end

  defp repaint(state) do
    {:noreply, %{state | full_repaint?: true}, commands: [Command.message(@repainted)]}
  end

  defp error_notice({:exit_status, status}, subject),
    do: "Editor exited with status #{status} · #{subject} kept"

  defp error_notice(:invalid_utf8, subject), do: "Edited text is not UTF-8 · #{subject} kept"

  defp error_notice(reason, subject),
    do: "External editor failed: #{inspect(reason)} · #{subject} kept"

  @doc "Whether `message` ends the blank repaint frame."
  @spec repainted?(term()) :: boolean()
  def repainted?(message), do: message == @repainted

  @doc """
  The blank frame drawn right after the terminal comes back.

  ratatui only writes the cells that differ from its previous frame. That frame
  is gone from the screen, so a blank frame first brings ratatui back in line
  with the cleared screen, and the next frame then draws every cell.
  """
  @spec blank(ExRatatui.Frame.t()) :: [{Clear.t(), Rect.t()}]
  def blank(%ExRatatui.Frame{width: width, height: height}),
    do: [{%Clear{}, %Rect{x: 0, y: 0, width: width, height: height}}]

  @doc """
  The default editing function: hands the terminal to the user's editor.

  After the editor exits, input that reached the terminal in the meantime is
  discarded: keys typed while a windowed editor had the user's attention would
  otherwise land in the composer (an Enter would send the draft), and late
  replies to an editor's terminal queries would read as keys. The terminal's
  current size is then sent to the calling process as an
  `ExRatatui.Event.Resize`, since the window may have changed while the
  editor had it.

  While the editor runs, the calling process waits inside a native call and
  cannot handle exit signals; a shutdown waits for the editor to close.

  ## Options

    * `:mouse_capture` and `:focus_events` - whether the shell enabled
      them, so only those modes come back. Both default to `true`.
    * `:extension` - the temporary file's extension; defaults to `".md"`.
    * `:env` - where the editor command is looked up; defaults to the
      process environment.
  """
  @spec edit(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def edit(text, opts \\ []) when is_binary(text) do
    with {:ok, command} <- ExternalEditor.command(Keyword.get(opts, :env, System.get_env())) do
      extension = Keyword.get(opts, :extension, ".md")

      result =
        handoff(
          fn -> ExternalEditor.edit(text, command: command, extension: extension) end,
          Keyword.put(opts, :note, waiting_note(command))
        )

      discard_input()
      report_size()
      result
    end
  end

  @doc false
  @spec edit_workflow(String.t()) :: {:ok, String.t()} | {:error, term()}
  def edit_workflow(text), do: edit(text, extension: ".lua")

  @doc """
  Runs `fun` with the terminal handed back to ordinary use.

  Leaves the alternate screen with mouse reporting, focus reporting, and
  bracketed paste off, shows `:note` on the ordinary screen for a windowed
  editor, and restores everything once `fun` returns or raises. Returns what
  `fun` returns.

  ## Options

    * `:mouse_capture` and `:focus_events` - see `edit/2`.
    * `:note` - one line to show while `fun` runs.
    * `:tty` - where the escape sequences go; defaults to the controlling
      terminal. Tests pass a file.
  """
  @spec handoff((-> result), keyword()) :: result when result: term()
  def handoff(fun, opts \\ []) when is_function(fun, 0) do
    tty = Keyword.get(opts, :tty, "/dev/tty")
    write_terminal(tty, [suspend_sequence(), "\r\e[2K", Keyword.get(opts, :note, "")])

    try do
      fun.()
    after
      write_terminal(tty, ["\r\e[2K", resume_sequence(opts)])
    end
  end

  defp waiting_note(command) do
    "Editing in #{command} · save and close the file to return to Tackle"
  end

  defp suspend_sequence do
    [@mouse_off, "\e[?1004l", "\e[?2004l", "\e[?1049l", "\e[?25h"]
  end

  # The alternate screen is cleared on entry too, but not by every terminal.
  defp resume_sequence(opts) do
    [
      "\e[?1049h",
      "\e[2J",
      "\e[?2004h",
      if(Keyword.get(opts, :focus_events, true), do: "\e[?1004h", else: []),
      if(Keyword.get(opts, :mouse_capture, true), do: @mouse_on, else: [])
    ]
  end

  # Reads through what the terminal sent while the editor had it. The short
  # wait catches replies to queries the editor made just before it exited;
  # the bound keeps a terminal that never goes quiet from holding the shell.
  @discard_wait_ms 20
  @discard_limit 1_000

  defp discard_input(count \\ 0)
  defp discard_input(@discard_limit), do: :ok

  defp discard_input(count) do
    case ExRatatui.poll_event(@discard_wait_ms) do
      nil -> :ok
      {:error, _reason} -> :ok
      _event -> discard_input(count + 1)
    end
  end

  defp report_size do
    case ExRatatui.terminal_size() do
      {:error, _reason} -> :ok
      {width, height} -> send(self(), %ExRatatui.Event.Resize{width: width, height: height})
    end
  end

  # The shell's standard output is the terminal crossterm draws on. Writing to
  # the controlling terminal reaches it directly, in order with the editor.
  defp write_terminal(tty, iodata) do
    case :file.open(String.to_charlist(tty), [:raw, :append, :binary]) do
      {:ok, file} ->
        _ = :file.write(file, iodata)
        _ = :file.close(file)
        :ok

      {:error, _reason} ->
        IO.write(:user, iodata)
    end
  end
end
