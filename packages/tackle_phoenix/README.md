# Tackle.Phoenix

`Tackle.Phoenix` connects [`Tackle.Runtime`](../tackle_runtime/README.md)
agents to Phoenix: it relays an agent's events over `Phoenix.PubSub` and
renders them incrementally in a LiveView stream. It owns no agent process.
The agent runs under a `Tackle.Runtime` scope through any
`Tackle.Runtime.AgentBackend`, and the host keeps authorization, persistence,
quota, billing, and message presentation.

```text
any AgentBackend agent ──Tackle.Runtime.subscribe──▶ Tackle.Phoenix.Bridge ──PubSub──▶ LiveViews
LiveView ──Tackle.Runtime.submit / cancel_turn(agent_ref)──▶ agent
```

| Module | Purpose |
|---|---|
| `Tackle.Phoenix.Bridge` | Subscribes to one agent and broadcasts its events on a host-chosen topic; keeps in-flight answer text for views that join mid-turn |
| `Tackle.Phoenix.EventReducer` | Turns streamed `Tackle.Lib.Event`s into an incrementally rendered LiveView stream |
| `Tackle.Phoenix.MessageView` | Host behaviour: message grouping and the shape of a streaming message |

For a complete app with saved conversations, idle agents, and restarts, see
the guide [Conversations with Ecto](guides/conversations_with_ecto.md).

## Installation

This package is released from this Git monorepo, not Hex, together with
`tackle_lib` and `tackle_runtime` under one tag. Add the following dependency
to your application's `mix.exs`:

```elixir
defp deps do
  [
    {:tackle_phoenix,
     git: "https://github.com/Makesesama/tackle.git",
     tag: "v0.1.0",
     subdir: "packages/tackle_phoenix"}
  ]
end
```

Run `mix deps.get`. The package's sibling `path:` dependencies resolve
`Tackle.Lib` and `Tackle.Runtime` from the same checked-out commit. Do not add
separate top-level Git dependencies for them unless you need them directly;
Mix will report diverging dependencies unless explicitly overridden. Mix's
`:subdir` option requires Elixir 1.13 or newer.

`Tackle.Phoenix` requires Elixir `~> 1.18`, Phoenix LiveView 1.1.33 or a
later 1.1 or 1.2 release (`>= 1.1.33 and < 1.3.0`; tested with 1.1.33 and
1.2.13), and Phoenix PubSub `~> 2.1`.

## 1. Run the agent under a runtime scope

The agent is whatever your `Tackle.Runtime.AgentBackend` starts; if an
in-memory conversation is enough, use the ready-made
`Tackle.Runtime.LoopAgent`. Start one scope per conversation, with a trusted
root spec your host built after authorizing the user:

```elixir
{:ok, config} =
  Tackle.Runtime.LoopAgent.Config.new(
    providers: MyApp.AI.providers_for(user),
    model: "provider/model",
    tools: MyApp.Agent.Tools.for(user),
    hooks: [MyApp.Agent.PersistenceHook],
    system_prompt: MyApp.Agent.Prompt.build(user)
  )

scope_spec =
  Tackle.Runtime.ScopeSpec.new!(
    backend: Tackle.Runtime.LoopAgent,
    root_spec: Tackle.Runtime.AgentSpec.new!(name: "root", config: config)
  )

{:ok, scope} = Tackle.Runtime.start_scope(scope_spec)
agent_ref = scope.root_agent_ref
```

To continue a conversation your app saved (for example from the
persistence hook), load it and add `messages: saved_messages` and
`session_id: saved_session_id` to the configuration. The runtime stores
nothing; the session id only keeps the agent's id stable for your hooks and
events. Add `idle_timeout: :timer.minutes(30)` to stop the scope of a
conversation nobody uses; the next message starts it again from what you
saved. The [Ecto guide](guides/conversations_with_ecto.md) puts these
together.

See the [runtime README](../tackle_runtime/README.md) for the backend
contract, subagents, and limits. The runtime's Registry is node-local: a
clustered host needs sticky routing or its own ownership layer.

## 2. Start a bridge

Start one bridge per agent you want to show, with a topic derived from the
conversation identity you already authorize:

```elixir
{:ok, _bridge} =
  DynamicSupervisor.start_child(
    MyApp.BridgeSupervisor,
    {Tackle.Phoenix.Bridge,
     agent_ref: agent_ref,
     pubsub: MyApp.PubSub,
     topic: "conversation:#{conversation.id}",
     name: {:via, Registry, {MyApp.BridgeRegistry, conversation.id}}}
  )
```

The bridge is `restart: :transient`. It stops normally after broadcasting
`{:agent_down, reason}` when the agent exits, so a bridge registered by name
(as above) leaves the registry with its agent, and `Bridge.agent_ref/1`
finds the agent of a registered bridge. A backend may also return the
bridge's child spec from `services/2`, so it starts and stops with its agent.

Subscribers receive:

```elixir
{:agent_event, %Tackle.Lib.Event{}}   # every event, auxiliary ones included
{:agent_down, reason}                 # the agent process exited
```

A turn ends with a `:turn_end` event whose `data.status` is `:completed`,
`:error`, or `:cancelled`. A turn task that crashes without the backend
publishing `:turn_end` is only reported once the agent exits, so backends
should publish one for every turn they start; `Tackle.Runtime.LoopAgent`
does.

## 3. Implement MessageView

The EventReducer does not decide what a message bubble looks like:

