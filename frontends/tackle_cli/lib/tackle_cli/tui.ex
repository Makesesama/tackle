defmodule Tackle.CLI.TUI do
  @moduledoc """
  Interactive terminal frontend for a configured Tackle session.

  The TUI owns presentation and input state while the root harness continues to
  own the session and agent loop.
  """

  use ExRatatui.App

  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}
  alias ExRatatui.{Layout, Style}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph, Popup, TextInput, WidgetList}
  alias ExRatatui.Widgets.List, as: SelectionList
  alias Tackle.Lib.{ContextUsage, Event, Message, ModelInfo, State, Usage}
  alias Tackle.Session.Snapshot
  alias Tackle.Thinking

  @tool_arguments_limit 240
  @tool_result_limit 500
  @tool_result_lines 6
  @mouse_scroll_rows 3
  @conversation_chunk_rows 64
  @conversation_sections [:settled, :pending, :tools, :thinking, :response, :error]
  @zero_width_grapheme ~r/^[\p{M}\p{Cf}]+$/u
  @emoji_presentation ~r/\p{Emoji_Presentation}/u
  @wide_codepoint_ranges [
    {0x1100, 0x115F},
    {0x231A, 0x231B},
    {0x2329, 0x232A},
    {0x2E80, 0xA4CF},
    {0xAC00, 0xD7A3},
    {0xF900, 0xFAFF},
    {0xFE10, 0xFE19},
    {0xFE30, 0xFE6F},
    {0xFF00, 0xFF60},
    {0xFFE0, 0xFFE6},
    {0x1F1E6, 0x1FAFF},
    {0x20000, 0x3FFFD}
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
    with {:ok, session} <- Keyword.fetch(opts, :session),
         {:ok, %Snapshot{} = snapshot} <- Tackle.subscribe(session) do
      models = available_models(opts, snapshot.agent_state)

      {width, height} = initial_terminal_size(opts)

      state = %{
        session: session,
        session_id: snapshot.session_id,
        agent_state: snapshot.agent_state,
        active_turn: snapshot.active_turn,
        session_monitor: Process.monitor(session),
        input: ExRatatui.text_input_new(),
        models: models,
        settings: nil,
        pending_prompt: nil,
        streaming_thinking: "",
        streaming_response: "",
        latest_usage: latest_usage(snapshot.agent_state),
        live_usage: nil,
        live_context_usage: nil,
        tool_activity: [],
        activity: nil,
        error: nil,
        conversation: new_conversation(width, height)
      }

      {:ok, refresh_conversation(state)}
    else
      :error -> {:error, :missing_session}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def render(state, frame), do: scene(state, frame)

  @doc false
  @spec scene(map(), ExRatatui.Frame.t()) :: [{struct(), Rect.t()}]
  def scene(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    [header_area, conversation_area, input_area, footer_area] = layout_areas(area)

    widgets = [
      {header_widget(state), header_area},
      {conversation_widget(state, conversation_area), conversation_area},
      {input_widget(state), input_area},
      {footer_widget(state, footer_area), footer_area}
    ]

    if state.settings, do: widgets ++ [{settings_widget(state), area}], else: widgets
  end

  @impl true
  def handle_event(%Key{code: "c", modifiers: ["ctrl"], kind: "press"}, state) do
    {:stop, state}
  end

  def handle_event(%Key{code: "esc", kind: "press"}, %{settings: settings} = state)
      when not is_nil(settings) do
    {:noreply, %{state | settings: nil}}
  end

  def handle_event(%Key{code: code, kind: "press"}, %{settings: settings} = state)
      when not is_nil(settings) and code in ["up", "down"] do
    field = if settings.field == :model, do: :thinking, else: :model
    {:noreply, %{state | settings: %{settings | field: field}}}
  end

  def handle_event(%Key{code: code, kind: "press"}, %{settings: settings} = state)
      when not is_nil(settings) and code in ["left", "right"] do
    {:noreply, cycle_setting(state, code)}
  end

  def handle_event(%Key{code: "enter", kind: "press"}, %{settings: settings} = state)
      when not is_nil(settings) do
    apply_settings(state)
  end

  def handle_event(%Key{kind: "press"}, %{settings: settings} = state)
      when not is_nil(settings) do
    {:noreply, state, render?: false}
  end

  def handle_event(%Mouse{}, %{settings: settings} = state) when not is_nil(settings) do
    {:noreply, state, render?: false}
  end

  def handle_event(%Resize{width: width, height: height}, state) do
    {:noreply, resize_conversation(state, width, height)}
  end

  def handle_event(%Key{code: "page_up", kind: "press"}, state) do
    scroll_reply(state, scroll_conversation(state, -conversation_page_size(state)))
  end

  def handle_event(%Key{code: "page_down", kind: "press"}, state) do
    scroll_reply(state, scroll_conversation(state, conversation_page_size(state)))
  end

  def handle_event(%Key{code: "home", modifiers: ["ctrl"], kind: "press"}, state) do
    scroll_reply(state, scroll_conversation_to(state, :start))
  end

  def handle_event(%Key{code: "end", modifiers: ["ctrl"], kind: "press"}, state) do
    scroll_reply(state, scroll_conversation_to(state, :end))
  end

  def handle_event(%Mouse{kind: kind} = mouse, state)
      when kind in ["scroll_up", "scroll_down"] do
    if conversation_contains?(state.conversation, mouse.x, mouse.y) do
      delta = if kind == "scroll_up", do: -@mouse_scroll_rows, else: @mouse_scroll_rows
      scroll_reply(state, scroll_conversation(state, delta))
    else
      {:noreply, state, render?: false}
    end
  end

  def handle_event(%Key{code: "f2", kind: "press"}, %{active_turn: nil} = state) do
    {:noreply, open_settings(state)}
  end

  def handle_event(%Key{code: "esc", kind: "press"}, %{active_turn: nil} = state) do
    {:stop, state}
  end

  def handle_event(%Key{code: "esc", kind: "press"}, state) do
    :ok = Tackle.cancel(state.session)
    {:noreply, %{state | activity: "cancelling"}}
  end

  def handle_event(%Key{code: "enter", kind: "press"}, %{active_turn: nil} = state) do
    submit_prompt(state)
  end

  def handle_event(%Key{kind: "press", code: code}, state) do
    :ok = ExRatatui.text_input_handle_key(state.input, code)
    {:noreply, state}
  end

  def handle_event(%Paste{}, %{settings: settings} = state) when not is_nil(settings) do
    {:noreply, state, render?: false}
  end

  def handle_event(%Paste{content: content}, state) do
    :ok = ExRatatui.text_input_insert_str(state.input, content)
    {:noreply, state}
  end

  def handle_event(_event, state), do: {:noreply, state, render?: false}

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
         live_context_usage: live_context_usage,
         activity: "usage"
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
        error: error
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
        error: format_reason(reason)
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
        settings: nil,
        error: nil
    }

    {:noreply, refresh_conversation(state)}
  end

  def handle_info({:tackle_session_closed, session_id}, %{session_id: session_id} = state) do
    {:stop, state}
  end

  def handle_info(
        {:DOWN, monitor_ref, :process, session, reason},
        %{session: session, session_monitor: monitor_ref}
      ) do
    exit({:session_down, reason})
  end

  def handle_info(_message, state), do: {:noreply, state, render?: false}

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.session), do: Tackle.unsubscribe(state.session)
    :ok
  end

  defp submit_prompt(state) do
    prompt = state.input |> ExRatatui.text_input_get_value() |> String.trim()

    if prompt == "" do
      {:noreply, state, render?: false}
    else
      case Tackle.submit(state.session, prompt) do
        {:ok, turn_id} ->
          :ok = ExRatatui.text_input_set_value(state.input, "")

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
              error: nil
          }

          state = scroll_conversation_to(state, :end)

          {:noreply,
           refresh_conversation(state, [:pending, :tools, :thinking, :response, :error])}

        {:error, reason} ->
          state = %{state | error: format_reason(reason)}
          {:noreply, refresh_conversation(state, [:error])}
      end
    end
  end

  defp header_widget(state) do
    model = model_ref(state.agent_state) || "configured default"
    thinking = Thinking.from_llm_opts(state.agent_state.llm_opts)

    %Paragraph{
      text: " Tackle  ·  #{model}  ·  thinking #{thinking}  ·  #{status(state)}",
      style: %Style{fg: :cyan, modifiers: [:bold]},
      block: panel_block(" Session ", :cyan)
    }
  end

  defp conversation_widget(state, _area) do
    %WidgetList{
      items: state.conversation.visible_items,
      scroll_offset: state.conversation.visible_offset,
      block: panel_block(conversation_title(state.conversation), :dark_gray)
    }
  end

  defp conversation_title(conversation) do
    max_offset = max(conversation.content_height - conversation.viewport_height, 0)

    cond do
      max_offset == 0 -> " Conversation "
      conversation.follow? -> " Conversation · latest "
      true -> " Conversation · #{round(conversation.scroll_offset / max_offset * 100)}% "
    end
  end

  defp input_widget(state) do
    %TextInput{
      state: state.input,
      placeholder: if(state.active_turn, do: "Agent is working…", else: "Ask Tackle…"),
      placeholder_style: %Style{fg: :dark_gray},
      block: panel_block(" Prompt ", if(state.active_turn, do: :dark_gray, else: :green))
    }
  end

  defp footer_widget(state, _area) do
    controls =
      if state.active_turn do
        "Esc cancel · Ctrl+C quit"
      else
        "Enter send · F2 model/thinking · Esc quit · Ctrl+C quit"
      end

    text =
      (session_stat_indicators(state) ++ ["PgUp/PgDn scroll · Ctrl+End follow", controls])
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    %Paragraph{text: " " <> text, style: %Style{fg: :dark_gray}}
  end

  defp panel_block(title, color) do
    %Block{
      title: title,
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: color}
    }
  end

  defp conversation_entries(state, :settled),
    do: Enum.flat_map(state.agent_state.messages, &format_message/1)

  defp conversation_entries(state, :pending) do
    if state.pending_prompt, do: ["You:\n#{state.pending_prompt}"], else: []
  end

  defp conversation_entries(state, :tools),
    do: Enum.map(state.tool_activity, &format_tool_activity/1)

  defp conversation_entries(state, :thinking) do
    if state.streaming_thinking == "",
      do: [],
      else: ["Thinking:\n#{state.streaming_thinking}"]
  end

  defp conversation_entries(state, :response) do
    if state.streaming_response == "",
      do: [],
      else: ["Tackle:\n#{state.streaming_response}"]
  end

  defp conversation_entries(state, :error) do
    if state.error, do: ["Error:\n#{state.error}"], else: []
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

  defp layout_areas(area) do
    Layout.split(area, :vertical, [
      {:length, 3},
      {:min, 0},
      {:length, 3},
      {:length, 1}
    ])
  end

  defp new_conversation(width, height) do
    area = %Rect{x: 0, y: 0, width: width, height: height}
    [_header, conversation_area, _input, _footer] = layout_areas(area)

    %{
      width: max(conversation_area.width - 2, 1),
      viewport_height: max(conversation_area.height - 2, 0),
      rect: conversation_area,
      sections: Map.new(@conversation_sections, &{&1, []}),
      items: [],
      visible_items: [],
      visible_offset: 0,
      content_height: 0,
      scroll_offset: 0,
      follow?: true
    }
  end

  # Cache wrapped sections in transition state so render/2 only hands the
  # already-sliced viewport to ExRatatui. Streaming updates rebuild just their
  # section instead of reformatting settled messages.
  defp refresh_conversation(state, sections \\ @conversation_sections) do
    conversation = state.conversation

    section_items =
      Enum.reduce(sections, conversation.sections, fn section, items ->
        Map.put(items, section, build_conversation_section(state, section, conversation.width))
      end)

    entry_items = Enum.flat_map(@conversation_sections, &Map.fetch!(section_items, &1))

    entry_items =
      case entry_items do
        [] ->
          build_conversation_items(
            ["Welcome to Tackle. Type a prompt below to start a session."],
            conversation.width
          )

        entries ->
          entries
      end

    items =
      entry_items
      |> Enum.intersperse([{%Paragraph{text: ""}, 1}])
      |> List.flatten()

    content_height =
      Enum.reduce(items, 0, fn {_widget, item_height}, total -> total + item_height end)

    max_offset = max(content_height - conversation.viewport_height, 0)

    scroll_offset =
      if conversation.follow?,
        do: max_offset,
        else: min(conversation.scroll_offset, max_offset)

    conversation = %{
      conversation
      | sections: section_items,
        items: items,
        content_height: content_height,
        scroll_offset: scroll_offset,
        follow?: conversation.follow? or scroll_offset == max_offset
    }

    %{state | conversation: put_visible_conversation(conversation)}
  end

  defp build_conversation_section(state, section, width) do
    state
    |> conversation_entries(section)
    |> build_conversation_items(width)
  end

  # Bound individual widgets as well as the visible item count. WidgetList must
  # render a whole partially-visible item before clipping it, so one unbounded
  # Paragraph would make a long agent response expensive even after slicing.
  defp build_conversation_items(entries, width) do
    Enum.map(entries, fn entry ->
      entry
      |> wrap_text(width)
      |> String.split("\n", trim: false)
      |> Enum.chunk_every(@conversation_chunk_rows)
      |> Enum.map(fn lines ->
        {%Paragraph{text: Enum.join(lines, "\n")}, length(lines)}
      end)
    end)
  end

  defp resize_conversation(state, width, height) do
    old_conversation = state.conversation

    conversation =
      width
      |> new_conversation(height)
      |> Map.put(:scroll_offset, old_conversation.scroll_offset)
      |> Map.put(:follow?, old_conversation.follow?)

    state
    |> Map.put(:conversation, conversation)
    |> refresh_conversation()
  end

  defp scroll_conversation(state, delta) do
    conversation = state.conversation
    max_offset = max(conversation.content_height - conversation.viewport_height, 0)
    scroll_offset = conversation.scroll_offset |> Kernel.+(delta) |> max(0) |> min(max_offset)

    conversation = %{
      conversation
      | scroll_offset: scroll_offset,
        follow?: scroll_offset == max_offset
    }

    %{state | conversation: put_visible_conversation(conversation)}
  end

  defp scroll_conversation_to(state, :start) do
    conversation = %{state.conversation | scroll_offset: 0, follow?: false}
    %{state | conversation: put_visible_conversation(conversation)}
  end

  defp scroll_conversation_to(state, :end) do
    max_offset = max(state.conversation.content_height - state.conversation.viewport_height, 0)
    conversation = %{state.conversation | scroll_offset: max_offset, follow?: true}
    %{state | conversation: put_visible_conversation(conversation)}
  end

  defp conversation_page_size(state), do: max(state.conversation.viewport_height - 1, 1)

  defp scroll_reply(state, scrolled_state) do
    if scrolled_state.conversation.scroll_offset == state.conversation.scroll_offset,
      do: {:noreply, state, render?: false},
      else: {:noreply, scrolled_state}
  end

  defp conversation_contains?(%{rect: rect}, x, y) when is_integer(x) and is_integer(y) do
    x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height
  end

  defp conversation_contains?(_conversation, _x, _y), do: false

  defp put_visible_conversation(conversation) do
    {remaining_items, visible_offset} =
      drop_scrolled_items(conversation.items, conversation.scroll_offset)

    visible_items =
      take_visible_items(
        remaining_items,
        conversation.viewport_height + visible_offset
      )

    %{
      conversation
      | visible_items: visible_items,
        visible_offset: visible_offset
    }
  end

  defp drop_scrolled_items([{_widget, height} | items], offset) when offset >= height,
    do: drop_scrolled_items(items, offset - height)

  defp drop_scrolled_items(items, offset), do: {items, offset}

  defp take_visible_items(_items, rows) when rows <= 0, do: []
  defp take_visible_items([], _rows), do: []

  defp take_visible_items([{_widget, height} = item | items], rows),
    do: [item | take_visible_items(items, rows - height)]

  defp settings_widget(state) do
    settings = state.settings
    model = Enum.at(state.models, settings.model_index)
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
      block: panel_block(" Settings · ↑/↓ field · ←/→ select · Enter apply · Esc close ", :cyan),
      percent_width: 80,
      percent_height: 35
    }
  end

  defp open_settings(state) do
    model_index = Enum.find_index(state.models, &(&1 == model_ref(state.agent_state))) || 0
    thinking = Thinking.from_llm_opts(state.agent_state.llm_opts)
    thinking_index = Enum.find_index(Thinking.levels(), &(&1 == thinking)) || 0

    %{
      state
      | settings: %{field: :model, model_index: model_index, thinking_index: thinking_index}
    }
  end

  defp cycle_setting(state, direction) do
    delta = if direction == "left", do: -1, else: 1
    settings = state.settings

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

    %{state | settings: settings}
  end

  defp cycle_index(index, delta, count), do: Integer.mod(index + delta, count)

  defp apply_settings(state) do
    model = Enum.at(state.models, state.settings.model_index)
    thinking = Enum.at(Thinking.levels(), state.settings.thinking_index)

    case Tackle.reconfigure(state.session, model: model, thinking: thinking) do
      {:ok, %Snapshot{} = snapshot} ->
        state = %{
          state
          | agent_state: snapshot.agent_state,
            active_turn: snapshot.active_turn,
            settings: nil,
            error: nil
        }

        {:noreply, refresh_conversation(state)}

      {:error, reason} ->
        state = %{state | settings: nil, error: format_reason(reason)}
        {:noreply, refresh_conversation(state, [:error])}
    end
  end

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

  defp wrap_text(text, width) do
    text
    |> String.split("\n", trim: false)
    |> Enum.flat_map(&wrap_line(&1, width))
    |> Enum.join("\n")
  end

  defp wrap_line("", _width), do: [""]

  defp wrap_line(line, width) do
    {lines, current, _current_width} =
      line
      |> String.graphemes()
      |> Enum.reduce({[], [], 0}, fn grapheme, {lines, current, current_width} ->
        grapheme_width = terminal_width(grapheme)

        if current != [] and current_width + grapheme_width > width do
          {[Enum.reverse(current) | lines], [grapheme], grapheme_width}
        else
          {lines, [grapheme | current], current_width + grapheme_width}
        end
      end)

    [Enum.reverse(current) | lines]
    |> Enum.reverse()
    |> Enum.map(&Enum.join/1)
  end

  defp terminal_width(grapheme) do
    codepoints = String.to_charlist(grapheme)

    cond do
      Regex.match?(@zero_width_grapheme, grapheme) -> 0
      Regex.match?(@emoji_presentation, grapheme) -> 2
      0xFE0F in codepoints -> 2
      Enum.any?(codepoints, &wide_codepoint?/1) -> 2
      true -> 1
    end
  end

  defp wide_codepoint?(codepoint) do
    Enum.any?(@wide_codepoint_ranges, fn {first, last} ->
      codepoint >= first and codepoint <= last
    end)
  end

  defp format_message(%Message{role: :user, content: content}) when is_binary(content),
    do: ["You:\n#{content}"]

  defp format_message(%Message{role: :assistant} = message) do
    thinking =
      if is_binary(message.thinking) and message.thinking != "",
        do: ["Thinking:\n#{message.thinking}"],
        else: []

    content =
      if is_binary(message.content) and message.content != "",
        do: ["Tackle:\n#{message.content}"],
        else: []

    tool_calls = Enum.map(message.tool_calls || [], &format_tool_call/1)
    thinking ++ content ++ tool_calls
  end

  defp format_message(%Message{role: :tool} = message) do
    failed? =
      is_binary(message.content) and
        String.starts_with?(String.trim_leading(message.content), "Error:")

    status = if failed?, do: :failed, else: :completed

    [
      format_tool_activity(%{
        name: message.tool_name || "unknown",
        status: status,
        result: if(failed?, do: nil, else: message.content),
        error: if(failed?, do: message.content, else: nil)
      })
    ]
  end

  defp format_message(_message), do: []

  defp format_tool_call(tool_call) do
    name = value(tool_call, :name) || "unknown"
    arguments = value(tool_call, :arguments)
    "● #{name}" <> format_detail("args", arguments, @tool_arguments_limit)
  end

  defp format_tool_activity(%{status: :running} = tool) do
    "● #{tool.name}" <>
      format_detail("args", Map.get(tool, :arguments), @tool_arguments_limit) <>
      "\n  running"
  end

  defp format_tool_activity(%{status: :completed} = tool) do
    "✓ #{tool.name}" <>
      format_detail("args", Map.get(tool, :arguments), @tool_arguments_limit) <>
      "\n  completed" <>
      format_detail("result", Map.get(tool, :result), @tool_result_limit)
  end

  defp format_tool_activity(%{status: :failed} = tool) do
    "✗ #{tool.name}" <>
      format_detail("args", Map.get(tool, :arguments), @tool_arguments_limit) <>
      "\n  failed" <>
      format_detail("error", Map.get(tool, :error), @tool_result_limit)
  end

  defp format_detail(_label, value, _limit) when value in [nil, "", %{}], do: ""

  defp format_detail(label, value, limit) do
    preview = value |> format_value() |> truncate_preview(limit) |> indent_lines()
    "\n  #{label}: #{preview}"
  end

  defp format_value(value) when is_binary(value), do: value

  defp format_value(value) when is_map(value) or is_list(value) do
    case Tackle.Lib.JSON.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(value)
    end
  end

  defp format_value(value), do: inspect(value)

  defp truncate_preview(value, limit) do
    lines = value |> String.trim() |> String.split("\n")
    lines_truncated? = length(lines) > @tool_result_lines
    preview = lines |> Enum.take(@tool_result_lines) |> Enum.join("\n")
    chars_truncated? = String.length(preview) > limit
    preview = if chars_truncated?, do: String.slice(preview, 0, limit), else: preview

    if lines_truncated? or chars_truncated?, do: preview <> "…", else: preview
  end

  defp indent_lines(value), do: String.replace(value, "\n", "\n  ")

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

  defp session_stat_indicators(state) do
    usage = displayed_usage(state)

    [
      context_indicator(displayed_context_usage(state)),
      token_indicator("in", usage.input_tokens),
      token_indicator("out", usage.output_tokens),
      cache_hit_indicator(usage),
      cost_indicator(usage)
    ]
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

  defp status(%{active_turn: nil, error: nil}), do: "ready"
  defp status(%{active_turn: nil}), do: "error"
  defp status(%{activity: nil}), do: "working"
  defp status(%{activity: activity}), do: activity

  defp format_activity(type) do
    type
    |> Atom.to_string()
    |> String.replace("_", " ")
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

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
