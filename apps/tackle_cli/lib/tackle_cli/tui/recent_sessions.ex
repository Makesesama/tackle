defmodule Tackle.CLI.TUI.RecentSessions do
  @moduledoc """
  Asynchronously loads the project's recent sessions.

  One page feeds both the dashboard's recent-session shortcuts and the
  `/resume` picker; the dashboard keeps only the first five.
  """

  alias ExRatatui.Command
  alias Tackle.CLI.TUI.State

  @doc "Starts a load without blocking the shell or delaying its first frame."
  @spec load(State.t()) :: {State.t(), [Command.t()]}
  def load(%State{list_recent_sessions: nil} = state), do: {state, []}

  def load(%State{} = state) do
    ref = make_ref()
    loader = state.list_recent_sessions

    command = Command.async(fn -> loader.(nil) end, &{:tui_recent_sessions_result, ref, &1})

    {%{state | recent_sessions: [], recent_sessions_ref: ref}, [command]}
  end

  @doc "Applies only the result of the latest request for the current session."
  @spec apply_result(State.t(), reference(), term()) ::
          {:noreply, State.t()} | {:noreply, State.t(), keyword()}
  def apply_result(%State{recent_sessions_ref: ref} = state, ref, result)
      when is_reference(ref) do
    sessions =
      case result do
        {:ok, %{sessions: sessions}} when is_list(sessions) ->
          sessions |> Enum.reject(&(Map.get(&1, :session_id) == state.session_id))

        _other ->
          []
      end

    {:noreply, %{state | recent_sessions: sessions, recent_sessions_ref: nil}}
  end

  def apply_result(%State{} = state, _ref, _result),
    do: {:noreply, state, render?: false}
end