```elixir
defmodule MyAppWeb.AgentMessageView do
  @behaviour Tackle.Phoenix.MessageView

  @impl true
  def group_messages(messages), do: Enum.map(messages, &{:visible, &1})

  @impl true
  def new_streaming_message, do: %{content: "", html: ""}

  @impl true
  def append_streaming_delta(entry, delta) do
    content = entry.content <> delta
    %{entry | content: content, html: MyApp.Markdown.to_html(content)}
  end
end
```

A richer host can group assistant tool-call and tool-result messages into
collapsible internal-work blocks; the reducer treats blocks as opaque.

## 4. Wire the LiveView

Subscribe before reading the snapshot and the in-flight text, so no event is
lost between them:

```elixir
alias Tackle.Phoenix.{Bridge, EventReducer}

@impl true
def mount(%{"id" => id}, _session, socket) do
  # Authorize the user for this conversation first, then:
  {agent_ref, bridge} = MyApp.Conversations.agent!(socket.assigns.current_scope, id)

  if connected?(socket), do: :ok = Phoenix.PubSub.subscribe(MyApp.PubSub, "conversation:#{id}")

  {:ok, %{agent_state: agent_state} = snapshot} = Tackle.Runtime.session_snapshot(agent_ref)

  {:ok,
   socket
   |> assign(agent_ref: agent_ref, agent_state: agent_state)
   # Snapshots are backend-specific; `LoopAgent` and `Tackle.Session` report `:active_turn`.
   |> assign(:processing, Map.get(snapshot, :active_turn) != nil)
   |> assign(:tackle_message_view, MyAppWeb.AgentMessageView)
   |> EventReducer.init_stream(agent_state)
   |> EventReducer.restore_streaming_messages(Bridge.streaming(bridge))}
end
```

The snapshot's shape is the backend's; most return `%{agent_state: state}`.
A delta broadcast while the view joins may appear twice in the provisional
text; the settled message replaces it on `:message_end`.

The reducer requires the `:agent_state` and `:tackle_message_view` assigns and
manages the `:agent_messages` stream (`EventReducer.stream_name/0`). Set
`:tackle_stream_rows?` to `true` to render in-flight messages as
`{:streaming, entry}` rows in that stream; otherwise render
`@streaming_messages` yourself. Keep the stream container mounted at all
times.

```elixir
@impl true
def handle_info({:agent_event, %Tackle.Lib.Event{} = event}, socket) do
  socket =
    socket
    |> handle_domain_event(event)
    |> EventReducer.handle_tackle_event(event)

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
```

`EventReducer` handles `:message_start`, visible content `:message_delta`,
`:retry_scheduled`, `:message_end`, and `:turn_end`. A retry clears the
provisional entry of that message; a finished turn clears every in-flight
entry. Reasoning and tool-input deltas never reach the visible bubble. Handle
domain events such as navigation or current-tool indicators before or after
the reducer.

Submit and cancel through the runtime:

```elixir
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
```

Cancellation is cooperative: the backend's loop, provider adapter, and
long-running tools must observe the signal.

## Guide: a multi-tenant SaaS host

Policy belongs in the host and the backend that runs the agent, not in this
package. With `Tackle.Runtime.LoopAgent`, gate turns in the host before
calling `Tackle.Runtime.submit/2`, and persist and settle in `Tackle.Lib.Hook`s
(`after_message/3`, `after_turn/2`) or an event subscriber. Hooks do not run
when the turn task crashes; settle such turns from the `:turn_end` event with
status `:error`. Write your own backend when you need durable sessions or an
inbox. A production host usually:

1. **Builds trusted specs.** Re-authorize the persisted user and tenant
   before starting a scope or a turn, and rebuild tools, prompt, model policy,
   and `Tackle.Lib.State.context` from current server-side state. Never trust
   a persisted context wholesale.
2. **Gates each turn before provider work.** Check quota, credits, and rate
   limits before submitting the turn (or in a backend's `:submit`); fail
   closed.
3. **Persists the user message first.** Write it before the provider call, and
   finalize assistant and tool messages idempotently by their stable
   `Tackle.Lib` ids, for example from `:message_end` events or a
   `Tackle.Lib.Committer`.
4. **Settles exactly once.** Aggregate usage from `:usage` and `:step_end`
   events and charge it when the turn ends, including on error, cancellation,
   or a crashed turn task, with an idempotency key tied to the turn.
5. **Recovers.** After a restart, reload the transcript, mark pending rows
   interrupted, and resume durable deliveries.
6. **Publishes `:turn_end` for every turn**, also when the turn task crashes,
   so views settle.

Keep tenant assumptions out of `Tackle.Lib`; keep them in the backend, the
agent factory, and the tools.

### Conversation trees

Branching is a library capability. Every `%Tackle.Lib.State{}` keeps its
conversation in a `Tackle.Lib.Tree`; `State.messages` is the **active
branch's** transcript. Hosts that index the whole history read
`Tackle.Lib.Tree.enumerate/1`, and model context is `State.model_messages/1`.
Usage follows the same split: `Tackle.Lib.State.branch_usage/1` for the
active path, `Tackle.Lib.State.usage/1` for the archive. `EventReducer`
renders `State.messages`.

## Source guide

- `lib/tackle_phoenix/bridge.ex` — runtime subscription and PubSub relay
- `lib/tackle_phoenix/event_reducer.ex` — LiveView stream reducer
- `lib/tackle_phoenix/message_view.ex` — host rendering behaviour
