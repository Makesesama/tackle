defmodule Tackle.Phoenix.EventReducer do
  @moduledoc """
  Pure LiveView stream reducer for `Tackle.Lib.Event` streams.

  Centralizes the incremental assistant-message rendering flow:

    * begin a transient in-flight message on `:message_start`
    * append token chunks from `:message_delta` (content deltas only)
    * finalize the message on `:message_end`
    * keep a stream of grouped message blocks

  This module is effectively pure: it only mutates LiveView socket assigns and
  streams. It owns *no* persistence, PubSub, or task/cancellation logic. Message
  grouping and transient-bubble shaping are delegated to a host module
  implementing `Tackle.Phoenix.MessageView`.

  ## Required socket assigns

    * `:agent_state` — a `Tackle.Lib.State`.
    * `:streaming_messages` — a map of in-flight streaming entries (initialized
      by `init_stream/2`).
    * `:tackle_message_view` — the `Tackle.Phoenix.MessageView` implementation.

  The host wires the view once (typically in `mount/3`):

      socket
      |> assign(:tackle_message_view, MyAppWeb.Components.AgentChat)
      |> EventReducer.init_stream(agent_state)
  """

  alias Phoenix.Component
  alias Tackle.Lib.Event
  alias Tackle.Lib.Message
  alias Tackle.Lib.State

  @stream_name :agent_messages

  @doc "Name of the message stream managed by this reducer."
  def stream_name, do: @stream_name

  @doc "Initializes stream state from an existing agent state."
  def init_stream(socket, %State{} = agent_state) do
    socket
    |> clear_streaming_messages()
    |> sync_message_stream(agent_state)
  end

  @doc "Resets the message stream from the current agent state."
  def sync_message_stream(socket, %State{} = agent_state) do
    Phoenix.LiveView.stream(
      socket,
      @stream_name,
      message_blocks(socket, agent_state),
      reset: true
    )
  end

  @doc "Clears all in-flight streaming assistant chunks."
  def clear_streaming_messages(socket) do
    Component.assign(socket, :streaming_messages, %{})
  end

  @doc "Converts grouped message blocks into stream items."
  def messages_from_block({:visible, message}), do: [message]
  def messages_from_block({:internal, messages}), do: messages
  def messages_from_block(messages) when is_list(messages), do: messages
  def messages_from_block(_), do: []

  @doc """
  Consumes a stream-related `Tackle.Lib.Event`.

  Returns an updated socket for `:message_start`, `:message_delta`, and
  `:message_end`; all other events are returned unchanged.
  """
  def handle_tackle_event(socket, %Event{type: :message_start, data: data} = event) do
    if assistant_message?(data) do
      maybe_start_message(
        socket,
        extract_message_id(data, event),
        current_streaming_messages(socket)
      )
    else
      socket
    end
  end

  def handle_tackle_event(socket, %Event{type: :message_delta, data: data} = event) do
    # Only *content* deltas belong in the visible assistant bubble. Reasoning
    # and tool-input deltas share the `:message_delta` type but carry a `:field`
    # tag (`:reasoning` / `:tool_input`); appending those would leak the agent's
    # raw chain-of-thought or the tool-call argument JSON into the chat bubble.
    if content_delta?(data) do
      append_message_delta(
        socket,
        extract_message_id(data, event),
        current_streaming_messages(socket),
        data
      )
    else
      socket
    end
  end

  def handle_tackle_event(socket, %Event{
        type: :message_end,
        data: %{message: %Message{} = message}
      }) do
    agent_state = State.add_message(socket.assigns.agent_state, message)

    socket
    |> Component.assign(:agent_state, agent_state)
    |> sync_message_stream(agent_state)
    |> clear_streaming_message(message.id)
  end

  def handle_tackle_event(socket, _event), do: socket

  # ── MessageView seam ──────────────────────────────────────────────────────

  defp message_view(%{assigns: %{tackle_message_view: view}}) when is_atom(view) and view != nil,
    do: view

  defp message_view(_socket) do
    raise ArgumentError,
          "Tackle.Phoenix.EventReducer requires a :tackle_message_view assign " <>
            "(a module implementing Tackle.Phoenix.MessageView)"
  end

  # ── Internals (extracted verbatim from the host's AgentEventHandler) ────────

  defp assistant_message?(data) when is_map(data) do
    role = Map.get(data, :role, Map.get(data, "role", :assistant))
    role in [:assistant, "assistant"]
  end

  defp assistant_message?(_), do: true

  defp content_delta?(data) when is_map(data) do
    case Map.get(data, :field, Map.get(data, "field")) do
      nil -> true
      :content -> true
      "content" -> true
      _ -> false
    end
  end

  defp content_delta?(_), do: true

  defp current_streaming_messages(%{assigns: %{streaming_messages: messages}}),
    do: messages || %{}

  defp current_streaming_messages(_), do: %{}

  defp maybe_start_message(socket, nil, _messages), do: socket

  defp maybe_start_message(socket, message_id, messages) when is_binary(message_id) do
    if Map.has_key?(messages, message_id) do
      socket
    else
      view = message_view(socket)

      Component.assign(
        socket,
        :streaming_messages,
        Map.put(messages, message_id, view.new_streaming_message())
      )
    end
  end

  defp append_message_delta(socket, nil, _messages, _data), do: socket

  defp append_message_delta(socket, message_id, messages, data) when is_binary(message_id) do
    case delta_text(data) do
      delta when delta != "" ->
        view = message_view(socket)
        current = Map.get(messages, message_id, view.new_streaming_message())
        entry = view.append_streaming_delta(current, delta)
        Component.assign(socket, :streaming_messages, Map.put(messages, message_id, entry))

      _ ->
        socket
    end
  end

  defp append_message_delta(socket, _message_id, _messages, _data), do: socket

  defp clear_streaming_message(socket, message_id) do
    messages = current_streaming_messages(socket)
    Component.assign(socket, :streaming_messages, Map.delete(messages, message_id))
  end

  defp extract_message_id(data, event) when is_map(data) and is_struct(event, Event) do
    cond do
      is_binary(event.id) && event.id != "" -> event.id
      is_binary(Map.get(data, :id)) -> Map.get(data, :id)
      is_binary(Map.get(data, "id")) -> Map.get(data, "id")
      is_binary(Map.get(data, :message_id)) -> Map.get(data, :message_id)
      is_binary(Map.get(data, "message_id")) -> Map.get(data, "message_id")
      true -> nil
    end
  end

  defp extract_message_id(_data, _event), do: nil

  defp delta_text(data) when is_map(data) do
    cond do
      is_binary(Map.get(data, :delta)) -> Map.get(data, :delta)
      is_binary(Map.get(data, "delta")) -> Map.get(data, "delta")
      is_binary(Map.get(data, :text)) -> Map.get(data, :text)
      is_binary(Map.get(data, "text")) -> Map.get(data, "text")
      true -> ""
    end
  end

  defp delta_text(_), do: ""

  defp message_blocks(socket, %State{messages: messages}),
    do: message_stream_entries(socket, messages)

  defp message_blocks(socket, _), do: message_stream_entries(socket, [])

  defp message_stream_entries(socket, messages) when is_list(messages) do
    view = message_view(socket)

    messages
    |> view.group_messages()
    |> Enum.with_index()
    |> Enum.map(fn {block, index} ->
      %{id: stream_entry_id(index), block: block}
    end)
  end

  defp message_stream_entries(_socket, _), do: []

  defp stream_entry_id(index) when is_integer(index), do: "agent-msg-block-#{index}"
  defp stream_entry_id(index), do: "agent-msg-block-#{inspect(index)}"
end
