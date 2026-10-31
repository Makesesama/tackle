defmodule Tackle.Phoenix.Test.ChatLive do
  @moduledoc false

  # A chat LiveView wired as the package README shows: subscribe, then read
  # the agent's snapshot and the bridge's in-flight text, reduce events, and
  # submit and cancel through the runtime. The session carries what a host's
  # authorization would have resolved.

  use Phoenix.LiveView

  alias Tackle.Phoenix.Bridge
  alias Tackle.Phoenix.EventReducer

  defmodule MessageView do
    @moduledoc false
    @behaviour Tackle.Phoenix.MessageView

    @impl true
    def group_messages(messages), do: Enum.map(messages, &{:visible, &1})

    @impl true
    def new_streaming_message, do: %{content: ""}

    @impl true
    def append_streaming_delta(entry, delta), do: %{entry | content: entry.content <> delta}
  end

  @impl true
  def mount(_params, session, socket) do
    %{"agent_ref" => agent_ref, "bridge" => bridge, "pubsub" => pubsub, "topic" => topic} =
      session

    if connected?(socket), do: :ok = Phoenix.PubSub.subscribe(pubsub, topic)

    {:ok, %{agent_state: agent_state} = snapshot} = Tackle.Runtime.session_snapshot(agent_ref)

    {:ok,
     socket
     |> assign(agent_ref: agent_ref, agent_state: agent_state, agent_error: nil)
     |> assign(:processing, Map.get(snapshot, :active_turn) != nil)
     |> assign(:tackle_message_view, MessageView)
     |> assign(:tackle_stream_rows?, true)
     |> EventReducer.init_stream(agent_state)
     |> EventReducer.restore_streaming_messages(Bridge.streaming(bridge))}
  end

  @impl true
  def handle_info({:agent_event, %Tackle.Lib.Event{} = event}, socket) do
    socket = EventReducer.handle_tackle_event(socket, event)

    socket =
      if event.type == :turn_end, do: assign(socket, :processing, false), else: socket

    {:noreply, socket}
  end

  def handle_info({:agent_down, reason}, socket) do
    {:noreply,
     socket
     |> assign(processing: false, agent_error: reason)
     |> EventReducer.clear_streaming_messages()}
  end

  @impl true
  def handle_event("submit", %{"input" => input}, socket) do
    case Tackle.Runtime.submit(socket.assigns.agent_ref, input) do
      {:ok, _turn} -> {:noreply, assign(socket, :processing, true)}
      {:error, reason} -> {:noreply, assign(socket, :agent_error, reason)}
    end
  end

  def handle_event("cancel", _params, socket) do
    case Tackle.Runtime.cancel_turn(socket.assigns.agent_ref) do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:noreply, assign(socket, :agent_error, reason)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="messages" phx-update="stream">
      <div :for={{dom_id, entry} <- @streams.agent_messages} id={dom_id}>{inspect(entry.block)}</div>
    </div>
    """
  end
end
