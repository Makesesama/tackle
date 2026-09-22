defmodule Tackle.Phoenix.EventReducer do
  @moduledoc """
  Pure LiveView stream reducer for `Tackle.Lib.Event` streams.

  Centralizes the incremental assistant-message rendering flow:

    * begin a transient in-flight message on `:message_start`
    * append token chunks from `:message_delta` (content deltas only)
    * finalize the message on `:message_end`
    * keep a stream of grouped message blocks and keyed in-flight chat rows

  This module is effectively pure: it only mutates LiveView socket assigns and
  streams. It owns *no* persistence, PubSub, or task/cancellation logic. Message
  grouping and transient-bubble shaping are delegated to a host module
  implementing `Tackle.Phoenix.MessageView`.

  ## Required socket assigns

    * `:agent_state` — a `Tackle.Lib.State`.
    * `:streaming_messages` — a map of in-flight streaming entries (initialized
      by `init_stream/2`).
    * `:message_stream_blocks` — cached settled blocks for incremental updates.
    * `:tackle_stream_rows?` — opt into rendering transient rows in the stream;
      hosts with their own streaming presentation may omit it.
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
    entries = message_blocks(socket, agent_state)

    socket
    |> clear_streaming_messages()
    |> Phoenix.LiveView.stream(@stream_name, entries, reset: true)
    |> Component.assign(:message_stream_blocks, Map.new(entries, &{&1.id, &1}))
  end

  @doc "Synchronizes settled blocks, updating only blocks whose contents changed."
  def sync_message_stream(socket, %State{} = agent_state) do
    entries = message_blocks(socket, agent_state)
    previous = Map.get(socket.assigns, :message_stream_blocks, %{})
    current = Map.new(entries, &{&1.id, &1})

    socket =
      if Map.has_key?(socket.assigns, :message_stream_blocks) do
        socket
        |> delete_missing_blocks(previous, current)
        |> insert_changed_blocks(entries, previous)
      else
        Phoenix.LiveView.stream(socket, @stream_name, entries, reset: true)
      end

    Component.assign(socket, :message_stream_blocks, current)
  end

  defp delete_missing_blocks(socket, previous, current) do
    Enum.reduce(previous, socket, fn {id, entry}, socket ->
      if Map.has_key?(current, id),
        do: socket,
        else: Phoenix.LiveView.stream_delete(socket, @stream_name, entry)
    end)
  end

  defp insert_changed_blocks(socket, entries, previous) do
    Enum.with_index(entries)
    |> Enum.reduce(socket, fn {entry, index}, socket ->
      if Map.get(previous, entry.id) == entry,
        do: socket,
        else: Phoenix.LiveView.stream_insert(socket, @stream_name, entry, at: index)
    end)
  end

  @doc "Clears all in-flight streaming assistant chunks."
  def clear_streaming_messages(socket) do
    socket =
      Enum.reduce(current_streaming_messages(socket), socket, fn {id, _entry}, socket ->
        delete_streaming_row(socket, id)
      end)

    Component.assign(socket, :streaming_messages, %{})
  end

  @doc "Restores in-flight content from a Runner snapshot after loading the transcript."
  def restore_streaming_messages(socket, messages) when is_map(messages) do
    Enum.reduce(messages, socket, fn {id, entry}, socket ->
      socket
      |> Component.assign(
        :streaming_messages,
        Map.put(current_streaming_messages(socket), id, entry)
      )
      |> put_streaming_row(id, entry)
    end)
  end

  @doc "Converts grouped message blocks into stream items."
  def messages_from_block({:visible, message}), do: [message]
  def messages_from_block({:internal, messages}), do: messages
  def messages_from_block(messages) when is_list(messages), do: messages
  def messages_from_block(_), do: []

  @doc "Projects in-flight answer text for snapshots without a LiveView socket."
  def project_streaming(messages, %Event{} = event) when is_map(messages) do
    id = extract_message_id(event.data, event)

    case event do
      %Event{type: :message_start, data: data} ->
        if assistant_message?(data) and is_binary(id),
          do: Map.put_new(messages, id, %{content: ""}),
          else: messages

      %Event{type: :message_delta, data: data} ->
        if content_delta?(data) and is_binary(id) do
          delta = delta_text(data)

          Map.update(messages, id, %{content: delta}, fn entry ->
            %{entry | content: entry.content <> delta}
          end)
        else
          messages
        end

      %Event{type: type} when type in [:retry_scheduled, :message_end] ->
        Map.delete(messages, id)

      _ ->
        messages
    end
  end

  @doc "Consumes a stream-related event and updates its LiveView socket."
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

  def handle_tackle_event(socket, %Event{type: :retry_scheduled} = event) do
    clear_streaming_message(socket, extract_message_id(event.data, event))
  end

  def handle_tackle_event(socket, %Event{
        type: :message_end,
        data: %{message: %Message{} = message}
      }) do
    agent_state = socket.assigns.agent_state

    agent_state =
      if Enum.any?(agent_state.messages, &(&1.id == message.id)),
        do: agent_state,
        else: State.add_message(agent_state, message)

    socket
    |> Component.assign(:agent_state, agent_state)
    |> sync_message_stream(agent_state)
    |> settle_streaming_message(message.id, agent_state)
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

      entry = view.new_streaming_message()

      socket
      |> Component.assign(:streaming_messages, Map.put(messages, message_id, entry))
      |> put_streaming_row(message_id, entry)
    end
  end

  defp append_message_delta(socket, nil, _messages, _data), do: socket

  defp append_message_delta(socket, message_id, messages, data) when is_binary(message_id) do
    case delta_text(data) do
      delta when delta != "" ->
        view = message_view(socket)
        current = Map.get(messages, message_id, view.new_streaming_message())
        entry = view.append_streaming_delta(current, delta)

        socket
        |> Component.assign(:streaming_messages, Map.put(messages, message_id, entry))
        |> put_streaming_row(message_id, entry)

      _ ->
        socket
    end
  end

  defp append_message_delta(socket, _message_id, _messages, _data), do: socket

  defp settle_streaming_message(socket, id, agent_state) do
    if Enum.any?(message_blocks(socket, agent_state), &(&1.id == streaming_id(id))) do
      Component.assign(
        socket,
        :streaming_messages,
        Map.delete(current_streaming_messages(socket), id)
      )
    else
      clear_streaming_message(socket, id)
    end
  end

  defp clear_streaming_message(socket, nil), do: socket

  defp clear_streaming_message(socket, message_id) do
    messages = current_streaming_messages(socket)

    socket
    |> Component.assign(:streaming_messages, Map.delete(messages, message_id))
    |> delete_streaming_row(message_id)
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

  defp message_stream_entries(socket, messages) when is_list(messages) do
    view = message_view(socket)

    messages
    |> view.group_messages()
    |> Enum.map(fn block ->
      [first | _] = messages_from_block(block)
      %{id: "agent-msg-block-#{first.id}", block: block}
    end)
  end

  defp message_stream_entries(_socket, _), do: []

  defp delete_streaming_row(%{assigns: assigns} = socket, id) do
    if Map.get(assigns, :tackle_stream_rows?, false),
      do: Phoenix.LiveView.stream_delete(socket, @stream_name, %{id: streaming_id(id)}),
      else: socket
  end

  defp streaming_id(id), do: "agent-msg-block-#{id}"

  defp put_streaming_row(%{assigns: assigns} = socket, id, entry) do
    if Map.get(assigns, :tackle_stream_rows?, false) do
      Phoenix.LiveView.stream_insert(socket, @stream_name, %{
        id: streaming_id(id),
        block: {:streaming, entry}
      })
    else
      socket
    end
  end
end
