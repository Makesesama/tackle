defmodule Tackle.Phoenix.PubSub do
  @moduledoc """
  Topic naming and broadcast/subscribe conventions for agent turns.

  A turn's events are fanned out on a per-session topic. Before a DB session
  exists (the very first message of a fresh conversation), subscribers listen on
  a stable *current* topic keyed by user; once the session is created mid-turn,
  events are broadcast to **both** the current topic and the new session topic so
  an already-subscribed LiveView keeps receiving updates without resubscribing.

  Preserving this dual-topic fan-out is load-bearing: dropping it silently breaks
  the "first message on a brand-new session" live-update path.

  The `Phoenix.PubSub` server module is injected by the caller (typically the
  Runner's configuration), so this layer keeps no hard reference to a host's
  PubSub name.

  Messages broadcast during a turn:

    * `{:agent_event, %Tackle.Lib.Event{}}`
    * `{:agent_turn_done, {:ok | :error | :cancelled, %Tackle.Lib.State{}}}`
    * `{:agent_turn_failed, reason}`
  """

  @doc """
  Builds the topic string for a (user, session) pair.

  When `session_id` is nil, returns the stable per-user *current* topic.
  """
  @spec topic(binary(), binary() | nil) :: String.t()
  def topic(user_id, nil) when is_binary(user_id), do: "agent:session:current:#{user_id}"

  def topic(user_id, session_id) when is_binary(user_id) and is_binary(session_id),
    do: "agent:session:#{byte_size(user_id)}:#{user_id}:#{session_id}"

  @doc """
  Subscribes the calling process to a (user, session) topic.
  """
  @spec subscribe(atom(), binary(), binary() | nil) ::
          :ok | {:error, {:already_registered, pid()}}
  def subscribe(pubsub, user_id, session_id) when is_atom(pubsub) do
    Phoenix.PubSub.subscribe(pubsub, topic(user_id, session_id))
  end

  @doc "Unsubscribes the calling process from a (user, session) topic."
  @spec unsubscribe(atom(), binary(), binary() | nil) :: :ok
  def unsubscribe(pubsub, user_id, session_id) when is_atom(pubsub) do
    Phoenix.PubSub.unsubscribe(pubsub, topic(user_id, session_id))
  end

  @doc """
  Broadcasts a message on the current-user topic only.
  """
  @spec broadcast(module(), binary(), binary() | nil, term()) :: :ok | {:error, term()}
  def broadcast(pubsub, user_id, session_id, message) when is_atom(pubsub) do
    Phoenix.PubSub.broadcast(pubsub, topic(user_id, session_id), message)
  end

  @doc """
  Dual-topic broadcast for a turn whose session was created mid-flight.

  Sends `message` to both the per-user current topic and the session topic when
  a `session_id` is present, so subscribers on either topic receive it. When
  `session_id` is nil, only the current topic is used.
  """
  @spec broadcast_turn(module(), binary(), binary() | nil, term()) :: :ok
  def broadcast_turn(pubsub, user_id, session_id, message) when is_atom(pubsub) do
    if is_binary(session_id) do
      Phoenix.PubSub.broadcast(pubsub, topic(user_id, nil), message)
      Phoenix.PubSub.broadcast(pubsub, topic(user_id, session_id), message)
    else
      Phoenix.PubSub.broadcast(pubsub, topic(user_id, nil), message)
    end

    :ok
  end
end
