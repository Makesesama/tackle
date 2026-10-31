defmodule Tackle.Phoenix do
  @moduledoc """
  Tackle.Phoenix — Phoenix PubSub and LiveView glue for `Tackle.Runtime` agents.

  The agent process belongs to a `Tackle.Runtime.AgentBackend`; this package
  owns none. It relays an agent's events to Phoenix and renders them, so it
  works with any backend, and LiveViews submit and cancel turns through the
  runtime (`Tackle.Runtime.submit/2`, `Tackle.Runtime.cancel_turn/1`).

    * `Tackle.Phoenix.Bridge` — subscribes to one agent and broadcasts its
      `Tackle.Lib.Event`s on a host-chosen `Phoenix.PubSub` topic, keeping the
      in-flight answer text for views that join mid-turn.
    * `Tackle.Phoenix.EventReducer` — a LiveView stream reducer that turns
      streamed `Tackle.Lib.Event`s into incrementally rendered messages.
    * `Tackle.Phoenix.MessageView` — the host behaviour that decides how
      messages are grouped and how a streaming message looks.

  Authorization, persistence, quota, and billing stay with the host and its
  backend.
  """
end
