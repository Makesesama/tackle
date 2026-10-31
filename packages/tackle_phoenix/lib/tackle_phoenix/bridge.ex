defmodule Tackle.Phoenix.Bridge do
  @moduledoc """
  Relays one `Tackle.Runtime` agent's events to a `Phoenix.PubSub` topic.

  The bridge subscribes to the agent through `Tackle.Runtime.subscribe/1`, so
  it works with any `Tackle.Runtime.AgentBackend`. It owns no turn, no
  persistence, and no policy: LiveViews submit and cancel turns through the
  runtime (`Tackle.Runtime.submit/2`, `Tackle.Runtime.cancel_turn/1`) and
  render what the bridge broadcasts.

  ## Options

    * `:agent_ref` (required) - the `Tackle.Runtime.AgentRef` to relay.
    * `:pubsub` (required) - the `Phoenix.PubSub` server name.
    * `:topic` (required) - the topic to broadcast on. The host chooses it,
      typically from the conversation identity it already authorizes.
    * `:name` - an optional `GenServer` name, so views can find the bridge.

  ## Broadcast messages

    * `{:agent_event, %Tackle.Lib.Event{}}` for every event the agent
      publishes, auxiliary events included. A turn ends with a `:turn_end`
      event whose `data.status` is `:completed`, `:error`, or `:cancelled`.
    * `{:agent_down, reason}` once when the agent process exits; the bridge
      then stops.

  A turn whose task crashes without the backend publishing `:turn_end` is not
  reported until the agent itself exits; that is up to the backend.

  ## Joining mid-turn

  `streaming/1` returns the visible answer text of messages still being
  streamed, keyed by message id, for `Tackle.Phoenix.EventReducer.restore_streaming_messages/2`.
  Subscribe to the topic before reading it and the agent's snapshot: a delta
  the bridge broadcast while the view joined may then appear twice in the
  provisional text, which the settled message replaces on `:message_end`.
  Reasoning and tool-input deltas are never kept. A bridge started (or
  restarted) mid-turn knows only the deltas it has seen since.

  ## Supervision

  The bridge is `restart: :transient`: it stops normally when its agent exits
  and is restarted only after a crash. Start it under the host's supervisor,
  or return its child spec from a backend's `services/2` so it lives and dies
  with the agent.
  """

  use GenServer, restart: :transient

  alias Tackle.Lib.Event
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef

  @type option ::
          {:agent_ref, AgentRef.t()}
          | {:pubsub, atom()}
          | {:topic, String.t()}
          | {:name, GenServer.name()}

  @doc "Starts a bridge for one agent. See the module documentation for options."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Returns the visible text of messages still being streamed, as
  `%{message_id => %{content: text}}`.
  """
  @spec streaming(GenServer.server()) :: %{String.t() => %{content: String.t()}}
  def streaming(server), do: GenServer.call(server, :streaming)

  @impl true
  def init(opts) do
    with {:ok, agent_ref} <- fetch(opts, :agent_ref, &match?(%AgentRef{}, &1)),
         {:ok, pubsub} <- fetch(opts, :pubsub, &is_atom/1),
         {:ok, topic} <- fetch(opts, :topic, &(is_binary(&1) and &1 != "")),
         {:ok, monitor} <- Runtime.monitor_agent(agent_ref),
         :ok <- subscribe(agent_ref) do
      {:ok,
       %{
         agent_ref: agent_ref,
         pubsub: pubsub,
         topic: topic,
         monitor: monitor,
         streaming: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp fetch(opts, key, valid?) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_option, key, value}}

      :error ->
        {:error, {:missing_option, key}}
    end
  end

  defp subscribe(agent_ref) do
    case Runtime.subscribe(agent_ref) do
      {:ok, _snapshot} -> :ok
      {:error, reason} -> {:error, {:subscribe_failed, reason}}
    end
  end

  @impl true
  def handle_call(:streaming, _from, state), do: {:reply, state.streaming, state}

  @impl true
  def handle_info({:tackle_event, _session_id, _turn_id, %Event{} = event}, state),
    do: {:noreply, relay(state, event)}

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{monitor: monitor} = state) do
    Phoenix.PubSub.broadcast(state.pubsub, state.topic, {:agent_down, reason})
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp relay(state, %Event{} = event) do
    state = %{state | streaming: project_streaming(state.streaming, event)}
    Phoenix.PubSub.broadcast(state.pubsub, state.topic, {:agent_event, event})
    state
  end

  # Visible answer text per in-flight assistant message. Retries discard the
  # partial answer, a settled message replaces it, and a finished turn leaves
  # nothing in flight.
  defp project_streaming(messages, %Event{type: :message_start, id: id, data: data})
       when is_binary(id) do
    if Map.get(data, :role, :assistant) == :assistant,
      do: Map.put_new(messages, id, %{content: ""}),
      else: messages
  end

  defp project_streaming(messages, %Event{type: :message_delta, id: id, data: data})
       when is_binary(id) do
    case data do
      %{delta: delta} when is_binary(delta) and delta != "" ->
        if Map.get(data, :field, :content) == :content,
          do: Map.update(messages, id, %{content: delta}, &%{&1 | content: &1.content <> delta}),
          else: messages

      _other ->
        messages
    end
  end

  defp project_streaming(messages, %Event{type: :retry_scheduled, id: id}),
    do: Map.delete(messages, id)

  defp project_streaming(messages, %Event{type: :message_end, data: %{message: %{id: id}}}),
    do: Map.delete(messages, id)

  defp project_streaming(_messages, %Event{type: :turn_end}), do: %{}
  defp project_streaming(messages, %Event{}), do: messages
end
