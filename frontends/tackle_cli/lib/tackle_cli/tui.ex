defmodule Tackle.CLI.TUI do
  @moduledoc """
  Interactive terminal frontend for a scoped Tackle agent.

  The shell is transcript-first: a compact header, a border-light transcript
  that owns the flexible middle of the screen, a native multiline composer that
  grows with the draft, and optional reading, status, and hint rows. Overlays
  (settings, source copy, output inspector, transcript search, and a searchable
  command/help palette) are modal and always route keys before the composer.

  The TUI owns presentation and input state while the root harness continues to
  own the scope and agent loop. It addresses the root agent through a
  `Tackle.Runtime.AgentRef` and detects crashes through the PID-free monitoring
  operation, so it never retains a runtime PID. Events are correlated by
  session id and active turn id; stale events cannot mutate the current turn.

  While a turn is active the composer keeps accepting a draft, but Enter does
  not submit it: there is no queue, so the draft is explicitly labeled as
  belonging to the next turn. Esc closes overlays, then requests cancellation,
  and never exits while idle; Ctrl+C is the distinct quit action and asks for
  confirmation when a draft or active turn would be lost.
  """

  use ExRatatui.App

  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph, Popup, Textarea, TextInput, WidgetList}
  alias ExRatatui.Widgets.List, as: SelectionList
  alias ExRatatui.Style
  alias Tackle.CLI.Clipboard
  alias Tackle.CLI.TUI.{Conversation, Layout, MessageView, Theme}
  alias Tackle.Lib.{ContextUsage, Event, Message, ModelInfo, State, Usage}
  alias Tackle.Session.Snapshot
  alias Tackle.Thinking

  @commands [
    %{
      id: :settings,
      label: "Model & thinking",
      keys: "F2",
      description: "Change the model and reasoning level when idle"
    },
    %{
      id: :copy,
      label: "Copy source",
      keys: "F3",
      description: "Copy a message, tool output, or the full transcript"
    },
    %{
      id: :inspect,
      label: "Inspect output",
      keys: "F4",
      description: "Open the latest retained tool output"
    },
    %{
      id: :search,
      label: "Search transcript",
      keys: "Ctrl+F",
      description: "Search full retained message and tool text"
    },
    %{
      id: :thinking,
      label: "Toggle reasoning",
      keys: "Ctrl+T",
      description: "Reveal or collapse supplied reasoning"
    },
    %{
      id: :cancel,
      label: "Cancel turn",
      keys: "Esc",
      description: "Request cancellation of the active turn"
    },
    %{
      id: :quit,
      label: "Quit",
      keys: "Ctrl+C",
      description: "Exit Tackle, confirming when a draft or turn would be lost"
    }
  ]

  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts) when is_list(opts) do
    opts = Keyword.put_new(opts, :mouse_capture, true)
    caller = self()
    result_ref = make_ref()

    {_runner, monitor_ref} =
      spawn_monitor(fn -> run_app(caller, result_ref, opts) end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, _runner, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def mount(opts) do
    with {:ok, agent_ref} <- Keyword.fetch(opts, :agent_ref),
         {:ok, %Snapshot{} = snapshot} <- Tackle.subscribe(agent_ref),
         {:ok, agent_monitor} <- Tackle.monitor_agent(agent_ref) do
      models = available_models(opts, snapshot.agent_state)
      {width, height} = initial_terminal_size(opts)

      state = %{
        agent_ref: agent_ref,
        agent_monitor: agent_monitor,
        session_id: snapshot.session_id,
        agent_state: snapshot.agent_state,
        active_turn: snapshot.active_turn,
        input: ExRatatui.textarea_new(),
        models: models,
        clipboard_writer: Keyword.get(opts, :clipboard_writer, &Clipboard.copy_local/1),
        overlay: nil,
        pending_prompt: nil,
        streaming_thinking: "",
        streaming_response: "",
        latest_usage: latest_usage(snapshot.agent_state),
        live_usage: nil,
        live_context_usage: nil,
        tool_activity: [],
        activity: nil,
        error: nil,
        outcome: nil,
        notice: nil,
        thinking_expanded?: false,
        draft_lines: 1,
        draft_empty?: true,
        size: {width, height},
        conversation: new_conversation(width, height)
      }

      {:ok, refresh_conversation(state)}
    else
      :error -> {:error, :missing_agent_ref}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def render(state, frame), do: scene(state, frame)

  @doc false
  @spec scene(map(), ExRatatui.Frame.t()) :: [{struct(), Rect.t()}]
  def scene(state, _frame) do
    {width, height} = state.size
    regions = Layout.regions(width, height, state.draft_lines, reading?(state.conversation))

    [
      {header_widget(state, width), regions.header},
      {transcript_widget(state), regions.transcript}
    ] ++
      reading_widgets(regions.reading, state.conversation) ++
      status_widgets(regions.status, state, width) ++
      [{composer_widget(state), regions.composer}] ++
      hints_widgets(regions.hints, state, width) ++
      overlay_widgets(state, width, height)
  end

  # -- input routing -------------------------------------------------------

  @impl true
  def handle_event(%Key{kind: "release"}, state), do: {:noreply, state, render?: false}

  def handle_event(%Key{} = key, state) do
    dispatch_key(key, %{state | notice: nil})
  end

  def handle_event(%Paste{content: content}, state), do: {:noreply, handle_paste(state, content)}

  def handle_event(%Resize{width: width, height: height}, state) do
    state = %{state | size: {width, height}}
    state = resize_overlay(state)

    regions = Layout.regions(width, height, state.draft_lines, reading?(state.conversation))
    state = %{state | conversation: Conversation.resize(state.conversation, regions.transcript)}

    {:noreply, refresh_conversation(state)}
  end

  def handle_event(%Mouse{kind: kind} = mouse, state) when kind in ["scroll_up", "scroll_down"] do
    delta =
      if kind == "scroll_up",
        do: -Conversation.mouse_scroll_rows(),
        else: Conversation.mouse_scroll_rows()

    case state.overlay do
      {:inspector, _inspector} ->
        {:noreply, scroll_inspector(state, delta)}

      nil ->
        if Conversation.contains?(state.conversation, mouse.x, mouse.y) do
          scroll_reply(state, scroll_conversation(state, delta))
        else
          {:noreply, state, render?: false}
        end

      _overlay ->
        {:noreply, state, render?: false}
    end
  end

  def handle_event(_event, state), do: {:noreply, state, render?: false}

  # -- runtime events ------------------------------------------------------

  @impl true
  def handle_info(
        {:tackle_event, session_id, turn_id,
         %Event{type: :message_delta, data: %{delta: delta} = data}},
        %{session_id: session_id, active_turn: %{id: turn_id}} = state
      )
      when is_binary(delta) do
    case Map.get(data, :field) do
      :reasoning ->
        state = %{
          state
          | streaming_thinking: state.streaming_thinking <> delta,
            activity: "thinking"
        }

        {:noreply, refresh_conversation(state, [:thinking])}

      field when field in [nil, :content] ->
        state = %{
          state
          | streaming_response: state.streaming_response <> delta,
            activity: "responding"
        }

        {:noreply, refresh_conversation(state, [:response])}

      _field ->
        {:noreply, state, render?: false}
    end
  end

  def handle_info(
        {:tackle_event, session_id, turn_id, %Event{type: :usage, data: %{usage: usage} = data}},
        %{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    latest_usage = Usage.normalize(usage) || state.latest_usage

    live_context_usage =
      Map.get(data, :context_usage) ||
        ContextUsage.from_usage(latest_usage, model_info(state.agent_state))

    {:noreply,
     %{
       state
       | latest_usage: latest_usage,
         live_usage: latest_usage,
         live_context_usage: live_context_usage
     }}
  end

  def handle_info(
        {:tackle_event, session_id, turn_id, %Event{type: :tool_start, data: data}},
        %{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    state = put_tool_activity(state, data, :running)
    state = %{state | activity: tool_activity_label(data, "running")}
    {:noreply, refresh_conversation(state, [:tools])}
  end

  def handle_info(
        {:tackle_event, session_id, turn_id, %Event{type: :tool_end, data: data}},
        %{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    state = put_tool_activity(state, data, :completed)
    state = %{state | activity: tool_activity_label(data, "completed")}
    {:noreply, refresh_conversation(state, [:tools])}
  end

  def handle_info(
        {:tackle_event, session_id, turn_id, %Event{type: :tool_error, data: data}},
        %{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    state = put_tool_activity(state, data, :failed)
    state = %{state | activity: tool_activity_label(data, "failed")}
    {:noreply, refresh_conversation(state, [:tools])}
  end

  def handle_info(
        {:tackle_event, session_id, turn_id, %Event{type: type}},
        %{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    {:noreply, %{state | activity: format_activity(type)}}
  end

  def handle_info(
        {:tackle_turn_finished, session_id, turn_id, {outcome, %State{} = agent_state}},
        %{session_id: session_id, active_turn: %{id: turn_id}} = state
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
        latest_usage: latest_usage(agent_state) || state.latest_usage,
        live_usage: nil,
        live_context_usage: nil,
        tool_activity: [],
        activity: nil,
        error: error,
        outcome: if(outcome == :cancelled, do: :cancelled, else: nil)
    }

    {:noreply, refresh_conversation(state)}
  end

  def handle_info(
        {:tackle_turn_failed, session_id, turn_id, reason},
        %{session_id: session_id, active_turn: %{id: turn_id}} = state
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
        error: format_reason(reason),
        outcome: :failed
    }

    {:noreply, refresh_conversation(state, [:pending, :tools, :thinking, :response, :error])}
  end

  def handle_info(
        {:tackle_session_reconfigured, session_id, %Snapshot{} = snapshot},
        %{session_id: session_id} = state
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

    {:noreply, refresh_conversation(state)}
  end

  def handle_info({:tackle_session_closed, session_id}, %{session_id: session_id} = state) do
    {:stop, state}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, _pid, reason},
        %{agent_monitor: monitor_ref}
      ) do
    exit({:agent_down, reason})
  end

  def handle_info(_message, state), do: {:noreply, state, render?: false}

  @impl true
  def terminate(_reason, state) do
    _ = Tackle.unsubscribe(state.agent_ref)
    :ok
  end

  # -- key dispatch --------------------------------------------------------

  defp dispatch_key(%Key{kind: "repeat"} = key, state) do
    if repeatable?(key), do: dispatch(key, state), else: {:noreply, state, render?: false}
  end

  defp dispatch_key(key, state), do: dispatch(key, state)

  defp repeatable?(%Key{code: code, modifiers: modifiers}) do
    cond do
      code in ["esc", "enter", "f1", "f2", "f3", "f4"] -> false
      "ctrl" in modifiers and code in ["c", "f", "t", "j", "home", "end"] -> false
      true -> true
    end
  end

  defp dispatch(%Key{code: "c", modifiers: modifiers} = key, state) do
    if "ctrl" in modifiers, do: quit(state), else: dispatch_overlay(key, state)
  end

  defp dispatch(key, state), do: dispatch_overlay(key, state)

  defp dispatch_overlay(key, %{overlay: nil} = state), do: dispatch_base(key, state)

  defp dispatch_overlay(key, %{overlay: {:confirm_quit, _}} = state),
    do: dispatch_confirm_quit(key, state)

  defp dispatch_overlay(key, %{overlay: {:settings, _}} = state),
    do: dispatch_settings(key, state)

  defp dispatch_overlay(key, %{overlay: {:copy, _}} = state), do: dispatch_copy(key, state)

  defp dispatch_overlay(key, %{overlay: {:inspector, _}} = state),
    do: dispatch_inspector(key, state)

  defp dispatch_overlay(key, %{overlay: {:search, _}} = state), do: dispatch_search(key, state)
  defp dispatch_overlay(key, %{overlay: {:palette, _}} = state), do: dispatch_palette(key, state)

  defp dispatch_base(%Key{code: "esc"}, state), do: escape(state)
  defp dispatch_base(%Key{code: "f1"}, state), do: open_palette(state)
  defp dispatch_base(%Key{code: "f2"}, state), do: open_settings(state)
  defp dispatch_base(%Key{code: "f3"}, state), do: open_copy(state)
  defp dispatch_base(%Key{code: "f4"}, state), do: open_inspector(state)

  defp dispatch_base(%Key{code: code, modifiers: modifiers} = key, state) do
    cond do
      "ctrl" in modifiers and code == "f" ->
        open_search(state)

      "ctrl" in modifiers and code == "t" ->
        toggle_thinking(state)

      "ctrl" in modifiers and code == "home" ->
        scroll_reply(state, scroll_conversation_to(state, :start))

      "ctrl" in modifiers and code == "end" ->
        scroll_reply(state, scroll_conversation_to(state, :end))

      code == "page_up" and modifiers == [] ->
        scroll_reply(state, scroll_conversation(state, -page_size(state)))

      code == "page_down" and modifiers == [] ->
        scroll_reply(state, scroll_conversation(state, page_size(state)))

      code == "enter" and modifiers == [] ->
        submit_prompt(state)

      code == "enter" ->
        insert_newline(state)

      "ctrl" in modifiers and code == "j" ->
        insert_newline(state)

      true ->
        composer_key(key, state)
    end
  end

  defp dispatch_confirm_quit(%Key{code: code}, state) when code in ["y", "Y", "enter"],
    do: {:stop, state}

  defp dispatch_confirm_quit(%Key{code: code}, state) when code in ["n", "N", "esc"],
    do: {:noreply, %{state | overlay: nil}}

  defp dispatch_confirm_quit(_key, state), do: {:noreply, state, render?: false}

  defp dispatch_settings(%Key{code: "esc"}, state), do: {:noreply, %{state | overlay: nil}}

  defp dispatch_settings(%Key{code: code}, state) when code in ["up", "down"] do
    {:settings, settings} = state.overlay
    field = if settings.field == :model, do: :thinking, else: :model
    {:noreply, %{state | overlay: {:settings, %{settings | field: field}}}}
  end

  defp dispatch_settings(%Key{code: code}, state) when code in ["left", "right"],
    do: {:noreply, cycle_setting(state, code)}

  defp dispatch_settings(%Key{code: "enter"}, state), do: apply_settings(state)
  defp dispatch_settings(_key, state), do: {:noreply, state, render?: false}

  defp dispatch_copy(%Key{code: "esc"}, state), do: {:noreply, %{state | overlay: nil}}

  defp dispatch_copy(%Key{code: code}, state) when code in ["up", "down"],
    do: {:noreply, move_copy_selection(state, code)}

  defp dispatch_copy(%Key{code: code}, state) when code in ["enter", "y", "Y"],
    do: copy_selected_entry(state)

  defp dispatch_copy(%Key{code: code}, state) when code in ["o", "O"],
    do: inspect_selected_entry(state)

  defp dispatch_copy(%Key{code: code}, state) when code in ["a", "A"], do: copy_all_entries(state)
  defp dispatch_copy(_key, state), do: {:noreply, state, render?: false}

  defp dispatch_inspector(%Key{code: "esc"}, state), do: {:noreply, %{state | overlay: nil}}

  defp dispatch_inspector(%Key{code: code}, state)
       when code in ["up", "down", "page_up", "page_down", "home", "end"],
       do: {:noreply, scroll_inspector(state, code)}

  defp dispatch_inspector(%Key{code: code}, state) when code in ["y", "Y"],
    do: copy_inspector(state)

  defp dispatch_inspector(%Key{code: code}, state) when code in ["left", "right"],
    do: {:noreply, adjacent_tool(state, code)}

  defp dispatch_inspector(%Key{code: code}, %{overlay: {:inspector, inspector}} = state)
       when code in ["a", "A"] do
    args = Tackle.CLI.TUI.ToolView.arguments(inspector.entry.tool_arguments)
    notice = clipboard_notice(state, JSON.encode!(args), "Copied tool arguments")
    {:noreply, %{state | overlay: {:inspector, %{inspector | notice: notice}}}}
  end

  defp dispatch_inspector(_key, state), do: {:noreply, state, render?: false}

  defp dispatch_search(%Key{code: "esc"}, state), do: {:noreply, %{state | overlay: nil}}

  defp dispatch_search(%Key{code: code}, state) when code in ["enter", "down"],
    do: {:noreply, next_search_match(state, 1)}

  defp dispatch_search(%Key{code: "up"}, state), do: {:noreply, next_search_match(state, -1)}

  defp dispatch_search(%Key{code: code}, state) when is_binary(code) do
    {:search, search} = state.overlay
    :ok = ExRatatui.text_input_handle_key(search.input, code)
    {:noreply, refresh_search(state)}
  end

  defp dispatch_search(_key, state), do: {:noreply, state, render?: false}

  defp dispatch_palette(%Key{code: "esc"}, state), do: {:noreply, %{state | overlay: nil}}

  defp dispatch_palette(%Key{code: code}, state) when code in ["up", "down"],
    do: {:noreply, move_palette_selection(state, code)}

  defp dispatch_palette(%Key{code: "enter"}, state), do: run_selected_command(state)

  defp dispatch_palette(%Key{code: "backspace"}, state),
    do: {:noreply, filter_palette(state, :backspace)}

  defp dispatch_palette(%Key{code: code, modifiers: modifiers}, state)
       when is_binary(code) and modifiers == [] do
    if String.length(code) == 1,
      do: {:noreply, filter_palette(state, {:insert, code})},
      else: {:noreply, state, render?: false}
  end

  defp dispatch_palette(_key, state), do: {:noreply, state, render?: false}

  # -- paste ---------------------------------------------------------------

  defp handle_paste(%{overlay: {:search, search}} = state, content) do
    :ok = ExRatatui.text_input_insert_str(search.input, content)
    refresh_search(state)
  end

  defp handle_paste(%{overlay: {:palette, palette}} = state, content) do
    query = palette.query <> String.replace(content, ~r/\s+/u, " ")
    refresh_palette(%{state | overlay: {:palette, %{palette | query: query, selected: 0}}})
  end

  defp handle_paste(%{overlay: nil} = state, content) do
    # Normalize line endings before the single native edit so pasted drafts
    # contain no stray carriage returns regardless of the crate's behavior.
    content = content |> String.replace("\r\n", "\n") |> String.replace("\r", "")
    :ok = ExRatatui.textarea_insert_str(state.input, content)
    state |> update_draft() |> relayout()
  end

  defp handle_paste(state, _content), do: state

  # -- base actions --------------------------------------------------------

  defp escape(%{active_turn: nil} = state) do
    {:noreply, %{state | notice: "Idle · Esc does not quit · Ctrl+C quits"}}
  end

  defp escape(state) do
    if state.activity == "cancelling" do
      {:noreply, %{state | notice: "Cancellation already requested"}}
    else
      case Tackle.cancel(state.agent_ref) do
        :ok -> {:noreply, %{state | activity: "cancelling"}}
        {:error, reason} -> {:noreply, %{state | error: format_reason(reason)}}
      end
    end
  end

  defp quit(%{active_turn: nil} = state) do
    if state.draft_empty? do
      {:stop, state}
    else
      {:noreply, %{state | overlay: {:confirm_quit, %{reason: :draft}}}}
    end
  end

  defp quit(state) do
    {:noreply, %{state | overlay: {:confirm_quit, %{reason: :turn}}}}
  end

  defp open_settings(state) do
    if state.active_turn do
      {:noreply, %{state | notice: "Model settings are available when idle"}}
    else
      model_index = Enum.find_index(state.models, &(&1 == model_ref(state.agent_state))) || 0
      thinking = Thinking.from_llm_opts(state.agent_state.llm_opts)
      thinking_index = Enum.find_index(Thinking.levels(), &(&1 == thinking)) || 0

      {:noreply,
       %{
         state
         | overlay:
             {:settings,
              %{field: :model, model_index: model_index, thinking_index: thinking_index}}
       }}
    end
  end

  defp open_copy(state) do
    selected =
      case Conversation.entries(state.conversation) do
        [] -> nil
        entries -> length(entries) - 1
      end

    {:noreply, %{state | overlay: {:copy, %{selected: selected, notice: nil}}}}
  end

  defp open_inspector(state) do
    case latest_output_entry(state.conversation) do
      nil ->
        {:noreply, %{state | notice: "No retained tool output yet · F3 browses source"}}

      entry ->
        {:noreply, %{state | overlay: {:inspector, build_inspector(state, entry)}}}
    end
  end

  defp open_search(state) do
    state = %{
      state
      | overlay: {:search, %{input: ExRatatui.text_input_new(), query: "", matches: [], index: 0}}
    }

    {:noreply, refresh_search(state)}
  end

  defp open_palette(state) do
    {:noreply, %{state | overlay: {:palette, %{query: "", selected: 0}}}}
  end

  defp toggle_thinking(state) do
    state = %{state | thinking_expanded?: not state.thinking_expanded?}
    {:noreply, refresh_conversation(state, [:settled, :thinking])}
  end

  defp insert_newline(state) do
    :ok = ExRatatui.textarea_insert_str(state.input, "\n")
    {:noreply, state |> update_draft() |> relayout()}
  end

  defp composer_key(%Key{code: code, modifiers: modifiers}, state) when is_binary(code) do
    :ok = ExRatatui.textarea_handle_key(state.input, code, modifiers)
    {:noreply, state |> update_draft() |> relayout()}
  end

  defp composer_key(_key, state), do: {:noreply, state, render?: false}

  defp submit_prompt(state) do
    cond do
      state.active_turn ->
        {:noreply, %{state | notice: "Busy · draft kept for the next turn (not queued)"}}

      state.draft_empty? ->
        {:noreply, state, render?: false}

      true ->
        prompt = state.input |> ExRatatui.textarea_get_value() |> String.trim()

        case Tackle.submit(state.agent_ref, prompt) do
          {:ok, turn_id} ->
            :ok = ExRatatui.textarea_set_value(state.input, "")

            state = %{
              state
              | active_turn: %{id: turn_id},
                pending_prompt: prompt,
                streaming_thinking: "",
                streaming_response: "",
                live_usage: nil,
                live_context_usage: nil,
                tool_activity: [],
                activity: "starting",
                error: nil,
                outcome: nil,
                notice: nil,
                draft_lines: 1,
                draft_empty?: true
            }

            state = scroll_conversation_to(state, :end)

            {:noreply,
             refresh_conversation(state, [:pending, :tools, :thinking, :response, :error])}

          {:error, reason} ->
            # The exact draft stays in the composer so the user can retry or edit.
            {:noreply, refresh_conversation(%{state | error: format_reason(reason)}, [:error])}
        end
    end
  end

  # -- overlay actions -----------------------------------------------------

  defp move_copy_selection(state, direction) do
    count = length(Conversation.entries(state.conversation))

    if count == 0 do
      state
    else
      {:copy, copy} = state.overlay
      delta = if direction == "up", do: -1, else: 1
      selected = clamp((copy_selection(copy, count) || 0) + delta, 0, count - 1)
      %{state | overlay: {:copy, %{copy | selected: selected, notice: nil}}}
    end
  end

  defp copy_selected_entry(%{overlay: {:copy, copy}} = state) do
    entries = Conversation.entries(state.conversation)

    case selected_entry(entries, copy) do
      nil ->
        {:noreply, put_copy_notice(state, "Nothing to copy")}

      entry ->
        notice = clipboard_notice(state, MessageView.source_text(entry), "Copied full source")
        {:noreply, put_copy_notice(state, notice)}
    end
  end

  defp inspect_selected_entry(%{overlay: {:copy, copy}} = state) do
    entries = Conversation.entries(state.conversation)

    case selected_entry(entries, copy) do
      nil ->
        {:noreply, put_copy_notice(state, "Nothing to inspect")}

      entry ->
        {:noreply, %{state | overlay: {:inspector, build_inspector(state, entry)}}}
    end
  end

  defp selected_entry(entries, copy) do
    case copy_selection(copy, length(entries)) do
      index when is_integer(index) -> Enum.at(entries, index)
      _none -> nil
    end
  end

  defp copy_all_entries(%{overlay: {:copy, _copy}} = state) do
    case Conversation.text(state.conversation) do
      "" ->
        {:noreply, put_copy_notice(state, "Nothing to copy")}

      text ->
        {:noreply,
         put_copy_notice(state, clipboard_notice(state, text, "Copied full transcript"))}
    end
  end

  defp put_copy_notice(%{overlay: {:copy, copy}} = state, notice) do
    %{state | overlay: {:copy, %{copy | notice: notice}}}
  end

  defp copy_selection(_copy, 0), do: nil

  defp copy_selection(%{selected: selected}, count) when is_integer(selected),
    do: clamp(selected, 0, count - 1)

  defp copy_selection(_copy, count), do: count - 1

  defp scroll_inspector(%{overlay: {:inspector, inspector}} = state, code) do
    max_offset = max(inspector.content_height - inspector.viewport_height, 0)
    page = max(inspector.viewport_height - 1, 1)

    delta =
      case code do
        "up" -> -1
        "down" -> 1
        "page_up" -> -page
        "page_down" -> page
        "home" -> -max_offset
        "end" -> max_offset
        rows when is_integer(rows) -> rows
      end

    offset = inspector.scroll_offset |> Kernel.+(delta) |> max(0) |> min(max_offset)
    %{state | overlay: {:inspector, %{inspector | scroll_offset: offset, notice: nil}}}
  end

  defp adjacent_tool(%{overlay: {:inspector, inspector}} = state, direction) do
    tools = Conversation.entries(state.conversation) |> Enum.filter(&(&1.kind == :tool))
    index = Enum.find_index(tools, &(&1.id == inspector.entry.id)) || 0
    delta = if direction == "left", do: -1, else: 1

    case Enum.at(tools, clamp(index + delta, 0, max(length(tools) - 1, 0))) do
      nil -> state
      entry -> %{state | overlay: {:inspector, build_inspector(state, entry)}}
    end
  end

  defp copy_inspector(%{overlay: {:inspector, inspector}} = state) do
    notice = clipboard_notice(state, MessageView.full_text(inspector.entry), "Copied full output")
    {:noreply, %{state | overlay: {:inspector, %{inspector | notice: notice}}}}
  end

  defp refresh_search(%{overlay: {:search, search}} = state) do
    query = ExRatatui.text_input_get_value(search.input)
    matches = Conversation.search(state.conversation, query)

    index =
      if query == search.query,
        do: clamp(search.index, 0, max(length(matches) - 1, 0)),
        else: 0

    search = %{search | query: query, matches: matches, index: index}
    state = %{state | overlay: {:search, search}}

    case Enum.at(matches, index) do
      nil -> state
      match -> %{state | conversation: Conversation.scroll_to_entry(state.conversation, match.id)}
    end
  end

  defp next_search_match(%{overlay: {:search, search}} = state, delta) do
    count = length(search.matches)

    if count == 0 do
      state
    else
      index = Integer.mod(search.index + delta, count)
      search = %{search | index: index}
      state = %{state | overlay: {:search, search}}
      match = Enum.at(search.matches, index)
      %{state | conversation: Conversation.scroll_to_entry(state.conversation, match.id)}
    end
  end

  defp filter_palette(%{overlay: {:palette, palette}} = state, :backspace) do
    query = palette.query |> String.graphemes() |> Enum.drop(-1) |> Enum.join()
    %{state | overlay: {:palette, %{palette | query: query, selected: 0}}}
  end

  defp filter_palette(%{overlay: {:palette, palette}} = state, {:insert, text}) do
    %{state | overlay: {:palette, %{palette | query: palette.query <> text, selected: 0}}}
  end

  defp refresh_palette(%{overlay: {:palette, palette}} = state) do
    commands = filtered_commands(state, palette.query)
    selected = clamp(palette.selected, 0, max(length(commands) - 1, 0))
    %{state | overlay: {:palette, %{palette | selected: selected}}}
  end

  defp move_palette_selection(state, direction) do
    {:palette, palette} = state.overlay
    commands = filtered_commands(state, palette.query)
    delta = if direction == "up", do: -1, else: 1
    selected = clamp(palette.selected + delta, 0, max(length(commands) - 1, 0))
    %{state | overlay: {:palette, %{palette | selected: selected}}}
  end

  defp run_selected_command(state) do
    {:palette, palette} = state.overlay
    commands = filtered_commands(state, palette.query)
    command = Enum.at(commands, clamp(palette.selected, 0, max(length(commands) - 1, 0)))

    if command do
      run_command(%{state | overlay: nil}, command.id)
    else
      {:noreply, state, render?: false}
    end
  end

  defp run_command(state, :settings), do: open_settings(state)
  defp run_command(state, :copy), do: open_copy(state)
  defp run_command(state, :inspect), do: open_inspector(state)
  defp run_command(state, :search), do: open_search(state)
  defp run_command(state, :thinking), do: toggle_thinking(state)
  defp run_command(state, :cancel), do: escape(state)
  defp run_command(state, :quit), do: quit(state)

  defp filtered_commands(state, query) do
    needle = query |> String.trim() |> String.downcase()

    Enum.filter(@commands, fn command ->
      command_available?(command.id, state) and
        (needle == "" or
           String.contains?(
             String.downcase(command.label <> " " <> command.description),
             needle
           ))
    end)
  end

  defp command_available?(:settings, state), do: state.active_turn == nil
  defp command_available?(:cancel, state), do: state.active_turn != nil
  defp command_available?(_id, _state), do: true

  defp cycle_setting(state, direction) do
    {:settings, settings} = state.overlay
    delta = if direction == "left", do: -1, else: 1

    settings =
      case settings.field do
        :model ->
          %{
            settings
            | model_index: cycle_index(settings.model_index, delta, length(state.models))
          }

        :thinking ->
          %{
            settings
            | thinking_index:
                cycle_index(settings.thinking_index, delta, length(Thinking.levels()))
          }
      end

    %{state | overlay: {:settings, settings}}
  end

  defp cycle_index(index, delta, count), do: Integer.mod(index + delta, max(count, 1))

  defp apply_settings(state) do
    {:settings, settings} = state.overlay
    model = Enum.at(state.models, settings.model_index)
    thinking = Enum.at(Thinking.levels(), settings.thinking_index)

    case Tackle.reconfigure(state.agent_ref, model: model, thinking: thinking) do
      {:ok, %Snapshot{} = snapshot} ->
        state = %{
          state
          | agent_state: snapshot.agent_state,
            active_turn: snapshot.active_turn,
            overlay: nil,
            error: nil,
            outcome: nil
        }

        {:noreply, refresh_conversation(state)}

      {:error, reason} ->
        # Reconfiguration failure preserves the conversation and the draft.
        state = %{state | overlay: nil, error: format_reason(reason)}
        {:noreply, refresh_conversation(state, [:error])}
    end
  end

  # -- conversation state --------------------------------------------------

  defp new_conversation(width, height) do
    regions = Layout.regions(width, height, 1, false)
    Conversation.new(regions.transcript)
  end

  defp refresh_conversation(state, sections \\ nil)

  defp refresh_conversation(state, nil) do
    state
    |> Map.put(:conversation, Conversation.refresh(state.conversation, state))
    |> relayout()
  end

  defp refresh_conversation(state, sections) do
    state
    |> Map.put(:conversation, Conversation.refresh(state.conversation, state, sections))
    |> relayout()
  end

  defp relayout(state) do
    {width, height} = state.size
    regions = Layout.regions(width, height, state.draft_lines, reading?(state.conversation))

    conversation =
      if regions.transcript == state.conversation.rect do
        state.conversation
      else
        Conversation.resize(state.conversation, regions.transcript)
      end

    %{state | conversation: conversation}
  end

  defp reading?(conversation), do: conversation.new_output? or not conversation.follow?

  defp update_draft(state) do
    value = ExRatatui.textarea_get_value(state.input)

    %{
      state
      | draft_lines: max(length(String.split(value, "\n")), 1),
        draft_empty?: String.trim(value) == ""
    }
  end

  defp resize_overlay(%{overlay: {:inspector, inspector}} = state) do
    {width, height} = state.size
    content_width = max(div(width * 90, 100) - 2, 1)
    items = MessageView.inspect_items(inspector.entry, content_width)

    content_height =
      Enum.reduce(items, 0, fn {_widget, item_height}, total -> total + item_height end)

    viewport_height = max(div(height * 80, 100) - 2, 1)
    max_offset = max(content_height - viewport_height, 0)

    overlay =
      {:inspector,
       %{
         inspector
         | items: items,
           content_height: content_height,
           viewport_height: viewport_height,
           scroll_offset: min(inspector.scroll_offset, max_offset)
       }}

    %{state | overlay: overlay}
  end

  defp resize_overlay(%{overlay: {:search, _search}} = state), do: refresh_search(state)
  defp resize_overlay(state), do: state

  defp scroll_conversation(state, delta) do
    %{state | conversation: Conversation.scroll(state.conversation, delta)}
    |> relayout()
  end

  defp scroll_conversation_to(state, location) do
    %{state | conversation: Conversation.scroll_to(state.conversation, location)}
    |> relayout()
  end

  defp page_size(state), do: Conversation.page_size(state.conversation)

  defp scroll_reply(state, scrolled_state) do
    if scrolled_state.conversation.scroll_offset == state.conversation.scroll_offset and
         scrolled_state.conversation.follow? == state.conversation.follow? do
      {:noreply, state, render?: false}
    else
      {:noreply, scrolled_state}
    end
  end

  defp latest_output_entry(conversation) do
    conversation
    |> Conversation.entries()
    |> Enum.reverse()
    |> Enum.find(&(&1.kind == :tool))
  end

  defp build_inspector(state, entry) do
    {width, height} = state.size
    content_width = max(div(width * 90, 100) - 2, 1)
    items = MessageView.inspect_items(entry, content_width)

    content_height =
      Enum.reduce(items, 0, fn {_widget, item_height}, total -> total + item_height end)

    %{
      entry: entry,
      name: MessageView.sanitize(entry.tool_name || entry.label || "entry"),
      items: items,
      content_height: content_height,
      viewport_height: max(div(height * 80, 100) - 2, 1),
      scroll_offset: 0,
      notice: nil
    }
  end

  # -- widgets -------------------------------------------------------------

  defp header_widget(state, width) do
    %Paragraph{text: [MessageView.row(header_spans(state, width), %Style{})], style: %Style{}}
  end

  defp header_spans(state, width) do
    model = model_ref(state.agent_state) || "configured default"
    thinking = Thinking.from_llm_opts(state.agent_state.llm_opts)
    separator = MessageView.span("  ·  ", Theme.style(:subtle))

    base = [MessageView.span(" Tackle", Theme.style(:accent))]
    model_part = [separator, MessageView.span(model, Theme.style(:muted))]
    thinking_part = [separator, MessageView.span("thinking #{thinking}", Theme.style(:muted))]
    status_part = [separator, MessageView.span(status_label(state), status_style(state))]

    variants = [
      base ++ model_part ++ thinking_part ++ status_part,
      base ++ thinking_part ++ status_part,
      base ++ status_part
    ]

    Enum.find(variants, List.last(variants), &(spans_width(&1) <= max(width, 1)))
  end

  defp spans_width(spans) do
    Enum.reduce(spans, 0, fn span, total -> total + MessageView.display_width(span.content) end)
  end

  defp transcript_widget(state) do
    %WidgetList{
      items: state.conversation.visible_items,
      scroll_offset: state.conversation.visible_offset
    }
  end

  defp reading_widgets(nil, _conversation), do: []

  defp reading_widgets(rect, conversation) do
    case Conversation.affordance(conversation) do
      nil ->
        [{%Paragraph{text: ""}, rect}]

      text ->
        [
          {
            %Paragraph{
              text: [
                MessageView.row(
                  [MessageView.span(" " <> text, Theme.style(:accent))],
                  %Style{}
                )
              ]
            },
            rect
          }
        ]
    end
  end

  defp status_widgets(nil, _state, _width), do: []

  defp status_widgets(rect, state, width) do
    [
      {%Paragraph{text: [MessageView.row(status_spans(state, width), %Style{})]}, rect}
    ]
  end

  defp status_spans(state, width) do
    case fit_segments(status_segments(state), width - 1) do
      [] ->
        [MessageView.span(" ", %Style{})]

      [first | rest] ->
        [MessageView.span(" " <> first, status_style(state))] ++
          Enum.map(rest, fn segment ->
            MessageView.span("  ·  " <> segment, Theme.style(:muted))
          end)
    end
  end

  defp hints_widgets(nil, _state, _width), do: []

  defp hints_widgets(rect, state, width) do
    [
      {
        %Paragraph{
          text: " " <> fit_hints(hint_segments(state), width - 1),
          style: Theme.style(:subtle)
        },
        rect
      }
    ]
  end

  defp composer_widget(state) do
    %Textarea{
      state: state.input,
      placeholder: composer_placeholder(state),
      placeholder_style: Theme.style(:subtle),
      cursor_line_style: %Style{bg: {:indexed, 235}},
      block: %Block{
        title: composer_title(state),
        title_style: %Style{fg: composer_color(state)},
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: composer_color(state)}
      }
    }
  end

  defp composer_title(%{active_turn: nil}), do: " Prompt "
  defp composer_title(_state), do: " Draft · next turn (not queued) "

  defp composer_placeholder(%{active_turn: nil}),
    do: "Ask Tackle… Enter sends · Shift+Enter or Ctrl+J newline · F1 help"

  defp composer_placeholder(_state), do: "Draft the next instruction — kept, not queued"

  defp composer_color(%{active_turn: nil}), do: :green
  defp composer_color(_state), do: :dark_gray

  defp overlay_widgets(%{overlay: nil}, _width, _height), do: []

  defp overlay_widgets(state, width, height) do
    [{overlay_widget(state), %Rect{x: 0, y: 0, width: width, height: height}}]
  end

  defp overlay_widget(%{overlay: {:settings, settings}} = state) do
    model = Enum.at(state.models, settings.model_index) || "configured default"
    thinking = Enum.at(Thinking.levels(), settings.thinking_index)
    selected = if settings.field == :model, do: 0, else: 1

    %Popup{
      content: %SelectionList{
        items: ["Model      ‹ #{model} ›", "Thinking   ‹ #{thinking} ›"],
        selected: selected,
        highlight_symbol: "› ",
        highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
        style: %Style{fg: :white}
      },
      block: panel_block(" Settings · ↑/↓ field · ←/→ select · Enter apply · Esc cancel ", :cyan),
      percent_width: 80,
      percent_height: 30
    }
  end

  defp overlay_widget(%{overlay: {:copy, copy}} = state) do
    entries = Conversation.entries(state.conversation)

    content =
      case entries do
        [] ->
          %Paragraph{
            text: " There is no conversation source to copy.",
            style: %Style{fg: :dark_gray}
          }

        entries ->
          %SelectionList{
            items: Enum.map(entries, &copy_preview/1),
            selected: copy_selection(copy, length(entries)),
            highlight_symbol: "› ",
            highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
            style: %Style{fg: :white},
            scroll_padding: 2
          }
      end

    title =
      case copy.notice do
        nil ->
          " Copy source · ↑/↓ select · Y/Enter copy full source · O inspect · A copy all · Esc close "

        notice ->
          " #{notice} · Esc close "
      end

    %Popup{
      content: content,
      block: panel_block(title, :cyan),
      percent_width: 85,
      percent_height: 60
    }
  end

  defp overlay_widget(%{overlay: {:inspector, inspector}}) do
    {visible_items, visible_offset} =
      Conversation.slice(inspector.items, inspector.scroll_offset, inspector.viewport_height)

    title =
      case inspector.notice do
        nil ->
          " #{inspector.name} · #{inspector_position(inspector)} · ←/→ tool · Y output · A args · Esc "

        notice ->
          " #{notice} · Esc close "
      end

    %Popup{
      content: %WidgetList{items: visible_items, scroll_offset: visible_offset},
      block: panel_block(title, :cyan),
      percent_width: 90,
      percent_height: 80
    }
  end

  defp overlay_widget(%{overlay: {:search, search}}) do
    title =
      case search.matches do
        [] when search.query == "" ->
          " Search · type to search · Esc close "

        [] ->
          " Search · no matches · Esc close "

        matches ->
          " Search · #{search.index + 1}/#{length(matches)} · Enter next · ↑ previous · Esc close "
      end

    %Popup{
      content: %TextInput{
        state: search.input,
        placeholder: "Search retained transcript and tool output",
        placeholder_style: %Style{fg: :dark_gray}
      },
      block: panel_block(title, :cyan),
      percent_width: 80,
      percent_height: 20
    }
  end

  defp overlay_widget(%{overlay: {:palette, palette}} = state) do
    commands = filtered_commands(state, palette.query)
    selected = clamp(palette.selected, 0, max(length(commands) - 1, 0))

    content =
      case commands do
        [] ->
          %Paragraph{text: " No commands match.", style: %Style{fg: :dark_gray}}

        commands ->
          %SelectionList{
            items: Enum.map(commands, fn command -> "#{command.label}  ·  #{command.keys}" end),
            selected: selected,
            highlight_symbol: "› ",
            highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
            style: %Style{fg: :white},
            scroll_padding: 2
          }
      end

    %Popup{
      content: content,
      block: panel_block(palette_title(palette.query, length(commands)), :cyan),
      percent_width: 72,
      percent_height: 55
    }
  end

  defp overlay_widget(%{overlay: {:confirm_quit, confirm}}) do
    text =
      case confirm.reason do
        :draft -> " Quit Tackle?\n\n Your unsent draft will be lost."
        :turn -> " Quit Tackle?\n\n An active turn will be stopped."
      end

    %Popup{
      content: %Paragraph{text: text, style: %Style{fg: :white}},
      block: panel_block(" Confirm quit · Y/Enter quit · N/Esc cancel ", :yellow),
      percent_width: 50,
      percent_height: 25
    }
  end

  defp palette_title("", count),
    do: " Help · #{count} commands · type to filter · Enter run · Esc close "

  defp palette_title(query, count),
    do: " Help · filter “#{truncate(query, 24)}” · #{count} matches · Enter run · Esc close "

  defp inspector_position(
         %{content_height: content_height, viewport_height: viewport_height} = inspector
       ) do
    max_offset = max(content_height - viewport_height, 0)

    if max_offset == 0 do
      "all"
    else
      "#{round(inspector.scroll_offset / max_offset * 100)}%"
    end
  end

  defp copy_preview(entry) do
    text =
      if entry.kind == :tool, do: MessageView.text(entry), else: MessageView.source_text(entry)

    preview =
      text
      |> MessageView.sanitize()
      |> String.split()
      |> Enum.join(" ")

    if String.length(preview) > 72, do: String.slice(preview, 0, 71) <> "…", else: preview
  end

  defp panel_block(title, color) do
    %Block{
      title: title,
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: color}
    }
  end

  # -- status and hints ----------------------------------------------------

  defp status_segments(%{overlay: {:search, search}}) do
    case search.matches do
      [] ->
        ["Search", if(search.query == "", do: "type to search", else: "no matches")]

      matches ->
        [
          "Match #{search.index + 1}/#{length(matches)}",
          current_search_preview(matches, search.index)
        ]
    end
  end

  defp status_segments(%{overlay: {:palette, palette}} = state) do
    case filtered_commands(state, palette.query) do
      [] -> ["Help", "no commands match"]
      commands -> ["Help", command_at(commands, palette.selected).description]
    end
  end

  defp status_segments(state) do
    [status_label(state)] ++ busy_segments(state) ++ metric_segments(state)
  end

  defp current_search_preview(matches, index) do
    case Enum.at(matches, index) do
      nil -> ""
      match -> match.preview
    end
  end

  defp command_at(commands, selected) do
    Enum.at(commands, clamp(selected, 0, max(length(commands) - 1, 0)))
  end

  defp busy_segments(%{active_turn: nil}), do: []
  defp busy_segments(%{draft_empty?: true}), do: []
  defp busy_segments(_state), do: ["draft kept · not queued"]

  defp status_label(%{active_turn: nil, error: error}) when is_binary(error), do: "failed"
  defp status_label(%{active_turn: nil, outcome: :cancelled}), do: "cancelled"
  defp status_label(%{active_turn: nil}), do: "ready"
  defp status_label(%{activity: nil}), do: "working"
  defp status_label(%{activity: activity}), do: activity

  defp status_style(state) do
    cond do
      is_binary(state.error) -> Theme.style(:error)
      state.active_turn -> Theme.style(:accent_soft)
      state.outcome == :cancelled -> Theme.style(:warning)
      true -> Theme.style(:muted)
    end
  end

  defp hint_segments(%{active_turn: nil}) do
    [
      "Enter send",
      "F1 help",
      "F2 model",
      "F3 source",
      "F4 output",
      "Ctrl+F search",
      "Shift+Enter newline",
      "Ctrl+T reasoning",
      "Ctrl+C quit"
    ]
  end

  defp hint_segments(_state) do
    [
      "Esc cancel",
      "F1 help",
      "F3 source",
      "F4 output",
      "Ctrl+F search",
      "draft kept · not queued",
      "Ctrl+C quit"
    ]
  end

  # Keeps the first and last hint (the essential send/quit pair) visible and
  # adds middle hints while they fit, so narrow terminals never hide the quit
  # action behind optional discoverability text.
  defp fit_hints([first | rest], width) do
    {middle, tail} = Enum.split(rest, max(length(rest) - 1, 0))
    last = List.first(tail)

    middle
    |> Enum.reduce([first | List.wrap(last)], fn segment, acc ->
      candidate = List.insert_at(acc, -2, segment)

      if String.length(Enum.join(candidate, " · ")) <= max(width, 1) do
        candidate
      else
        acc
      end
    end)
    |> Enum.join(" · ")
    |> truncate(max(width, 1))
  end

  # Fits the leading status word plus as many metric segments as the width
  # allows. The first segment is always kept so the working state survives a
  # narrow terminal.
  defp fit_segments([first | rest], width) do
    width = max(width, 1)

    rest
    |> Enum.reduce({[first], MessageView.display_width(first) + 1}, fn segment, {kept, used} ->
      candidate = used + 4 + MessageView.display_width(segment)

      if candidate <= width do
        {kept ++ [segment], candidate}
      else
        {kept, used}
      end
    end)
    |> elem(0)
  end

  defp truncate(text, width) do
    if String.length(text) <= width,
      do: text,
      else: String.slice(text, 0, max(width - 1, 0)) <> "…"
  end

  # -- metrics -------------------------------------------------------------

  defp metric_segments(state) do
    usage = displayed_usage(state)

    [
      context_indicator(displayed_context_usage(state)),
      token_indicator("in", usage.input_tokens),
      token_indicator("out", usage.output_tokens),
      cache_hit_indicator(usage),
      cost_indicator(usage)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp displayed_usage(state) do
    settled = State.usage(state.agent_state)

    [settled, state.live_usage]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(not usage_activity?(&1)))
    |> Usage.aggregate()
  end

  defp displayed_context_usage(%{live_context_usage: %ContextUsage{} = context}), do: context
  defp displayed_context_usage(state), do: Tackle.Lib.context_usage(state.agent_state)

  defp context_indicator(%ContextUsage{} = context) do
    percentage = :erlang.float_to_binary(context.percent, decimals: 1)

    "ctx #{format_token_count(context.tokens)}/#{format_token_count(context.context_window)} " <>
      "(#{percentage}%)"
  end

  defp context_indicator(nil), do: nil

  defp token_indicator(_label, nil), do: nil
  defp token_indicator(label, tokens), do: "#{label} #{format_token_count(tokens)}"

  defp cache_hit_indicator(%Usage{} = usage) do
    with rate when is_float(rate) <- Usage.cache_hit_rate(usage),
         true <- cache_activity?(usage) do
      percentage = :erlang.float_to_binary(rate * 100, decimals: 1)
      "CH#{percentage}%"
    else
      _unavailable -> nil
    end
  end

  defp cache_activity?(%Usage{} = usage) do
    Enum.any?(
      [usage.cache_read_tokens, usage.cache_write_tokens],
      &(is_integer(&1) and &1 > 0)
    )
  end

  defp cost_indicator(%Usage{cost: cost, currency: currency} = usage) when is_number(cost) do
    marker = if usage.cost_estimated == true, do: "~", else: ""
    decimals = if abs(cost) < 0.01, do: 4, else: 2
    amount = :erlang.float_to_binary(cost / 1, decimals: decimals)

    case currency do
      "USD" -> "#{marker}$#{amount}"
      currency when is_binary(currency) -> "#{marker}#{currency} #{amount}"
      nil -> "cost #{marker}#{amount}"
    end
  end

  defp cost_indicator(%Usage{}), do: nil

  defp format_token_count(tokens) when tokens < 1_000, do: Integer.to_string(tokens)

  defp format_token_count(tokens) when tokens < 1_000_000,
    do: compact_decimal(tokens / 1_000, "k")

  defp format_token_count(tokens), do: compact_decimal(tokens / 1_000_000, "m")

  defp compact_decimal(value, suffix) do
    decimals = if value < 10 and value != trunc(value), do: 1, else: 0
    :erlang.float_to_binary(value / 1, decimals: decimals) <> suffix
  end

  defp usage_activity?(%Usage{} = usage) do
    Enum.any?(
      [
        usage.input_tokens,
        usage.output_tokens,
        usage.reasoning_tokens,
        usage.cache_read_tokens,
        usage.cache_write_tokens,
        usage.total_tokens
      ],
      &is_integer/1
    ) or is_number(usage.cost)
  end

  defp model_info(%State{llm: %{model_info: %ModelInfo{} = info}}), do: info
  defp model_info(%State{}), do: nil

  defp format_activity(type) do
    type
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)

  # -- session helpers -----------------------------------------------------

  defp available_models(opts, agent_state) do
    current = model_ref(agent_state)

    models =
      opts
      |> Keyword.get(:models, [])
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    cond do
      is_binary(current) and current not in models -> [current | models]
      models == [] -> [current || "configured default"]
      true -> models
    end
  end

  defp model_ref(%State{llm: %{ref: ref}}) when is_binary(ref), do: ref
  defp model_ref(%State{model: model}) when is_binary(model), do: model
  defp model_ref(_agent_state), do: nil

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

  defp latest_usage(%State{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant, token_usage: usage} when not is_nil(usage) ->
        Usage.normalize(usage)

      _message ->
        nil
    end)
  end

  defp clipboard_notice(state, text, success_notice) do
    case state.clipboard_writer.(text) do
      :ok -> success_notice
      {:error, reason} -> "Copy failed: #{format_reason(reason)}"
      other -> "Copy failed: #{format_reason(other)}"
    end
  end

  defp initial_terminal_size(opts) do
    case Keyword.get(opts, :test_mode) do
      {width, height} ->
        {width, height}

      nil ->
        width = Keyword.get(opts, :width)
        height = Keyword.get(opts, :height)

        if is_integer(width) and is_integer(height) do
          {width, height}
        else
          case ExRatatui.terminal_size() do
            {width, height} when is_integer(width) and is_integer(height) -> {width, height}
            {:error, _reason} -> {80, 24}
          end
        end
    end
  end

  # -- app lifecycle -------------------------------------------------------

  defp run_app(caller, result_ref, opts) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)

    result =
      case start_link(Keyword.put_new(opts, :name, nil)) do
        {:ok, pid} -> await_exit(pid, caller, caller_monitor)
        {:error, reason} -> {:error, reason}
      end

    if result != :caller_down, do: send(caller, {result_ref, result})
  end

  defp await_exit(pid, caller, caller_monitor) do
    receive do
      {:EXIT, ^pid, reason} when reason in [:normal, :shutdown] ->
        :ok

      {:EXIT, ^pid, reason} ->
        {:error, reason}

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        if Process.alive?(pid), do: GenServer.stop(pid, :shutdown, :infinity)
        :caller_down
    end
  end
end
