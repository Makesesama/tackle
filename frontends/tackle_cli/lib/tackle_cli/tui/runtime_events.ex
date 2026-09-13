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

  alias Tackle.CLI.TUI.{
    Compaction,
    Observations,
    State,
    Subagents,
    Tree,
    UsageChart,
    Util,
    Viewport
  }

  alias Tackle.CLI.TUI.State.{Metrics, Stream}
  alias Tackle.CLI.Widgets.Input
  alias Tackle.Lib.{ContextUsage, Event, Usage}
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Session.Snapshot

  @stream_frame_ms 32

  @doc "Handles one harness or shell-operation message."
  @spec handle(term(), State.t()) ::
          {:noreply, State.t()}
          | {:noreply, State.t(), keyword()}
          | {:stop, State.t()}
  def handle(message, state), do: route(message, Observations.observe(message, state))

  defp route({:tui_spinner_tick}, %State{} = state) do
    if busy?(state) do
      state = %{state | spinner_frame: state.spinner_frame + 1}
      {:noreply, refresh_subagent_clocks(state)}
    else
      {:noreply, state, render?: false}
    end
  end

  defp route({:tui_flush_stream, ref}, %State{stream: %Stream{flush_ref: ref}} = state) do
    {:noreply, Viewport.refresh(%{state | stream: %{state.stream | flush_ref: nil}}, [:turn])}
  end

  defp route({:tui_flush_stream, _stale_ref}, state),
    do: {:noreply, state, render?: false}

  defp route(
         {:tui_operation_result, ref, :submit, result},
         %State{pending_operation: %{ref: ref, kind: :submit} = operation} = state
       ) do
    case result do
      {:ok, turn_id} when is_binary(turn_id) ->
        case state.active_turn do
          nil ->
            state = %{
              state
              | pending_operation: nil,
                deferred_events: [],
                active_turn: %{id: turn_id},
                activity: "starting",
                error: nil,
                outcome: nil
            }

            state =
              state |> Viewport.update_draft() |> Viewport.refresh([:pending, :turn, :error])

            submit_started(state, operation, [])

          %{id: ^turn_id} ->
            submit_started(%{state | pending_operation: nil, deferred_events: []}, operation, [])

          %{id: active_turn_id} ->
            submit_failed(state, operation, {:unexpected_turn, active_turn_id, turn_id})
        end

      {:error, reason} ->
        submit_failed(state, operation, reason)

      other ->
        submit_failed(state, operation, {:invalid_submit_result, other})
    end
  end

  defp route(
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

  defp route(
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

  defp route(
         {:tui_operation_result, ref, :cancel, result},
         %State{pending_operation: %{ref: ref, kind: :cancel}} = state
       ) do
    case result do
      :ok -> {:noreply, %{state | pending_operation: nil, activity: "cancelling"}}
      {:error, reason} -> operation_failed(state, reason)
      other -> operation_failed(state, {:invalid_cancel_result, other})
    end
  end

  defp route(
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

  defp route({:tui_operation_result, _ref, _kind, _result}, state),
    do: {:noreply, state, render?: false}

  defp route({:tui_usage_timeline_result, ref, mode, session_id, result}, state),
    do: UsageChart.apply_result(state, ref, mode, session_id, result)

  # Manual compaction broadcasts its progress and completion while the idle
  # session performs the summarization; the operation result above remains the
  # authoritative state update.
  defp route(
         {:tackle_compaction, session_id, %Event{} = event},
         %State{session_id: session_id} = state
       ) do
    {:noreply,
     state |> Compaction.project(event.type, event.data) |> Viewport.refresh([:settled, :turn])}
  end

  defp route({:tackle_compaction, _session_id, _event}, state),
    do: {:noreply, state, render?: false}

  defp route(
         {:tackle_session_compacted, session_id, %Snapshot{} = snapshot, record},
         %State{session_id: session_id} = state
       ) do
    state = %{state | agent_state: snapshot.agent_state}
    {:noreply, state |> Compaction.completed(record) |> Viewport.refresh()}
  end

  defp route({:tackle_session_compacted, _session_id, _snapshot, _record}, state),
    do: {:noreply, state, render?: false}

  # Another frontend can navigate the same session while this shell is attached.
  # Refresh from the committed snapshot so every attached view agrees, without
  # touching the local draft or overlay.
  defp route(
         {:tackle_session_navigated, session_id, %Snapshot{} = snapshot, outcome},
         %State{session_id: session_id, pending_operation: nil} = state
       ) do
    state = %{state | agent_state: snapshot.agent_state, active_turn: snapshot.active_turn}
    {:noreply, state |> Tree.apply_outcome(outcome) |> Viewport.refresh()}
  end

  defp route({:tackle_session_navigated, _session_id, _snapshot, _outcome}, state),
    do: {:noreply, state, render?: false}

  # The session can emit from the new turn before the asynchronous submit
  # command reports its id. The event already carries that id, and only one turn
  # can be admitted for this pending submit, so install it immediately instead
  # of withholding a potentially large stream behind another sender's reply.
  defp route(
         {:tackle_event, session_id, turn_id, %Event{}} = message,
         %State{session_id: session_id, active_turn: nil, pending_operation: %{kind: :submit}} =
           state
       ) do
    project_early_turn(message, turn_id, state)
  end

  defp route(
         {:tackle_turn_finished, session_id, turn_id, _result} = message,
         %State{session_id: session_id, active_turn: nil, pending_operation: %{kind: :submit}} =
           state
       ) do
    project_early_turn(message, turn_id, state)
  end

  defp route(
         {:tackle_turn_failed, session_id, turn_id, _reason} = message,
         %State{session_id: session_id, active_turn: nil, pending_operation: %{kind: :submit}} =
           state
       ) do
    project_early_turn(message, turn_id, state)
  end

  defp route(
         {:tackle_event, session_id, turn_id, %Event{type: :retry_scheduled, id: event_id}},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       ) do
    message_id = event_id || state.stream.active_message_id
    timeline = Enum.reject(state.stream.timeline, &(&1[:message_id] == message_id))

    stream = %{
      state.stream
      | thinking: timeline_text(timeline, :thinking),
        response: timeline_text(timeline, :assistant),
        timeline: timeline,
        flush_ref: nil
    }

    {:noreply, Viewport.refresh(%{state | stream: stream}, [:turn])}
  end

  # Message identity is part of the live projection. Keeping it here prevents
  # adjacent deltas from separate LLM iterations from being rendered as one
  # continuously rewritten response.
  defp route(
         {:tackle_event, session_id, turn_id,
          %Event{type: :message_start, id: id, data: %{role: :assistant}}},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       )
       when is_binary(id) do
    {:noreply, %{state | stream: %{state.stream | active_message_id: id}}, render?: false}
  end

  defp route(
         {:tackle_event, session_id, turn_id,
          %Event{type: :message_delta, id: event_id, data: %{delta: delta} = data}},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       )
       when is_binary(delta) do
    message_id = event_id || state.stream.active_message_id

    case Map.get(data, :field) do
      :reasoning ->
        stream = %{
          state.stream
          | thinking: state.stream.thinking <> delta,
            timeline: append_text(state.stream.timeline, :thinking, delta, message_id)
        }

        state = %{state | stream: stream, activity: "thinking"}

        stream_reply(state)

      field when field in [nil, :content] ->
        stream = %{
          state.stream
          | response: state.stream.response <> delta,
            timeline: append_text(state.stream.timeline, :assistant, delta, message_id)
        }

        state = %{state | stream: stream, activity: "responding"}

        stream_reply(state)

      _field ->
        {:noreply, state, render?: false}
    end
  end

  # Replace streamed text with the canonical message while preserving its place
  # among tool and compaction entries. This makes live and settled transcripts
  # agree even when a provider's terminal payload differs from its deltas.
  defp route(
         {:tackle_event, session_id, turn_id,
          %Event{
            type: :message_end,
            data: %{message: %Tackle.Lib.Message{id: id, role: :assistant} = message}
          }},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       ) do
    ids = append_message_id(state.stream.message_ids, id)
    {timeline, reconciled?} = reconcile_message(state.stream.timeline, message, state.stream)

    stream = %{
      state.stream
      | timeline: timeline,
        message_ids: ids,
        active_message_id: nil,
        flush_ref: if(reconciled?, do: nil, else: state.stream.flush_ref)
    }

    state = %{state | stream: stream}

    if reconciled?,
      do: {:noreply, Viewport.refresh(state, [:turn])},
      else: {:noreply, state, render?: false}
  end

  # Canonical message boundaries let live compaction entries retain their place
  # when streaming output is replaced by the finished turn's transcript.
  defp route(
         {:tackle_event, session_id, turn_id,
          %Event{type: :message_end, data: %{message: %Tackle.Lib.Message{id: id}}}},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       ) do
    ids = append_message_id(state.stream.message_ids, id)
    {:noreply, %{state | stream: %{state.stream | message_ids: ids}}, render?: false}
  end

  defp route(
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
        do: append(state.metrics.turn_usages, normalized_usage),
        else: state.metrics.turn_usages

    metrics = %{
      state.metrics
      | latest_usage: latest_usage,
        turn_usages: turn_usages,
        context_usage: context_usage
    }

    {:noreply, %{state | metrics: metrics}}
  end

  defp route(
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
        activity: tool_activity_label(tool, "running")
    }

    {:noreply, state |> Subagents.reconcile() |> Viewport.refresh([:turn])}
  end

  defp route(
         {:tackle_event, session_id, turn_id,
          %Event{type: :tool_execution_end, data: %{status: status} = data}},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       )
       when status in [:completed, :failed] do
    settle_tool(state, data, status, Atom.to_string(status))
  end

  defp route(
         {:tackle_event, session_id, turn_id, %Event{type: :tool_end, data: data}},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       ) do
    settle_tool(state, data, :completed, "completed")
  end

  defp route(
         {:tackle_event, session_id, turn_id, %Event{type: :tool_error, data: data}},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       ) do
    settle_tool(state, data, :failed, "failed")
  end

  defp route(
         {:tackle_event, session_id, turn_id, %Event{type: :status_change, data: data}},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       ) do
    activity = value(data, :status) |> format_activity()
    {:noreply, %{state | activity: activity}}
  end

  defp route(
         {:tackle_event, session_id, turn_id, %Event{type: type} = event},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       )
       when type in [:compaction_start, :compaction_end, :compaction_retry] do
    {:noreply,
     state |> Compaction.project(event.type, event.data) |> Viewport.refresh([:settled, :turn])}
  end

  defp route(
         {:tackle_event, session_id, turn_id, %Event{type: type}},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       ) do
    {:noreply, %{state | activity: format_activity(type)}}
  end

  defp route(
         {:tackle_turn_finished, session_id, turn_id, {outcome, %AgentState{} = agent_state}},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       )
       when outcome in [:ok, :error, :cancelled] do
    state = state |> Compaction.settle(agent_state) |> UsageChart.invalidate_cache()
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

    {:noreply, state |> Subagents.reconcile() |> Viewport.refresh()}
  end

  defp route(
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

    {:noreply,
     state |> Subagents.reconcile() |> Viewport.refresh([:settled, :pending, :turn, :error])}
  end

  defp route(
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

  defp route({:tackle_session_closed, session_id}, %State{session_id: session_id} = state) do
    {:stop, state}
  end

  defp route(
         {:DOWN, monitor_ref, :process, _pid, reason},
         %State{agent_monitor: monitor_ref}
       ) do
    exit({:agent_down, reason})
  end

  defp route(_message, state), do: {:noreply, state, render?: false}

  defp project_early_turn(message, turn_id, state) do
    state = %{state | active_turn: %{id: turn_id}, deferred_events: []}
    route(message, Observations.observe(message, state))
  end

  defp submit_started(state, operation, commands) do
    if Map.get(operation, :cancellation_requested?, false) and state.active_turn != nil do
      {state, cancel_command} = cancel_command(%{state | activity: "cancelling"})
      {:noreply, state, commands: append(commands, cancel_command)}
    else
      {:noreply, state, commands: commands}
    end
  end

  defp submit_failed(state, operation, reason) do
    if Input.get_value(state.input) == "" do
      :ok = Input.set_value(state.input, operation.raw_draft)
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

  defp timeline_text(timeline, kind) do
    timeline
    |> Enum.filter(&(&1[:kind] == kind))
    |> Enum.map_join(& &1.content)
  end

  defp append_text(timeline, kind, delta, message_id) do
    case List.pop_at(timeline, -1) do
      {%{kind: ^kind} = entry, rest} ->
        if Map.get(entry, :message_id) == message_id do
          append(rest, %{entry | content: entry.content <> delta})
        else
          append(timeline, text_timeline_entry(kind, delta, message_id))
        end

      _other ->
        append(timeline, text_timeline_entry(kind, delta, message_id))
    end
  end

  defp text_timeline_entry(kind, content, message_id) when is_binary(message_id) do
    %{
      kind: kind,
      content: content,
      message_id: message_id,
      id: "streaming:#{message_id}:#{kind}"
    }
  end

  defp text_timeline_entry(kind, content, _message_id), do: %{kind: kind, content: content}

  defp reconcile_message(timeline, message, stream) do
    index = Enum.find_index(timeline, &(&1[:message_id] == message.id))
    canonical_entries = canonical_message_entries(message)

    cond do
      is_integer(index) ->
        remaining = Enum.reject(timeline, &(&1[:message_id] == message.id))
        {Enum.take(remaining, index) ++ canonical_entries ++ Enum.drop(remaining, index), true}

      stream.active_message_id == message.id and canonical_entries != [] ->
        {timeline ++ canonical_entries, true}

      true ->
        {timeline, false}
    end
  end

  defp canonical_message_entries(message) do
    []
    |> maybe_append_message_text(:thinking, message.thinking, message.id)
    |> maybe_append_message_text(:assistant, message.content, message.id)
  end

  defp maybe_append_message_text(entries, kind, content, message_id)
       when is_binary(content) and content != "" do
    append(entries, text_timeline_entry(kind, content, message_id))
  end

  defp maybe_append_message_text(entries, _kind, _content, _message_id), do: entries

  defp append_message_id(ids, id), do: if(id in ids, do: ids, else: append(ids, id))

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
        activity: tool_activity_label(tool, label)
    }

    {:noreply, state |> Subagents.reconcile() |> Viewport.refresh([:turn])}
  end

  defp put_timeline_tool(timeline, nil), do: timeline

  defp put_timeline_tool(timeline, tool) do
    case Enum.find_index(timeline, &same_timeline_tool?(&1, tool)) do
      nil -> append(timeline, Map.put(tool, :kind, :tool))
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
        %{state | tool_activity: append(state.tool_activity, observe_tool_time(updates))}

      index ->
        tool_activity =
          List.update_at(state.tool_activity, index, fn tool ->
            tool |> merge_tool_activity(updates) |> observe_tool_time()
          end)

        %{state | tool_activity: tool_activity}
    end
  end

  # Local observation time only: never persisted or presented as provider
  # latency. Ordered settlement may repeat execution completion; freeze once.
  defp observe_tool_time(%{name: "subagent", status: status} = tool) do
    now = System.monotonic_time(:millisecond)

    case {status, Map.get(tool, :started_at_ms), Map.get(tool, :finished_at_ms)} do
      {:running, nil, nil} ->
        tool |> Map.put(:started_at_ms, now) |> Map.put(:elapsed_ms, 0)

      {status, started, nil} when status in [:completed, :failed] and is_integer(started) ->
        tool |> Map.put(:finished_at_ms, now) |> Map.put(:elapsed_ms, max(now - started, 0))

      _ ->
        tool
    end
  end

  defp observe_tool_time(tool), do: tool

  defp refresh_subagent_clocks(state) do
    now = System.monotonic_time(:millisecond)

    tools =
      Enum.map(state.tool_activity, fn
        %{name: "subagent", status: :running, started_at_ms: started} = tool ->
          Map.put(tool, :elapsed_ms, div(max(now - started, 0), 1_000) * 1_000)

        tool ->
          tool
      end)

    if tools == state.tool_activity do
      state
    else
      timeline = Enum.reduce(tools, state.stream.timeline, &put_timeline_tool(&2, &1))
      state = %{state | tool_activity: tools, stream: %{state.stream | timeline: timeline}}
      Viewport.refresh(state, [:turn])
    end
  end

  defp append(items, item), do: Enum.reverse([item | Enum.reverse(items)])

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

    profile =
      if name == "subagent" do
        args = Tackle.CLI.TUI.ToolView.arguments(value(data, :arguments))

        case value(args, :profile) do
          profile when is_binary(profile) -> " · " <> profile
          _ -> ""
        end
      else
        ""
      end

    "#{status} #{name}#{profile}" |> Tackle.CLI.TUI.MessageView.sanitize()
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
