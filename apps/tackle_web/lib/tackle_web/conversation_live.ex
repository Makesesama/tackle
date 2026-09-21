defmodule Tackle.Web.ConversationLive do
  @moduledoc """
  One chat conversation with the assistant.

  The conversation is a `Tackle.Phoenix.Runner` session wired through
  `Tackle.Web.ChatSession`, and this LiveView is only a view of it: it renders
  the transcript, streams the answer in flight, and turns clicks into calls on
  the session facade. `Tackle.Phoenix.EventReducer` owns the streaming state —
  it keeps `:agent_state` and `:streaming_messages` up to date, groups the
  transcript through `Tackle.Web.ChatMessageView`, and filters reasoning and
  tool-input deltas out of the visible answer.

  Everything shown here is in memory. A reload re-reads the conversation from
  `Tackle.Web.ChatStore` and reattaches to the Runner; restarting the server
  starts from an empty conversation list.
  """

  use Tackle.Web, :live_view

  alias Tackle.Lib.Event
  alias Tackle.Lib.State
  alias Tackle.Phoenix.EventReducer
  alias Tackle.Web.AgentActivity
  alias Tackle.Web.ChatAgent
  alias Tackle.Web.ChatError
  alias Tackle.Web.ChatMessageView
  alias Tackle.Web.ChatSession
  alias Tackle.Web.ChatStore
  alias Tackle.Web.Components.Chat
  alias Tackle.Web.Projects

  @impl true
  def mount(%{"slug" => slug, "id" => id}, _session, socket) do
    if Projects.get(slug) == nil do
      # A conversation only makes sense inside the project that decides the
      # directory the assistant reads, so an unknown project is not a page.
      {:ok, push_navigate(socket, to: ~p"/projects")}
    else
      socket =
        socket
        |> assign(
          section: :projects,
          slug: slug,
          conversation_id: id,
          conversation: nil,
          conversations: ChatStore.list(slug),
          models: ChatAgent.models(),
          model: nil,
          draft: "",
          agent_state: nil,
          streaming_messages: %{},
          tackle_message_view: ChatMessageView,
          processing: false,
          runner_pid: nil,
          activity: nil,
          error: nil,
          loaded: false
        )
        # The stream container is rendered before anything is done with the
        # conversation, so the disconnected render of this page — which never
        # reaches a Runner — has a stream to render as well.
        |> stream(:agent_messages, [])

      if connected?(socket) do
        _ = ChatStore.subscribe()
        {:ok, connect(socket, id)}
      else
        {:ok, socket}
      end
    end
  end

  @impl true
  def handle_info({:agent_event, %Event{} = event}, socket) do
    socket =
      socket
      |> track_activity(event)
      |> EventReducer.handle_tackle_event(event)

    {:noreply, socket}
  end

  def handle_info({:agent_turn_done, {status, %State{} = state}}, socket)
      when status in [:ok, :error, :cancelled] do
    socket =
      socket
      |> assign(agent_state: state, processing: false, runner_pid: nil, activity: nil)
      |> EventReducer.sync_message_stream(state)
      |> EventReducer.clear_streaming_messages()
      |> put_turn_error(status)

    {:noreply, socket}
  end

  def handle_info({:agent_turn_failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(
       processing: false,
       runner_pid: nil,
       activity: nil,
       error: "The assistant stopped unexpectedly: #{inspect(reason)}"
     )
     |> EventReducer.clear_streaming_messages()}
  end

  def handle_info({:chat_updated, id}, socket) do
    socket = assign(socket, :conversations, ChatStore.list(socket.assigns.slug))

    if id == socket.assigns.conversation_id do
      # The transcript itself arrives through turn events; this only picks up a
      # title and model the store now holds.
      case conversation_of(socket, id) do
        nil ->
          {:noreply, gone(socket)}

        conversation ->
          {:noreply, assign(socket, conversation: conversation, page_title: conversation.title)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:chat_deleted, id}, socket) do
    # Deleting a conversation broadcasts on the same topic this LiveView is
    # subscribed to, so its own deletion arrives here like anyone else's.
    if id == socket.assigns.conversation_id do
      {:noreply, gone(socket)}
    else
      {:noreply, assign(socket, :conversations, ChatStore.list(socket.assigns.slug))}
    end
  end

  @impl true
  def handle_event("draft", %{"message" => %{"body" => body}}, socket) when is_binary(body) do
    {:noreply, assign(socket, :draft, body)}
  end

  def handle_event("send", %{"message" => %{"body" => body}}, socket) do
    cond do
      socket.assigns.processing ->
        # The composer stays as it is: the message was not sent and the reader
        # should not have to type it again.
        {:noreply, assign(socket, :error, "Wait for the current answer to finish.")}

      String.trim(body) == "" ->
        {:noreply, assign(socket, :error, "Write a message first.")}

      is_nil(socket.assigns.agent_state) ->
        {:noreply, assign(socket, :error, "This conversation has no configured agent to run.")}

      true ->
        run_turn(socket, String.trim(body))
    end
  end

  def handle_event("cancel_turn", _params, socket) do
    :ok = ChatSession.cancel_turn(socket.assigns.runner_pid)
    {:noreply, socket}
  end

  def handle_event("retry_turn", _params, socket) do
    case ChatSession.continue_turn(socket.assigns.conversation_id, socket.assigns.agent_state) do
      {:ok, pid} -> {:noreply, start_turn(socket, pid)}
      {:error, reason} -> {:noreply, assign(socket, :error, ChatError.message(reason))}
    end
  end

  def handle_event("select_model", %{"model" => model}, socket) do
    cond do
      socket.assigns.processing ->
        {:noreply,
         assign(socket, :error, "Wait for the current answer to finish, then switch models.")}

      model == socket.assigns.model ->
        {:noreply, socket}

      true ->
        switch_model(socket, model)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    ChatStore.delete(id)

    if id == socket.assigns.conversation_id do
      {:noreply,
       socket
       |> put_flash(:info, "Conversation deleted.")
       |> push_navigate(to: ~p"/projects/#{socket.assigns.slug}")}
    else
      {:noreply, assign(socket, :conversations, ChatStore.list(socket.assigns.slug))}
    end
  end

  # Reading the conversation back is one unit of work: the transcript, the
  # directory it was started in and the model it runs all come from the stored
  # conversation, so a conversation that cannot be loaded has nothing to show.
  defp connect(socket, id) do
    case conversation_of(socket, id) do
      nil ->
        gone(socket)

      conversation ->
        :ok = ChatSession.subscribe(id)

        case ChatSession.snapshot(conversation) do
          {:ok, snapshot} ->
            socket
            |> assign(
              conversation: conversation,
              model: conversation.model || ChatAgent.default_model(),
              page_title: conversation.title,
              agent_state: snapshot.agent_state,
              processing: snapshot.turn_active?,
              runner_pid: snapshot.runner_pid,
              loaded: true
            )
            |> EventReducer.init_stream(snapshot.agent_state)

          {:error, reason} ->
            assign(socket,
              conversation: conversation,
              model: conversation.model,
              loaded: true,
              error: ChatError.message(reason)
            )
        end
    end
  end

  defp run_turn(socket, body) do
    case ChatSession.run_turn(socket.assigns.conversation_id, socket.assigns.agent_state, body) do
      {:ok, pid} -> {:noreply, socket |> start_turn(pid) |> assign(:draft, "")}
      {:error, reason} -> {:noreply, assign(socket, :error, ChatError.message(reason))}
    end
  end

  defp start_turn(socket, pid) do
    assign(socket, processing: true, runner_pid: pid, error: nil, activity: nil)
  end

  defp switch_model(socket, model) do
    %{conversation: conversation, agent_state: state} = socket.assigns

    case ChatSession.change_model(conversation, state, model) do
      {:ok, new_state} ->
        {:noreply, assign(socket, agent_state: new_state, model: model, error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, ChatError.message(reason))}
    end
  end

  # A conversation belongs to the project it was started in, so one addressed
  # under another project is treated as missing rather than rendered.
  defp conversation_of(socket, id) do
    case ChatStore.get(id) do
      %{project_slug: slug} = conversation when slug == socket.assigns.slug -> conversation
      _other -> nil
    end
  end

  defp gone(socket) do
    socket
    |> put_flash(:error, "That conversation is no longer in memory.")
    |> push_navigate(to: ~p"/projects/#{socket.assigns.slug}")
  end

  defp track_activity(socket, %Event{type: :tool_start, data: data}) do
    assign(socket, :activity, AgentActivity.label(data))
  end

  defp track_activity(socket, %Event{type: type}) when type in [:tool_end, :tool_error] do
    assign(socket, :activity, nil)
  end

  defp track_activity(socket, _event), do: socket

  defp put_turn_error(socket, :ok), do: assign(socket, :error, nil)
  defp put_turn_error(socket, :cancelled), do: assign(socket, :error, nil)

  defp put_turn_error(socket, :error) do
    error = socket.assigns.agent_state |> Map.get(:error) |> Kernel.||("That turn failed.")
    assign(socket, :error, to_string(error))
  end

  defp asked?(%State{messages: messages}) do
    Enum.any?(messages, &(&1.role == :user))
  end

  defp asked?(_state), do: false

  defp workspace(nil), do: ""
  defp workspace(conversation), do: conversation.cwd
end
