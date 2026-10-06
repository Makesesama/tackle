defmodule Tackle.CLI.TUI.TerminalTitle do
  @moduledoc """
  Keeps the terminal's window title in sync with the shell's session and state.

  The title names the session and its current activity, so tab bars and window
  managers can tell Tackle windows apart at a glance: `tackle · <session> ·
  <activity>`, falling back to `idle` between turns. It is recomputed on the
  transitions the shell already funnels through key dispatch and runtime
  events, deduplicated against the last title written so steady state emits
  nothing, and cleared when the shell exits.

  Sanitization and the OSC write live in `Tackle.CLI.TerminalTitle`; this
  module decides what the title says and owns the last-written cache in the
  shell state. A title whose visible content sanitizes away clears the managed
  title, and a failed write leaves the cache alone so the next transition
  retries it.
  """

  alias Tackle.CLI.TUI.State

  @doc "Returns the title text for `state`."
  @spec text(State.t()) :: String.t()
  def text(%State{} = state) do
    ["tackle", session(state), activity(state)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
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

  defp session(%State{session_id: nil}), do: nil

  # The session id is a UUID; its first block is enough to tell windows apart
  # without spending the title on it.
  defp session(%State{session_id: session_id}), do: String.slice(session_id, 0, 8)

  defp activity(%State{activity: activity}) when is_binary(activity), do: activity
  defp activity(%State{active_turn: turn}) when turn != nil, do: "working"
  defp activity(%State{}), do: "idle"
end
