defmodule Tackle.CLI.TUI.RuntimeEvents do
  @moduledoc """
  Projects root-harness events and asynchronous shell operations into state.

  Live turn output is retained as an ordered timeline. Reasoning, assistant
  prose, and tools therefore remain where they occurred instead of being
  grouped into type-based buckets at the bottom of the transcript.

  Streaming deltas are coalesced into one paint per short frame in an actual
  terminal. This keeps input responsive when a provider emits many tiny
  deltas, while the complete source is appended to state immediately.
  """

  alias ExRatatui.Command
  alias Tackle.CLI.TUI.{Compaction, State, Tree, Util, Viewport}
  alias Tackle.CLI.TUI.State.{Metrics, Stream}
  alias Tackle.Lib.{ContextUsage, Event, Usage}
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Session.Snapshot

  @stream_frame_ms 32

  @doc "Handles one harness or shell-operation message."
  @spec handle(term(), State.t()) ::
          {:noreply, State.t()}
          | {:noreply, State.t(), keyword()}
          | {:stop, State.t()}
  def handle({:tui_spinner_tick}, %State{} = state) do
    if busy?(state) do
      {:noreply, %{state | spinner_frame: state.spinner_frame + 1}}
    else
      {:noreply, state, render?: false}
    end
  end

  def handle({:tui_flush_stream, ref}, %State{stream: %Stream{flush_ref: ref}} = state) do
    {:noreply, Viewport.refresh(%{state | stream: %{state.stream | flush_ref: nil}}, [:turn])}
  end

  def handle({:tui_flush_stream, _stale_ref}, state),
    do: {:noreply, state, render?: false}

  def handle(
        {:tui_operation_result, ref, :submit, result},
        %State{pending_operation: %{ref: ref, kind: :submit} = operation} = state
      ) do
    case result do
      {:ok, turn_id} when is_binary(turn_id) ->
        deferred = state.deferred_events

        state = %{
          state
          | deferred_events: [],
            active_turn: %{id: turn_id},
            activity: "starting",
            error: nil,
            outcome: nil
        }

        state = state |> Viewport.update_draft() |> Viewport.refresh([:pending, :turn, :error])
        deferred_commands = Enum.map(deferred, &Command.message/1)

        if Map.get(operation, :cancellation_requested?, false) do
          {state, cancel_command} = cancel_command(%{state | activity: "cancelling"})
          {:noreply, state, commands: deferred_commands ++ [cancel_command]}
        else
          {:noreply, %{state | pending_operation: nil}, commands: deferred_commands}
        end

      {:error, reason} ->
        submit_failed(state, operation, reason)

      other ->
        submit_failed(state, operation, {:invalid_submit_result, other})
    end
  end

  def handle(
        {:tui_operation_result, ref, :reconfigure, result},
        %State{pending_operation: %{ref: ref, kind: :reconfigure}} = state
      ) do
    case result do
      {:ok, %Snapshot{} = snapshot} ->
        state = %{
          state
          | pending_operation: nil,
            agent_state: snapshot.agent_state,
            active_turn: snapshot.active_turn,
            error: nil,
            outcome: nil
        }

        {:noreply, Viewport.refresh(state)}

      {:error, reason} ->
        operation_failed(state, reason)

      other ->
        operation_failed(state, {:invalid_reconfigure_result, other})
    end
  end

  def handle(
        {:tui_operation_result, ref, :compact, result},
        %State{pending_operation: %{ref: ref, kind: :compact}} = state
      ) do
    case result do
      {:ok, %Snapshot{} = snapshot, record} ->
        state = %{
          state
          | pending_operation: nil,
            agent_state: snapshot.agent_state,
            active_turn: snapshot.active_turn,
            activity: nil,
            error: nil,
            outcome: nil,
            notice: nil
        }

        {:noreply, state |> Compaction.completed(record) |> Viewport.refresh()}

      {:error, reason} ->
        compaction_failed(state, reason)

      other ->
        compaction_failed(state, {:invalid_compact_result, other})
    end
  end

  def handle(
        {:tui_operation_result, ref, :cancel, result},
        %State{pending_operation: %{ref: ref, kind: :cancel}} = state
      ) do
    case result do
      :ok -> {:noreply, %{state | pending_operation: nil, activity: "cancelling"}}
      {:error, reason} -> operation_failed(state, reason)
      other -> operation_failed(state, {:invalid_cancel_result, other})
    end
  end

  def handle(
        {:tui_operation_result, ref, :navigate, result},
        %State{pending_operation: %{ref: ref, kind: :navigate}} = state
      ) do
    case result do
      {:ok, %Snapshot{} = snapshot, outcome} ->
        state = %{
          state
          | pending_operation: nil,
            agent_state: snapshot.agent_state,
            active_turn: snapshot.active_turn,
            activity: nil,
            error: nil,
            outcome: nil
        }

        {:noreply, state |> Tree.apply_outcome(outcome) |> Viewport.refresh()}

      {:error, reason} ->
        operation_failed(state, reason)

      other ->
        operation_failed(state, {:invalid_navigate_result, other})
    end
  end

  def handle({:tui_operation_result, _ref, _kind, _result}, state),
    do: {:noreply, state, render?: false}

  # Manual compaction broadcasts its progress and completion while the idle
  # session performs the summarization; the operation result above remains the
  # authoritative state update.
  def handle(
        {:tackle_compaction, session_id, %Event{} = event},
        %State{session_id: session_id} = state
      ) do
    {:noreply,
     state |> Compaction.project(event.type, event.data) |> Viewport.refresh([:settled, :turn])}
  end

  def handle({:tackle_compaction, _session_id, _event}, state),
    do: {:noreply, state, render?: false}

  def handle(
        {:tackle_session_compacted, session_id, %Snapshot{} = snapshot, record},
        %State{session_id: session_id} = state
      ) do
    state = %{state | agent_state: snapshot.agent_state}
    {:noreply, state |> Compaction.completed(record) |> Viewport.refresh()}
  end

  def handle({:tackle_session_compacted, _session_id, _snapshot, _record}, state),
    do: {:noreply, state, render?: false}

  # Another frontend can navigate the same session while this shell is attached.
  # Refresh from the committed snapshot so every attached view agrees, without
  # touching the local draft or overlay.
  def handle(
        {:tackle_session_navigated, session_id, %Snapshot{} = snapshot, outcome},
        %State{session_id: session_id, pending_operation: nil} = state
      ) do
    state = %{state | agent_state: snapshot.agent_state, active_turn: snapshot.active_turn}
    {:noreply, state |> Tree.apply_outcome(outcome) |> Viewport.refresh()}
  end

  def handle({:tackle_session_navigated, _session_id, _snapshot, _outcome}, state),
    do: {:noreply, state, render?: false}

  # A turn can begin emitting from its supervised task before the asynchronous
  # submit command's reply reaches this process. Hold those messages briefly;
  # the submit result re-enqueues them after installing the correlated turn id.
  def handle(
        {:tackle_event, session_id, _turn_id, %Event{}} = message,
        %State{session_id: session_id, active_turn: nil, pending_operation: %{kind: :submit}} =
          state
      ) do
    {:noreply, %{state | deferred_events: state.deferred_events ++ [message]}, render?: false}
  end

  def handle(
        {:tackle_turn_finished, session_id, _turn_id, _result} = message,
        %State{session_id: session_id, active_turn: nil, pending_operation: %{kind: :submit}} =
          state
      ) do
    {:noreply, %{state | deferred_events: state.deferred_events ++ [message]}, render?: false}
  end

  def handle(
        {:tackle_turn_failed, session_id, _turn_id, _reason} = message,
        %State{session_id: session_id, active_turn: nil, pending_operation: %{kind: :submit}} =
          state
      ) do
    {:noreply, %{state | deferred_events: state.deferred_events ++ [message]}, render?: false}
  end

  def handle(
        {:tackle_event, session_id, turn_id,
         %Event{type: :message_delta, data: %{delta: delta} = data}},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      )
      when is_binary(delta) do
    case Map.get(data, :field) do
      :reasoning ->
        stream = %{
          state.stream
          | thinking: state.stream.thinking <> delta,
            timeline: append_text(state.stream.timeline, :thinking, delta)
        }

        state = %{state | stream: stream, activity: "thinking"}

        stream_reply(state)

      field when field in [nil, :content] ->
        stream = %{
          state.stream
          | response: state.stream.response <> delta,
            timeline: append_text(state.stream.timeline, :assistant, delta)
        }

        state = %{state | stream: stream, activity: "responding"}

        stream_reply(state)

      _field ->
        {:noreply, state, render?: false}
    end
  end

  # Canonical message boundaries let live compaction entries retain their place
  # when streaming output is replaced by the finished turn's transcript.
  def handle(
        {:tackle_event, session_id, turn_id,
         %Event{type: :message_end, data: %{message: %Tackle.Lib.Message{id: id}}}},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    ids = state.stream.message_ids
    ids = if id in ids, do: ids, else: ids ++ [id]
    {:noreply, %{state | stream: %{state.stream | message_ids: ids}}, render?: false}
  end

  def handle(
        {:tackle_event, session_id, turn_id, %Event{type: :usage, data: %{usage: usage} = data}},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    normalized_usage = Usage.normalize(usage)
    latest_usage = normalized_usage || state.metrics.latest_usage

    context_usage =
      Map.get(data, :context_usage) ||
        ContextUsage.from_usage(latest_usage, State.model_info(state.agent_state))

    turn_usages =
      if normalized_usage,
        do: state.metrics.turn_usages ++ [normalized_usage],
        else: state.metrics.turn_usages

    metrics = %{
      state.metrics
      | latest_usage: latest_usage,
        turn_usages: turn_usages,
        context_usage: context_usage
    }

    {:noreply, %{state | metrics: metrics}}
  end

  def handle(
        {:tackle_event, session_id, turn_id, %Event{type: :tool_start, data: data}},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    state = put_tool_activity(state, data, :running)
    tool = find_tool(state.tool_activity, data)

    state = %{
      state
      | stream: %{
          state.stream
          | timeline: put_timeline_tool(state.stream.timeline, tool),
            flush_ref: nil
        },
        activity: tool_activity_label(data, "running")
    }

    {:noreply, Viewport.refresh(state, [:turn])}
  end

  def handle(
        {:tackle_event, session_id, turn_id, %Event{type: :tool_end, data: data}},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    settle_tool(state, data, :completed, "completed")
  end

  def handle(
        {:tackle_event, session_id, turn_id, %Event{type: :tool_error, data: data}},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    settle_tool(state, data, :failed, "failed")
  end

  def handle(
        {:tackle_event, session_id, turn_id, %Event{type: :status_change, data: data}},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    activity = value(data, :status) |> format_activity()
    {:noreply, %{state | activity: activity}}
  end

  def handle(
        {:tackle_event, session_id, turn_id, %Event{type: type} = event},
        %State{session_id: session_id, active_turn: %{id: turn_id}} = state
      )
      when type in [:compaction_start, :compaction_end, :compaction_retry] do
    {:noreply,
     state |> Compaction.project(event.type, event.data) |> Viewport.refresh([:settled, :turn])}
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
    state = Compaction.settle(state, agent_state)
    error = if outcome == :error, do: agent_state.error || "turn failed", else: nil

    state = %{
      state
      | agent_state: agent_state,
        active_turn: nil,
        pending_prompt: nil,
        stream: Stream.reset(state.stream),
        pending_operation: nil,
        deferred_events: [],
        metrics: %Metrics{
          latest_usage: State.latest_usage(agent_state) || state.metrics.latest_usage
        },
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
    state = Compaction.settle(state, state.agent_state)

    state = %{
      state
      | active_turn: nil,
        pending_prompt: nil,
        stream: Stream.reset(state.stream),
        pending_operation: nil,
        deferred_events: [],
        metrics: Metrics.reset(state.metrics),
        tool_activity: [],
        activity: nil,
        error: Util.format_reason(reason),
        outcome: :failed
    }

    {:noreply, Viewport.refresh(state, [:settled, :pending, :turn, :error])}
  end

  def handle(
        {:tackle_session_reconfigured, session_id, %Snapshot{} = snapshot},
        %State{session_id: session_id} = state
      ) do
    state = %{
      state
      | agent_state: snapshot.agent_state,
        active_turn: snapshot.active_turn,
        metrics: Metrics.reset(state.metrics),
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

  defp submit_failed(state, operation, reason) do
    if ExRatatui.textarea_get_value(state.input) == "" do
      :ok = ExRatatui.textarea_set_value(state.input, operation.raw_draft)
    end

    state = %{
      state
      | pending_operation: nil,
        deferred_events: [],
        pending_prompt: nil,
        activity: nil,
        error: Util.format_reason(reason),
        outcome: :failed
    }

    state = state |> Viewport.update_draft() |> Viewport.relayout()
    {:noreply, Viewport.refresh(state, [:pending, :error])}
  end

  defp compaction_failed(state, reason) do
    state = Compaction.project(state, :compaction_end, %{status: :failed, error: reason})
    operation_failed(Viewport.refresh(state, [:settled, :turn]), reason)
  end

  defp cancel_command(state) do
    ref = make_ref()
    agent_ref = state.agent_ref

    command =
      Command.async(
        fn -> Tackle.cancel(agent_ref) end,
        &{:tui_operation_result, ref, :cancel, &1}
      )

    {%{state | pending_operation: %{ref: ref, kind: :cancel}}, command}
  end

  defp operation_failed(state, reason) do
    state = %{
      state
      | pending_operation: nil,
        overlay: nil,
        activity: nil,
        error: Util.format_reason(reason),
        outcome: :failed
    }

    {:noreply, Viewport.refresh(state, [:error])}
  end

  defp stream_reply(%State{stream: %Stream{coalesce?: false}} = state),
    do: {:noreply, Viewport.refresh(state, [:turn])}

  defp stream_reply(%State{stream: %Stream{flush_ref: ref}} = state) when is_reference(ref),
    do: {:noreply, state, render?: false}

  defp stream_reply(state) do
    ref = make_ref()

    {:noreply, %{state | stream: %{state.stream | flush_ref: ref}},
     render?: false, commands: [Command.send_after(@stream_frame_ms, {:tui_flush_stream, ref})]}
  end

  defp append_text(timeline, kind, delta) do
    case List.pop_at(timeline, -1) do
      {%{kind: ^kind} = entry, rest} ->
        rest ++ [%{entry | content: entry.content <> delta}]

      _other ->
        timeline ++ [%{kind: kind, content: delta}]
    end
  end

  defp settle_tool(state, data, status, label) do
    state = put_tool_activity(state, data, status)
    tool = find_tool(state.tool_activity, data)

    state = %{
      state
      | stream: %{
          state.stream
          | timeline: put_timeline_tool(state.stream.timeline, tool),
            flush_ref: nil
        },
        activity: tool_activity_label(data, label)
    }

    {:noreply, Viewport.refresh(state, [:turn])}
  end

  defp put_timeline_tool(timeline, nil), do: timeline

  defp put_timeline_tool(timeline, tool) do
    case Enum.find_index(timeline, &same_timeline_tool?(&1, tool)) do
      nil -> timeline ++ [Map.put(tool, :kind, :tool)]
      index -> List.replace_at(timeline, index, Map.put(tool, :kind, :tool))
    end
  end

  defp same_timeline_tool?(%{kind: :tool, id: id}, %{id: id}) when not is_nil(id), do: true

  defp same_timeline_tool?(%{kind: :tool, id: nil, name: name}, %{id: nil, name: name}),
    do: true

  defp same_timeline_tool?(_entry, _tool), do: false

  defp find_tool(tools, data) do
    id = value(data, :tool_call_id)
    name = value(data, :name) || value(data, :tool_name) || "unknown"
    Enum.find(tools, &same_tool?(&1, id, name))
  end

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

  defp value(_other, _key), do: nil

  defp format_activity(nil), do: "working"

  defp format_activity(type) when is_atom(type) do
    type |> Atom.to_string() |> String.replace("_", " ")
  end

  defp format_activity(type) when is_binary(type), do: String.replace(type, "_", " ")
  defp format_activity(_other), do: "working"

  defp busy?(state), do: not is_nil(state.active_turn) or not is_nil(state.pending_operation)
end
