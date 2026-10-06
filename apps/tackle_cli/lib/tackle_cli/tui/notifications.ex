defmodule Tackle.CLI.TUI.Notifications do
  @moduledoc """
  Posts a terminal notification when a turn finishes while the terminal is
  unfocused.

  Ported from codex-rs's completion notifications: the shell tracks window focus
  through terminal focus events (`ExRatatui.Event.FocusLost` /
  `FocusGained`), and a turn that finishes while the window is unfocused posts
  one notification through the writer in the shell state. A queued follow-up
  prompt suppresses the notification, because the agent keeps working through
  the next turn instead of waiting for the user.

  The body is a trimmed preview of the turn's streamed response, falling back
  to a plain outcome line when the turn produced no prose. The low-level OSC 9
  and BEL write path lives in `Tackle.CLI.Notifications`; this module decides
  when a notification is due and what it says. A failed write is dropped
  without touching the shell state, because the transcript remains the source
  of truth.
  """

  alias Tackle.CLI.TUI.State

  @doc "Returns the notification body for the finished turn in `state`."
  @spec turn_finished_message(State.t(), :ok | :error | :cancelled) :: String.t()
  def turn_finished_message(%State{} = state, :ok) do
    case String.trim(state.stream.response) do
      "" -> "Turn complete"
      preview -> preview
    end
  end

  def turn_finished_message(%State{} = state, :error) do
    case String.trim(state.stream.response) do
      "" -> "Turn failed"
      preview -> preview
    end
  end

  def turn_finished_message(%State{} = _state, :cancelled), do: "Turn cancelled"

  @doc """
  Posts the turn-finished notification when the terminal is unfocused and no
  queued prompt keeps the agent working.

  Returns `:ok`; the write's result is deliberately not surfaced because a
  failed notification never changes what the shell does next.
  """
  @spec turn_finished(State.t(), :ok | :error | :cancelled) :: :ok
  def turn_finished(%State{terminal_focused?: false, queued_prompts: []} = state, outcome) do
    _ = state.notification_writer.(turn_finished_message(state, outcome))
    :ok
  end

  def turn_finished(%State{} = _state, _outcome), do: :ok
end
