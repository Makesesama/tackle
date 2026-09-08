defmodule Tackle.CLI.TUI do
  @moduledoc """
  Interactive terminal frontend for a configured Tackle session.

  The TUI owns presentation and input state while the root harness continues to
  own the session and agent loop.
  """

  use ExRatatui.App

  alias ExRatatui.Event.{Key, Paste}
  alias ExRatatui.{Layout, Style}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph, TextInput, WidgetList}
  alias Tackle.Lib.{Event, Message, State}
  alias Tackle.Session.Snapshot

  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts) when is_list(opts) do
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
      {:ok,
       %{
         session: session,
         session_id: snapshot.session_id,
         agent_state: snapshot.agent_state,
         active_turn: snapshot.active_turn,
         session_monitor: Process.monitor(session),
         input: ExRatatui.text_input_new(),
         pending_prompt: nil,
         streaming_response: "",
         activity: nil,
         error: nil
       }}
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

    [header_area, conversation_area, input_area, footer_area] =
      Layout.split(area, :vertical, [
        {:length, 3},
        {:min, 0},
        {:length, 3},
        {:length, 1}
      ])

    [
      {header_widget(state), header_area},
      {conversation_widget(state, conversation_area), conversation_area},
      {input_widget(state), input_area},
      {footer_widget(state), footer_area}
    ]
  end

  @impl true
  def handle_event(%Key{code: "c", modifiers: ["ctrl"], kind: "press"}, state) do
    {:stop, state}
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

  def handle_event(%Paste{content: content}, state) do
    :ok = ExRatatui.text_input_insert_str(state.input, content)
    {:noreply, state}
  end

  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:tackle_event, session_id, turn_id,
         %Event{type: :message_delta, data: %{delta: delta} = data}},
        %{session_id: session_id, active_turn: %{id: turn_id}} = state
      )
      when is_binary(delta) do
    streaming_response =
      if Map.get(data, :field) in [nil, :content] do
        state.streaming_response <> delta
      else
        state.streaming_response
      end

    {:noreply, %{state | streaming_response: streaming_response, activity: "responding"}}
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

    {:noreply,
     %{
       state
       | agent_state: agent_state,
         active_turn: nil,
         pending_prompt: nil,
         streaming_response: "",
         activity: nil,
         error: error
     }}
  end

  def handle_info(
        {:tackle_turn_failed, session_id, turn_id, reason},
        %{session_id: session_id, active_turn: %{id: turn_id}} = state
      ) do
    {:noreply,
     %{
       state
       | active_turn: nil,
         pending_prompt: nil,
         streaming_response: "",
         activity: nil,
         error: format_reason(reason)
     }}
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

  def handle_info(_message, state), do: {:noreply, state}

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

          {:noreply,
           %{
             state
             | active_turn: %{id: turn_id},
               pending_prompt: prompt,
               streaming_response: "",
               activity: "starting",
               error: nil
           }}

        {:error, reason} ->
          {:noreply, %{state | error: format_reason(reason)}}
      end
    end
  end

  defp header_widget(state) do
    model = state.agent_state.model || "configured default"

    %Paragraph{
      text: " Tackle  ·  #{model}  ·  #{status(state)}",
      style: %Style{fg: :cyan, modifiers: [:bold]},
      block: panel_block(" Session ", :cyan)
    }
  end

  defp conversation_widget(state, area) do
    content_width = max(area.width - 2, 1)
    viewport_height = max(area.height - 2, 0)

    items =
      state
      |> conversation_entries()
      |> Enum.with_index()
      |> Enum.map(fn {entry, index} ->
        text = wrap_text(if(index == 0, do: entry, else: "\n" <> entry), content_width)
        height = text |> String.split("\n", trim: false) |> length()
        {%Paragraph{text: text}, height}
      end)

    total_height = Enum.reduce(items, 0, fn {_widget, height}, total -> total + height end)

    %WidgetList{
      items: items,
      scroll_offset: max(total_height - viewport_height, 0),
      block: panel_block(" Conversation ", :dark_gray)
    }
  end

  defp input_widget(state) do
    %TextInput{
      state: state.input,
      placeholder: if(state.active_turn, do: "Agent is working…", else: "Ask Tackle…"),
      placeholder_style: %Style{fg: :dark_gray},
      block: panel_block(" Prompt ", if(state.active_turn, do: :dark_gray, else: :green))
    }
  end

  defp footer_widget(state) do
    text =
      if state.active_turn do
        " Esc cancel · Ctrl+C quit"
      else
        " Enter send · Esc quit · Ctrl+C quit"
      end

    %Paragraph{text: text, style: %Style{fg: :dark_gray}}
  end

  defp panel_block(title, color) do
    %Block{
      title: title,
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: color}
    }
  end

  defp conversation_entries(state) do
    settled = Enum.flat_map(state.agent_state.messages, &format_message/1)
    pending = if state.pending_prompt, do: ["You:\n#{state.pending_prompt}"], else: []

    streaming =
      if state.streaming_response == "",
        do: [],
        else: ["Tackle:\n#{state.streaming_response}"]

    error = if state.error, do: ["Error:\n#{state.error}"], else: []

    case settled ++ pending ++ streaming ++ error do
      [] -> ["Welcome to Tackle. Type a prompt below to start a session."]
      entries -> entries
    end
  end

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
    if grapheme |> String.to_charlist() |> Enum.any?(&wide_codepoint?/1), do: 2, else: 1
  end

  defp wide_codepoint?(codepoint) do
    codepoint in 0x1100..0x115F or
      codepoint in 0x2329..0x232A or
      codepoint in 0x2E80..0xA4CF or
      codepoint in 0xAC00..0xD7A3 or
      codepoint in 0xF900..0xFAFF or
      codepoint in 0xFE10..0xFE19 or
      codepoint in 0xFE30..0xFE6F or
      codepoint in 0xFF00..0xFF60 or
      codepoint in 0xFFE0..0xFFE6 or
      codepoint in 0x1F1E6..0x1FAFF or
      codepoint in 0x20000..0x3FFFD
  end

  defp format_message(%Message{role: :user, content: content}) when is_binary(content),
    do: ["You:\n#{content}"]

  defp format_message(%Message{role: :assistant, content: content}) when is_binary(content),
    do: ["Tackle:\n#{content}"]

  defp format_message(_message), do: []

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
