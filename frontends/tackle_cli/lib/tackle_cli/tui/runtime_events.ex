defmodule Tackle.CLI.TUI.RuntimeEvents do
  @moduledoc """
  Projects root-harness events into shell state.

  The shell subscribes to one root agent, so every event arrives tagged with
  the session and turn it belongs to. Each clause here matches on both and
  falls through when they do not name the active turn, which is what makes a
  late delta from a finished turn a no-op instead of a mutation.

  The module owns the whole turn lifecycle as the user sees it: streaming
  reasoning and response text, the live tool cards, usage and context figures,
  and the transition into a settled, cancelled, or failed turn. It never calls
  back into rendering beyond asking `Viewport` to refresh the sections an event
  changed.
  """

  alias Tackle.CLI.TUI.{State, Util, Viewport}
  alias Tackle.Lib.{ContextUsage, Event, Usage}
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Session.Snapshot

  @doc """
  Handles one harness message, returning the mutation the ExRatatui server
  should apply.

  Messages the shell does not understand are ignored without a render.
  """
  @spec handle(term(), State.t()) ::
          {:noreply, State.t()}
          | {:noreply, State.t(), keyword()}
          | {:stop, State.t()}
  def handle(
        {:tackle_event, session_id, turn_id,
         %Event{type: :message_delta, data: %{delta: delta} = data}},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      )
      when is_binary(delta) do
    case Map.get(data, :field) do
      :reasoning ->
        state = %{
          state
          | streaming_thinking: state.streaming_thinking <> delta,
            activity: "thinking"
        }

        {:noreply, Viewport.refresh(state, [:thinking])}

      field when field in [nil, :content] ->
        state = %{
          state
          | streaming_response: state.streaming_response <> delta,
            activity: "responding"
        }

        {:noreply, Viewport.refresh(state, [:response])}

      _field ->
        {:noreply, state, render?: false}
    end
  end

  def handle(
        {:tackle_event, session_id, turn_id, %Event{type: :usage, data: %{usage: usage} = data}},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    latest_usage = Usage.normalize(usage) || state.latest_usage

    live_context_usage =
      Map.get(data, :context_usage) ||
        ContextUsage.from_usage(latest_usage, State.model_info(state.agent_state))

    {:noreply,
     %{
       state
       | latest_usage: latest_usage,
         live_usage: latest_usage,
         live_context_usage: live_context_usage
     }}
  end

  def handle(
        {:tackle_event, session_id, turn_id, %Event{type: :tool_start, data: data}},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    state = put_tool_activity(state, data, :running)
    state = %{state | activity: tool_activity_label(data, "running")}
    {:noreply, Viewport.refresh(state, [:tools])}
  end

  def handle(
        {:tackle_event, session_id, turn_id, %Event{type: :tool_end, data: data}},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    state = put_tool_activity(state, data, :completed)
    state = %{state | activity: tool_activity_label(data, "completed")}
    {:noreply, Viewport.refresh(state, [:tools])}
  end

  def handle(
        {:tackle_event, session_id, turn_id, %Event{type: :tool_error, data: data}},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    state = put_tool_activity(state, data, :failed)
    state = %{state | activity: tool_activity_label(data, "failed")}
    {:noreply, Viewport.refresh(state, [:tools])}
  end

  def handle(
        {:tackle_event, session_id, turn_id, %Event{type: type}},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    {:noreply, %{state | activity: format_activity(type)}}
  end

  def handle(
        {:tackle_turn_finished, session_id, turn_id, {outcome, %AgentState{} = agent_state}},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      )
      when outcome in [:ok, :error, :cancelled] do
    error = if outcome == :error, do: agent_state.error || "turn failed", else: nil

    state = %{
      state
      | agent_state: agent_state,
        active_turn: nil,
        pending_prompt: nil,
        streaming_thinking: "",
        streaming_response: "",
        latest_usage: State.latest_usage(agent_state) || state.latest_usage,
        live_usage: nil,
        live_context_usage: nil,
        tool_activity: [],
        activity: nil,
        error: error,
        outcome: if(outcome == :cancelled, do: :cancelled, else: nil)
    }

    {:noreply, Viewport.refresh(state)}
  end

  def handle(
        {:tackle_turn_failed, session_id, turn_id, reason},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    state = %{
      state
      | active_turn: nil,
        pending_prompt: nil,
        streaming_thinking: "",
        streaming_response: "",
        live_usage: nil,
        live_context_usage: nil,
        tool_activity: [],
        activity: nil,
        error: Util.format_reason(reason),
        outcome: :failed
    }

    {:noreply, Viewport.refresh(state, [:pending, :tools, :thinking, :response, :error])}
  end

  def handle(
        {:tackle_session_reconfigured, session_id, %Snapshot{} = snapshot},
        %State{session_id: session_id} = state
      ) do
    state = %{
      state
      | agent_state: snapshot.agent_state,
        active_turn: snapshot.active_turn,
        live_usage: nil,
        live_context_usage: nil,
        overlay: nil,
        error: nil
    }

    {:noreply, Viewport.refresh(state)}
  end

  def handle({:tackle_session_closed, session_id}, %State{session_id: session_id} = state) do
    {:stop, state}
  end

  def handle(
        {:DOWN, monitor_ref, :process, _pid, reason},
        %State{agent_monitor: monitor_ref}
      ) do
    exit({:agent_down, reason})
  end

  def handle(_message, state), do: {:noreply, state, render?: false}

  defp put_tool_activity(state, data, status) do
    id = value(data, :tool_call_id)
    name = value(data, :name) || value(data, :tool_name) || "unknown"

    updates = %{
      id: id,
      name: name,
      status: status,
      arguments: value(data, :arguments),
      result: value(data, :result),
      error: value(data, :error) || value(data, :reason)
    }

    case Enum.find_index(state.tool_activity, &same_tool?(&1, id, name)) do
      nil ->
        %{state | tool_activity: state.tool_activity ++ [updates]}

      index ->
        tool_activity =
          List.update_at(state.tool_activity, index, &merge_tool_activity(&1, updates))

        %{state | tool_activity: tool_activity}
    end
  end

  defp merge_tool_activity(existing, updates) do
    Enum.reduce(updates, existing, fn
      {_key, nil}, activity -> activity
      {key, value}, activity -> Map.put(activity, key, value)
    end)
  end

  defp same_tool?(tool, id, _name) when is_binary(id), do: tool.id == id
  defp same_tool?(tool, nil, name), do: is_nil(tool.id) and tool.name == name

  defp tool_activity_label(data, status) do
    name = value(data, :name) || value(data, :tool_name) || "tool"
    "#{status} #{name}"
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp format_activity(type) do
    type
    |> Atom.to_string()
    |> String.replace("_", " ")
  end
end
