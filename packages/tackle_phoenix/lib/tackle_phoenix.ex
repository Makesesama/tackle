defmodule Tackle.Phoenix do
  @moduledoc """
  Tackle.Phoenix — the Phoenix runtime + UI glue for Tackle.

  `Tackle` is the stateless, framework-free agent core (loop, cancellation,
  events, state). `Tackle.Phoenix` is the thin layer that runs that core inside
  an OTP/Phoenix application: it owns the long-lived turn process, the
  cancellation signal, PubSub fan-out of `Tackle.Event`s, turn settlement, and
  the LiveView stream that renders the conversation.

  It deliberately owns *no* persistence, *no* billing/quota, *no* org scoping,
  and *no* opinion about how a message looks. Those stay host-side behind small
  behaviours, exactly where multi-tenant/billing logic belongs. This keeps
  `Tackle.Phoenix` adoptable: a host wires its repo/pubsub/registry and a couple
  of callbacks, and gets the generic runtime for free.

  ## What Tackle.Phoenix provides

    * `Tackle.Phoenix.Runner` — a GenServer that supervises one agent turn
      (`Task.Supervisor.async_nolink`), owns the cancellation signal, fans
      `Tackle.Event`s out over PubSub, and settles the turn
      (`:ok` / `:error` / `:cancelled` → `:agent_turn_done`, crash →
      `:agent_turn_failed`).
    * `Tackle.Phoenix.EventReducer` — a pure LiveView stream reducer that turns
      streamed `Tackle.Event`s into incrementally rendered messages.
    * `Tackle.Phoenix.Chat` — a `use`-able LiveView mixin that wires
      mount → subscribe, stream init, and the turn-settlement `handle_info`
      clauses, leaving render + domain events to the host.
    * `Tackle.Phoenix.PubSub` — topic naming + dual-topic broadcast/subscribe.

  ## What the host provides

    * A `Tackle.Phoenix.Store` implementation for persistence, enrichment,
      quota and billing (org-scoped — never bypassed by this library).
    * A `Tackle.Phoenix.MessageView` implementation for message grouping and
      transient streaming-message rendering.
    * Infrastructure modules (Registry, DynamicSupervisor, Task.Supervisor,
      `Phoenix.PubSub`) supplied via config to the Runner.

  See `lib/tackle.ex` for the agent core this layer drives.
  """
end
