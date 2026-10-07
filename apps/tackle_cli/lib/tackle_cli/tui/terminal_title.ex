defmodule Tackle.CLI.TUI.TerminalTitle do
  @moduledoc """
  Keeps the terminal's window title in sync with the shell's session and state.

  The title names the app, the session, the current activity, and the project
  directory so tab bars and window managers can tell Tackle windows apart at a
  glance: `tackle | <session> | <activity> | <project>`, falling back to `idle`
  between turns. While a turn or shell operation runs, the activity label is
  preceded by the current braille spinner frame, so an unfocused tab still
  shows live progress.

  The composition follows codex-rs's terminal title where it matters:

    * segments join with ASCII ` | `, because some terminals and multiplexers
      decode OSC title payloads as Latin-1 or truncate them to one byte per
      character, which turns a Unicode separator into mojibake
    * raw event names never reach the title: the activity is a curated label,
      and `idle` wins over any stale label once no turn or shell operation is
      running
    * the spinner frames match the GNU Screen ASCII fallback in
      `Tackle.CLI.TerminalTitle`'s sanitizer, so the animation stays visible
      under Screen
    * the project segment is truncated the way codex truncates title parts,
      so one long name cannot eat the title

  Sanitization and the OSC write live in `Tackle.CLI.TerminalTitle`; this
  module decides what the title says and owns the last-written cache in the
  shell state. A title whose visible content sanitizes away clears the managed
  title, and a failed write leaves the cache alone so the next transition
  retries it.
  """

  alias Tackle.CLI.TUI.State

  # Braille spinner frames, matching codex-rs TERMINAL_TITLE_SPINNER_FRAMES.
  # Keep in sync with the :screen ASCII fallback in Tackle.CLI.TerminalTitle
  # so GNU Screen keeps a visible animation.
  @spinner_frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

  # Codex truncates the project-name title part to 24 characters.
  @max_project_chars 24

  @doc "Returns the title text for `state`."
  @spec text(State.t()) :: String.t()
  def text(%State{} = state) do
    ["tackle", session(state), activity(state), project()]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" | ")
  end

  @doc """
  Writes the title for `state` when it changed.

  Returns the state with the last-written title updated, so an unchanged title
  is not rewritten. The session id is untrusted display text like any other
  title source, so the writer sanitizes before emitting the sequence.
  """
  @spec refresh(State.t()) :: State.t()
  def refresh(%State{} = state) do
    title = text(state)

    if title == state.terminal_title do
      state
    else
      case state.terminal_title_writer.(title) do
        {:ok, :applied} -> %{state | terminal_title: title}
        {:ok, :no_visible_content} -> clear(state)
        {:error, _reason} -> state
      end
    end
  end

  @doc """
  Clears the managed title; a no-op when none was written.

  This clears the visible title; it does not restore whatever title the shell
  or a previous program may have set before Tackle started managing the title.
  """
  @spec clear(State.t()) :: State.t()
  def clear(%State{terminal_title: nil} = state), do: state

  def clear(%State{} = state) do
    case state.terminal_title_writer.(nil) do
      :ok -> %{state | terminal_title: nil}
      {:error, _reason} -> state
    end
  end

  # A generated or explicit session title names the window; an untitled
  # session falls back to the id's first block. The title is bounded by the
  # generator and sanitized by the writer like any other title source.
  defp session(%State{session_title: title}) when is_binary(title) and title != "",
    do: title

  defp session(%State{session_id: nil}), do: nil

  # The session id is a UUID; its first block is enough to tell windows apart
  # without spending the title on it.
  defp session(%State{session_id: session_id}), do: String.slice(session_id, 0, 8)

  # The spinner animates only while a turn or shell operation runs, which is
  # exactly when the shell subscribes to spinner ticks; codex-rs gives the
  # activity indicator a plain space on either side for the same reason.
  defp activity(%State{active_turn: nil, pending_operation: nil} = state),
    do: activity_label(state)

  defp activity(%State{} = state),
    do: spinner_frame(state) <> " " <> activity_label(state)

  # The activity label is curated. Idle wins over any stale label so the last
  # event of a turn cannot outlive it; codex-rs renders "Ready" for the same
  # reason instead of trusting the last status bucket.
  defp activity_label(%State{active_turn: nil, pending_operation: nil}), do: "idle"

  # Shell operations run between turns and carry their own short labels.
  defp activity_label(%State{active_turn: nil, pending_operation: operation}),
    do: operation_activity(operation)

  defp activity_label(%State{activity: activity}) when is_binary(activity), do: activity
  defp activity_label(%State{}), do: "working"

  defp operation_activity(%{kind: :submit}), do: "starting"
  defp operation_activity(%{kind: :cancel}), do: "cancelling"
  defp operation_activity(%{kind: :compact}), do: "compacting"
  defp operation_activity(_operation), do: "working"

  defp spinner_frame(%State{spinner_frame: frame}) do
    Enum.at(@spinner_frames, rem(frame, length(@spinner_frames)))
  end

  # The project segment mirrors codex-rs's default project-name item: the
  # working directory's basename, omitted when there is no working directory.
  defp project do
    case File.cwd() do
      {:ok, cwd} -> truncate_part(Path.basename(cwd), @max_project_chars)
      {:error, _reason} -> nil
    end
  end

  @doc """
  Truncates `value` to at most `max_chars` graphemes.

  Ports codex-rs's `truncate_terminal_title_part`: the cut is marked with
  `...` when that leaves room for it, so a truncated segment still reads as
  truncated rather than merely wrong.
  """
  @spec truncate_part(String.t(), non_neg_integer()) :: String.t()
  def truncate_part(value, max_chars) when max_chars <= 3,
    do: String.slice(value, 0, max_chars)

  def truncate_part(value, max_chars) do
    if String.length(value) <= max_chars do
      value
    else
      String.slice(value, 0, max_chars - 3) <> "..."
    end
  end
end
