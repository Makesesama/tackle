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
    MessageView,
    Observations,
    RecentSessions,
    State,
    Subagents,
    ToolView,
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
  @queue_notice_ms 3_000
  @max_live_tool_input_bytes 50 * 1_024
  @max_live_tool_output_bytes 50 * 1_024
  @max_subagent_work_bytes 16 * 1_024

  @doc "Handles one harness or shell-operation message."
  @spec handle(term(), State.t()) ::
          {:noreply, State.t()}
          | {:noreply, State.t(), keyword()}
          | {:stop, State.t()}
  def handle(message, state), do: route(message, Observations.observe(message, state))

  defp route({:tui_spinner_tick}, %State{} = state) do
    expired = expire_queue_notice(state)

    if busy?(expired) do
      state = %{expired | spinner_frame: expired.spinner_frame + 1}
      {:noreply, refresh_subagent_clocks(state)}
    else
      {:noreply, expired, render?: expired != state}
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

      {:ok, :queued} ->
        state = %{
          state
          | pending_operation: nil,
            deferred_events: [],
            queued_prompts: state.queued_prompts ++ [operation.prompt],
            notice: "Message queued for the next safe boundary",
            queue_notice_at: System.monotonic_time(:millisecond)
        }

        {:noreply, Viewport.refresh(state, [:turn])}

      {:error, reason} ->
        submit_failed(state, operation, reason)

      other ->
        submit_failed(state, operation, {:invalid_submit_result, other})
    end
  end

  defp route(
         {:tui_operation_result, ref, :withdraw_queued, result},
         %State{pending_operation: %{ref: ref, kind: :withdraw_queued, prompt: prompt}} = state
       ) do
    state = %{state | pending_operation: nil}

    case result do
      :ok ->
        # Preserve edits made while the withdrawal was in flight.
        draft = Input.get_value(state.input)
        restored = if draft == "", do: prompt, else: prompt <> "\n" <> draft
        :ok = Input.set_value(state.input, restored)

        queued_prompts =
          state.queued_prompts
          |> Enum.reverse()
          |> List.delete(prompt)
          |> Enum.reverse()

        state = %{
          state
          | queued_prompts: queued_prompts,
            notice: "Queued message restored to composer",
            queue_notice_at: nil
        }

        {:noreply,
         state |> Viewport.update_draft() |> Viewport.relayout() |> Viewport.refresh([:turn])}

      {:error, :not_queued} ->
        {:noreply, %{state | notice: "Message already delivered; cannot take it back"}}

      {:error, reason} ->
        {:noreply,
         %{state | notice: "Could not take back message: #{Util.format_reason(reason)}"}}
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

  defp route({:tui_recent_sessions_result, ref, result}, state),
    do: RecentSessions.apply_result(state, ref, result)

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
         {:tackle_session_compacted, session_id, %Snapshot{} = snapshot, nil},
         %State{session_id: session_id} = state
       ) do
    {:noreply, %{state | agent_state: snapshot.agent_state} |> Viewport.refresh()}
  end

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

  # A background subagent terminal notice wakes an idle parent without a frontend
  # submit command. Adopt that internally-started continuation before its events;
  # the session broadcasts this message before processing the turn task's output.
  defp route(
         {:tackle_turn_started, session_id, turn_id, reason},
         %State{session_id: session_id, active_turn: nil} = state
       )
       when reason in [:background_notice, :queued_messages] do
    state = %{
      state
      | active_turn: %{id: turn_id, operation: :continue, cancellation_requested?: false},
        pending_prompt: nil,
        stream: Stream.reset(state.stream),
        deferred_events: [],
        activity:
          if(reason == :queued_messages,
            do: "processing queued messages",
            else: "processing subagent notice"
          ),
        error: nil,
        outcome: nil
    }

    {:noreply, Viewport.refresh(state, [:pending, :turn, :error])}
  end

  defp route({:tackle_turn_started, _session_id, _turn_id, :background_notice}, state),
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

    tool_activity =
      Enum.reject(state.tool_activity, fn tool ->
        tool[:status] == :preparing and tool[:message_id] == message_id
      end)

    stream = %{
      state.stream
      | thinking: timeline_text(timeline, :thinking),
        response: timeline_text(timeline, :assistant),
        timeline: timeline,
        flush_ref: nil
    }

    {:noreply, Viewport.refresh(%{state | stream: stream, tool_activity: tool_activity}, [:turn])}
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

      :tool_input ->
        state = put_streaming_tool_input(state, data, delta, message_id)
        stream_reply(state)

      _field ->
        {:noreply, state, render?: false}
    end
  end

  # Queued user messages arrive as complete messages, without streaming deltas.
  defp route(
         {:tackle_event, session_id, turn_id,
          %Event{
            type: :message_end,
            data: %{message: %Tackle.Lib.Message{id: id, role: :user, content: content}}
          }},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       ) do
    ids = append_message_id(state.stream.message_ids, id)

    cond do
      id in state.stream.message_ids ->
        {:noreply, state, render?: false}

      content == state.pending_prompt ->
        stream = %{
          state.stream
          | message_ids: ids,
            timeline:
              state.stream.timeline ++
                [%{kind: :user, content: content, id: "streaming:#{id}:user", message_id: id}]
        }

        {:noreply,
         Viewport.refresh(%{state | pending_prompt: nil, stream: stream}, [:pending, :turn])}

      true ->
        queued_prompts = pop_queued_prompt(state.queued_prompts, content)

        stream = %{
          state.stream
          | message_ids: ids,
            timeline:
              state.stream.timeline ++
                [%{kind: :user, content: content, id: "streaming:#{id}:user", message_id: id}]
        }

        state = %{
          state
          | stream: stream,
            queued_prompts: queued_prompts,
            notice:
              if(queued_prompts == [] and state.queue_notice_at, do: nil, else: state.notice),
            queue_notice_at: if(queued_prompts == [], do: nil, else: state.queue_notice_at)
        }

        {:noreply, Viewport.refresh(state, [:turn])}
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
         {:tackle_event, session_id, turn_id, %Event{type: :subagent_started, data: data}},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       ) do
    tool_call_id = value(data, :tool_call_id)
    model = value(data, :model)

    tracked = Map.get(state.subagents, value(data, :run_id), %{})

    tools =
      Enum.map(state.tool_activity, fn
        %{id: ^tool_call_id, name: "subagent"} = tool when is_binary(tool_call_id) ->
          tool
          |> maybe_put_value(:model, model)
          |> maybe_put_value(:run_id, value(data, :run_id))
          |> maybe_put_value(:agent_ref, value(data, :agent_ref))
          |> maybe_put_value(:subagent_work, Map.get(tracked, :work))
          |> maybe_put_value(:subagent_output, Map.get(tracked, :work_output))

        tool ->
          tool
      end)

    subagents = put_subagent(state.subagents, data, find_tool(tools, data))
    timeline = Enum.reduce(tools, state.stream.timeline, &put_timeline_tool(&2, &1))

    {:noreply,
     Viewport.refresh(
       %{
         state
         | tool_activity: tools,
           subagents: subagents,
           stream: %{state.stream | timeline: timeline}
       },
       [:turn]
     )}
  end

  defp route(
         {:tackle_event, session_id, _turn_id, %Event{type: :subagent_finished, data: data}},
         %State{session_id: session_id} = state
       ) do
    state = %{state | subagents: put_subagent(state.subagents, data)}
    {:noreply, state |> Subagents.reconcile() |> Viewport.relayout()}
  end

  defp route(
         {:tackle_event, session_id, _turn_id, %Event{type: :subagent_progress, data: data}},
         %State{session_id: session_id} = state
       ) do
    state = state |> put_subagent_progress(data) |> Subagents.reconcile()
    stream_reply(state)
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
         {:tackle_event, session_id, turn_id, %Event{type: :tool_progress, data: data}},
         %State{session_id: session_id, active_turn: %{id: turn_id}} = state
       ) do
    state = put_tool_progress(state, data)
    stream_reply(state)
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
        notice: nil,
        queue_notice_at: nil,
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
        notice: nil,
        queue_notice_at: nil,
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

  # Stop the terminal App normally, then let its runner report the runtime
  # failure. Raising here only adds a second GenServer crash to the agent loss.
  defp route(
         {:DOWN, monitor_ref, :process, _pid, reason},
         %State{agent_monitor: monitor_ref, owner: owner} = state
       ) do
    if is_pid(owner), do: send(owner, {:tui_runtime_error, {:agent_down, reason}})
    {:stop, state}
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
        pending_prompt: if(state.active_turn, do: state.pending_prompt, else: nil),
        activity: if(state.active_turn, do: state.activity, else: nil),
        error: Util.format_reason(reason),
        outcome: if(state.active_turn, do: state.outcome, else: :failed)
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

  defp put_streaming_tool_input(state, data, delta, message_id) do
    id = value(data, :tool_call_id)
    name = value(data, :tool_name) || value(data, :name) || "tool"
    current = find_tool(state.tool_activity, %{tool_call_id: id, name: name})

    arguments =
      case value(data, :arguments) do
        arguments when is_binary(arguments) ->
          arguments

        arguments when is_map(arguments) ->
          arguments

        _other ->
          append_bounded_prefix(value(current, :arguments), delta, @max_live_tool_input_bytes)
      end

    state =
      put_tool_activity(
        state,
        %{tool_call_id: id, name: name, arguments: arguments, message_id: message_id},
        :preparing
      )

    tool = find_tool(state.tool_activity, %{tool_call_id: id, name: name})

    %{
      state
      | stream: %{
          state.stream
          | timeline: put_timeline_tool(state.stream.timeline, tool),
            flush_ref: state.stream.flush_ref
        },
        activity: tool_activity_label(tool, "receiving")
    }
  end

  defp append_bounded_prefix(current, delta, max_bytes) when is_binary(delta) do
    current = if is_binary(current), do: current, else: ""

    if byte_size(current) >= max_bytes do
      current
    else
      content = current <> delta

      if byte_size(content) <= max_bytes,
        do: content,
        else: take_valid_prefix(content, max_bytes)
    end
  end

  defp append_bounded_prefix(current, _delta, _max_bytes), do: current

  defp take_valid_prefix(content, bytes) do
    prefix = binary_part(content, 0, bytes)

    cond do
      String.valid?(prefix) -> prefix
      bytes > 0 -> take_valid_prefix(content, bytes - 1)
      true -> ""
    end
  end

  defp put_tool_progress(state, data) do
    id = value(data, :tool_call_id)
    name = value(data, :name) || value(data, :tool_name) || "unknown"
    delta = value(data, :delta) || value(data, :output) || ""
    current = find_tool(state.tool_activity, data)
    output = append_bounded(value(current, :result), delta, @max_live_tool_output_bytes)

    state = put_tool_activity(state, %{tool_call_id: id, name: name, result: output}, :running)
    tool = find_tool(state.tool_activity, data)

    %{
      state
      | stream: %{
          state.stream
          | timeline: put_timeline_tool(state.stream.timeline, tool),
            flush_ref: state.stream.flush_ref
        },
        activity: tool_activity_label(tool, "running")
    }
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
      error: value(data, :error) || value(data, :reason),
      message_id: value(data, :message_id)
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

    subagents =
      Map.new(state.subagents, fn
        {run_id, %{status: :running, started_at_ms: started} = subagent}
        when is_integer(started) ->
          {run_id, Map.put(subagent, :elapsed_ms, div(max(now - started, 0), 1_000) * 1_000)}

        entry ->
          entry
      end)

    if tools == state.tool_activity and subagents == state.subagents do
      state
    else
      timeline = Enum.reduce(tools, state.stream.timeline, &put_timeline_tool(&2, &1))

      state = %{
        state
        | tool_activity: tools,
          subagents: subagents,
          stream: %{state.stream | timeline: timeline}
      }

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

  defp put_subagent_progress(state, data) do
    run_id = value(data, :run_id)
    child_event = value(data, :event) || value(data, :child_event)
    existing = Map.get(state.subagents, run_id, %{run_id: run_id})
    updated = project_subagent_work(existing, child_event, data)

    subagents =
      if is_binary(run_id), do: Map.put(state.subagents, run_id, updated), else: state.subagents

    tools =
      Enum.map(state.tool_activity, fn tool ->
        if same_subagent_progress?(tool, data) do
          tool
          |> maybe_put_value(:subagent_work, Map.get(updated, :work))
          |> maybe_put_value(:subagent_output, Map.get(updated, :work_output))
        else
          tool
        end
      end)

    timeline = Enum.reduce(tools, state.stream.timeline, &put_timeline_tool(&2, &1))

    %{
      state
      | subagents: subagents,
        tool_activity: tools,
        stream: %{state.stream | timeline: timeline}
    }
  end

  defp project_subagent_work(existing, %Event{type: type, data: event_data}, _data),
    do: project_subagent_event(existing, type, event_data)

  defp project_subagent_work(existing, %{type: type, data: event_data}, _data)
       when is_map(event_data),
       do: project_subagent_event(existing, type, event_data)

  defp project_subagent_work(existing, _child_event, data) do
    case value(data, :delta) || value(data, :activity) do
      text when is_binary(text) -> put_subagent_text(existing, text, value(data, :field))
      _other -> existing
    end
  end

  defp project_subagent_event(existing, :message_delta, data) do
    put_subagent_text(existing, value(data, :delta) || "", value(data, :field))
  end

  defp project_subagent_event(existing, :tool_start, data) do
    name = value(data, :name) || value(data, :tool_name) || "tool"

    existing
    |> Map.put(:work_phase, {:tool, value(data, :tool_call_id) || name})
    |> Map.put(:work_buffer, "")
    |> Map.put(:work_boundary?, true)
    |> Map.put(:work, "Running #{name}#{subagent_target(name, value(data, :arguments))}")
  end

  defp project_subagent_event(existing, :tool_progress, data) do
    delta = value(data, :delta) || value(data, :output) || ""
    delta = if is_binary(delta), do: delta, else: ""
    phase = {:tool, value(data, :tool_call_id) || value(data, :name) || "tool"}
    put_subagent_activity(existing, delta, phase, nil)
  end

  defp project_subagent_event(existing, type, data)
       when type in [:tool_end, :tool_execution_end] do
    name = value(data, :name) || value(data, :tool_name) || "tool"

    existing
    |> Map.put(:work_phase, nil)
    |> Map.put(:work_buffer, "")
    |> Map.put(:work, "Completed #{name}")
  end

  defp project_subagent_event(existing, :tool_error, data) do
    name = value(data, :name) || value(data, :tool_name) || "tool"

    existing
    |> Map.put(:work_phase, nil)
    |> Map.put(:work_buffer, "")
    |> Map.put(:work, "Failed #{name}")
  end

  defp project_subagent_event(existing, :status_change, data) do
    Map.put(existing, :work, value(data, :status) |> format_activity())
  end

  defp project_subagent_event(existing, _type, _data), do: existing

  defp put_subagent_text(existing, "", _field), do: existing

  defp put_subagent_text(existing, delta, field) do
    prefix = if field == :reasoning, do: "Thinking: ", else: "Writing: "
    put_subagent_activity(existing, delta, {:message, field || :content}, prefix)
  end

  defp put_subagent_activity(existing, delta, phase, prefix) do
    phase_changed? = Map.get(existing, :work_phase) != phase
    boundary? = Map.get(existing, :work_boundary?, false)
    current_buffer = if phase_changed? or boundary?, do: "", else: Map.get(existing, :work_buffer)
    buffer = append_bounded(current_buffer, delta, @max_subagent_work_bytes)

    separator =
      if (phase_changed? or boundary?) and nonempty?(Map.get(existing, :work_output)) and
           delta != "",
         do: "\n",
         else: ""

    output =
      append_bounded(
        Map.get(existing, :work_output),
        separator <> delta,
        @max_subagent_work_bytes
      )

    work = (prefix || "") <> latest_work_line(buffer)

    existing
    |> Map.put(:work_phase, phase)
    |> Map.put(:work_buffer, buffer)
    |> Map.put(:work_boundary?, false)
    |> Map.put(:work_output, output)
    |> Map.put(:work, work)
  end

  defp nonempty?(value), do: is_binary(value) and value != ""

  defp latest_work_line(output) do
    output
    |> to_string()
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> List.last()
    |> case do
      nil -> "Working"
      line -> if String.length(line) > 240, do: "…" <> String.slice(line, -239, 239), else: line
    end
  end

  defp subagent_target(name, arguments) do
    target = ToolView.title(name, arguments, :running)
    target = String.replace_prefix(target, "● #{name}", "") |> String.trim()
    if target == "", do: "", else: " · " <> target
  end

  defp same_subagent_progress?(tool, data) do
    run_id = value(data, :run_id)
    tool_call_id = value(data, :tool_call_id)
    agent_ref = value(data, :agent_ref)

    tool.name == "subagent" and
      ((is_binary(run_id) and value(tool, :run_id) == run_id) or
         (is_binary(tool_call_id) and tool.id == tool_call_id) or
         (not is_nil(agent_ref) and value(tool, :agent_ref) == agent_ref))
  end

  defp append_bounded(current, delta, max_bytes) when is_binary(delta) do
    content = if(is_binary(current), do: current, else: "") <> delta

    if byte_size(content) <= max_bytes do
      content
    else
      take_valid_tail(content, byte_size(content) - max_bytes)
    end
  end

  defp append_bounded(current, _delta, _max_bytes), do: current

  defp take_valid_tail(content, start) do
    tail = binary_part(content, start, byte_size(content) - start)

    cond do
      String.valid?(tail) -> tail
      start < byte_size(content) -> take_valid_tail(content, start + 1)
      true -> ""
    end
  end

  defp put_subagent(subagents, data, tool \\ nil) do
    case value(data, :run_id) do
      run_id when is_binary(run_id) ->
        now = System.monotonic_time(:millisecond)
        existing = Map.get(subagents, run_id, %{run_id: run_id, started_at_ms: now})

        updates = %{
          agent_ref: value(data, :agent_ref),
          tool_call_id: value(data, :tool_call_id),
          profile: value(data, :profile),
          model: value(data, :model),
          arguments: value(data, :arguments) || value(tool, :arguments),
          status: normalize_subagent_status(value(data, :status))
        }

        Map.put(subagents, run_id, merge_tool_activity(existing, updates))

      _other ->
        subagents
    end
  end

  defp normalize_subagent_status(:ok), do: :completed
  defp normalize_subagent_status(status), do: status

  defp maybe_put_value(map, _key, nil), do: map
  defp maybe_put_value(map, key, value), do: Map.put(map, key, value)

  defp same_tool?(tool, id, _name) when is_binary(id), do: tool.id == id
  defp same_tool?(tool, nil, name), do: is_nil(tool.id) and tool.name == name

  defp tool_activity_label(data, status) do
    name = value(data, :name) || value(data, :tool_name) || "tool"

    profile =
      if name == "subagent" do
        args = ToolView.arguments(value(data, :arguments))

        case value(args, :profile) do
          profile when is_binary(profile) -> " · " <> profile
          _ -> ""
        end
      else
        ""
      end

    "#{status} #{name}#{profile}" |> MessageView.sanitize()
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

  defp expire_queue_notice(%State{queue_notice_at: at} = state) when is_integer(at) do
    if System.monotonic_time(:millisecond) - at >= @queue_notice_ms,
      do: %{state | notice: nil, queue_notice_at: nil},
      else: state
  end

  defp expire_queue_notice(state), do: state

  defp pop_queued_prompt([content | rest], content), do: rest
  defp pop_queued_prompt(prompts, _content), do: prompts

  defp busy?(state) do
    not is_nil(state.active_turn) or not is_nil(state.pending_operation) or
      Subagents.active?(state)
  end
end
