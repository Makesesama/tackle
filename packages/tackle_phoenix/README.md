# Tackle.Phoenix

`Tackle.Phoenix` runs the framework-free [`Tackle`](../tackle/README.md) agent
core inside an OTP/Phoenix application. It supplies a generic per-session
Runner, cooperative cancellation ownership, PubSub fan-out, usage settlement,
and a LiveView event reducer. The host still owns persistence, authorization,
tenant scoping, quotas, billing, and message presentation.

## Current status

The reusable pieces are:

- `Tackle.Phoenix.Runner`
- `Tackle.Phoenix.Store`
- `Tackle.Phoenix.PubSub`
- `Tackle.Phoenix.EventReducer`
- `Tackle.Phoenix.MessageView`

`Tackle.Phoenix.Chat` is currently a **scaffold only**. Its moduledoc describes
a future `use`-able LiveView mixin, but it does not inject mount or message
handlers yet. Integrate the EventReducer manually as shown below.

## Installation

This package is currently an in-repo path package, not a Hex package. Copy or
extract both sibling packages while preserving this layout:

```text
packages/
  tackle/
  tackle_phoenix/
```

Then add:

```elixir
# mix.exs
defp deps do
  [
    {:tackle, path: "packages/tackle"},
    {:tackle_phoenix, path: "packages/tackle_phoenix"}
  ]
end
```

`Tackle.Phoenix` requires Elixir `~> 1.18`, Phoenix LiveView `~> 1.1.33`, and
Phoenix PubSub `~> 2.1`.

## Responsibility split

| Concern | Owner |
|---|---|
| LLM loop, messages, tools, events | `Tackle` |
| Turn process, supervised task, cancellation token | `Tackle.Phoenix.Runner` |
| PubSub topic and event/terminal broadcast | `Tackle.Phoenix.PubSub` |
| Usage collection and terminal settlement ordering | `Tackle.Phoenix.Runner` |
| Permission/quota gate | host `Tackle.Phoenix.Store` |
| Trusted tenant/context enrichment | host `Tackle.Phoenix.Store` |
| Session/message persistence and recovery | host `Tackle.Phoenix.Store` |
| Pricing and billing | host `Tackle.Phoenix.Store` |
| Message grouping and rendering shape | host `Tackle.Phoenix.MessageView` |
| LiveView domain events and templates | host LiveView |

The Runner has no permissive built-in Store. That is intentional: a production
host cannot accidentally bypass tenant or billing policy by accepting a default.

## Runtime architecture

```text
LiveView/API/job
  │ run_turn
  ▼
host session facade
  ▼
Tackle.Phoenix.Runner (temporary GenServer, one user/session key)
  ├── Store.before_turn              authorization/quota gate
  ├── Store.enrich_state             trusted host context
  ├── Store.persist_user_message     write-ahead user message
  ├── Task.Supervisor.async_nolink
  │     └── host agent.continue
  │           └── Tackle loop + LLM + tools
  ├── receive Tackle.Event
  │     ├── optional pending assistant persistence
  │     ├── usage/stat aggregation
  │     └── Phoenix.PubSub broadcast
  ├── Store.settle_turn              persistence + billing
  ├── Store.after_turn               follow-up work
  └── broadcast terminal result
```

The Runner appends and broadcasts the user message before starting the task,
then calls `config.agent.continue/2`. It does not call `run/3`, because doing so
would append the user message twice.

## 1. Start the OTP infrastructure

Add a unique Registry, DynamicSupervisor, and Task.Supervisor. Reuse your
application's existing Phoenix PubSub when possible.

```elixir
# lib/my_app/application.ex
children = [
  {Phoenix.PubSub, name: MyApp.PubSub},
  {Registry, keys: :unique, name: MyApp.AgentRegistry},
  {DynamicSupervisor,
   name: MyApp.AgentSessionSupervisor,
   strategy: :one_for_one,
   max_restarts: 5,
   max_seconds: 60},
  {Task.Supervisor, name: MyApp.AgentTaskSupervisor}
]
```

Each Runner uses `restart: :temporary` and stops after 30 minutes of inactivity.
Runners are started on demand and should reload state from the host Store/facade
when recreated.

The built-in Registry is node-local. If requests for one conversation can land
on multiple cluster nodes, add sticky routing or a distributed ownership layer
in the host; `Tackle.Phoenix` does not provide cluster-wide process discovery.

## 2. Provide an agent module

The Runner expects `config.agent.continue(state, opts)`. A thin host facade is
recommended because it centralizes defaults and authorization checks:

```elixir
defmodule MyApp.Agent do
  def new(opts \\ []) do
    tools = Keyword.get(opts, :tools, MyApp.Agent.Tools.default())
    context = Keyword.get(opts, :context, %{})

    Tackle.new(
      model: Keyword.fetch!(opts, :model),
      tools: tools,
      context: context,
      system_prompt: MyApp.Agent.Prompt.build(tools, context),
      hooks: Keyword.get(opts, :hooks, []),
      llm_opts: Keyword.get(opts, :llm_opts, [])
    )
  end

  def continue(%Tackle.State{} = state, opts) do
    Tackle.continue(state, Keyword.put_new(opts, :llm_stream, true))
  end
end
```

`agent: Tackle` also satisfies `continue/2`, but a host facade is the right place
to select tools, prompts, model defaults, and any fail-closed authorization
checks.

## 3. Implement the Store

`Tackle.Phoenix.Store` is the main host integration boundary. The following
sample is deliberately minimal and suitable only for an ephemeral/local proof
of concept:

```elixir
defmodule MyApp.AgentStore do
  @behaviour Tackle.Phoenix.Store

  @impl true
  def before_turn(_host_state, _opts), do: :ok

  @impl true
  def enrich_state(host_state, state, opts) do
    trusted_context = %{
      actor_id: host_state.actor_id,
      tenant_id: host_state.tenant_id,
      scope: host_state.scope,
      turn_metadata: Keyword.get(opts, :turn_metadata, %{})
    }

    %{state | context: Map.merge(state.context, trusted_context)}
  end

  @impl true
  def persist_user_message(host_state, _state, _message), do: host_state

  @impl true
  def settle_turn(host_state, _result, _usage, _opts), do: host_state

  @impl true
  def current_session_id(host_state), do: host_state.session_id

  @impl true
  def handle_turn_failed(host_state, _reason, _opts), do: {host_state, nil}
end
```

A production Store should implement these phases:

### `before_turn(host_state, turn_opts)`

Run before any provider work. Re-authorize the persisted session identity and
check quota/credits/rate limits here. Return `:ok` or `{:error, reason}`. Any
other value fails closed as `:turn_rejected`.

Do not trust `organization_id`, `tenant_id`, or permissions merely because they
appear in caller options. Resolve them from authenticated or persisted identity.

### `enrich_state(host_state, agent_state, turn_opts)`

Return `%Tackle.State{}` with trusted host context. This is the right place for
scope, permissions, persisted session identity, correlation metadata, telemetry
configuration, and additional hooks.

The Runner treats context as opaque and only Tackle/tools/hooks read it.

### `persist_user_message(host_state, agent_state, message)`

Persist the user message before starting provider work and return updated host
state. When the host has already performed a durable write, call `run_turn` with
both `user_message_id:` and `pre_persisted_message?: true` to avoid inserting it
again.

### `persist_pending_message(host_state, data, turn_opts)` (optional)

Called best-effort on assistant `:message_start`. A host can create an in-flight
row before deltas arrive, then finalize it after `:message_end` or at settlement.
The three-argument callback is preferred; a legacy two-argument callback is
also accepted.

### `settle_turn(host_state, result, usage, turn_opts)`

Called for `{:ok, state}`, `{:error, state}`, and `{:cancelled, state}` after the
supervised task returns. Persist final messages/session status and apply billing
using the already aggregated `%Tackle.Usage{}`.

Charge actual usage on error/cancel when the provider already consumed tokens.
Keep settlement idempotent because process failure and recovery can revisit
unfinished records.

### `after_turn(host_state, result, turn_opts)` (optional)

Run host follow-ups after settlement, such as title generation or delivery
recovery. Keep this bounded; it runs in the Runner process.

### `handle_turn_failed(host_state, reason, turn_opts)`

Called when the supervised task crashes/exits rather than returning a normal
Tackle result. `turn_opts[:turn_usage]` contains usage observed before the crash.
Return `{updated_host_state, recovered_agent_state_or_nil}`.

### `init_host/1` and `handle_host_message/2` (optional)

Use these to subscribe a Runner to a private host transport or recover durable
mailbox work. `handle_host_message/2` may return:

```elixir
:unhandled
{:noreply, updated_host_state}
{:run_turn, updated_host_state, input, turn_opts}
```

The last form sends host-delivered input through the same gate, correlation,
persistence, cancellation, telemetry, billing, and settlement lifecycle as a
public turn. ExampleHost uses this seam for durable parent/child agent delivery.

## 4. Build Runner configuration

Hide the map behind a host module so LiveViews never know infrastructure names:

```elixir
defmodule MyApp.AgentSession do
  alias Tackle.Phoenix.Runner

  @config %{
    registry: MyApp.AgentRegistry,
    dynamic_supervisor: MyApp.AgentSessionSupervisor,
    task_supervisor: MyApp.AgentTaskSupervisor,
    pubsub: MyApp.PubSub,
    store: MyApp.AgentStore,
    agent: MyApp.Agent
  }

  def get_or_start(user_id, opts \\ []) do
    Runner.get_or_start(@config, user_id, prepare_start_opts(user_id, opts))
  end

  def snapshot(user_id, opts \\ []) do
    Runner.snapshot(@config, user_id, prepare_start_opts(user_id, opts))
  end

  def subscribe(user_id, session_id) do
    Runner.subscribe(@config, user_id, session_id)
  end

  def run_turn(user_id, state, input, opts \\ []) do
    Runner.run_turn(@config, user_id, state, input, prepare_start_opts(user_id, opts))
  end

  def continue_turn(user_id, state, opts \\ []) do
    Runner.continue_turn(@config, user_id, state, prepare_start_opts(user_id, opts))
  end

  def cancel_turn(pid), do: Runner.cancel_turn(pid)

  defp prepare_start_opts(user_id, opts) do
    session_id = Keyword.get(opts, :session_id)
    {agent_state, host_state} = MyApp.AgentPersistence.load(user_id, session_id)

    opts
    |> Keyword.put_new(:agent_state, agent_state)
    |> Keyword.put_new(:host_state, host_state)
  end
end
```

When creating/reloading a Runner, pass both:

```elixir
[
  session_id: persisted_session_id,
  agent_state: reconstructed_tackle_state,
  host_state: initialized_store_state
]
```

The host facade should load these from durable storage. `Runner.get_or_start/3`
otherwise needs enough state for the Store and agent to work.

## Runner API

| Function | Purpose |
|---|---|
| `get_or_start/3` | Resolve/start runner for user + optional session |
| `get_state/3` | Read in-memory Tackle state |
| `snapshot/3` or `snapshot/1` | Atomically read agent state, session ID, active turn, runner pid |
| `replace_state/3` | Replace host and agent state when idle |
| `update_state/4` | Replace only agent state |
| `get_session_id/3` | Read Store's current persisted session ID |
| `subscribe/3` | Subscribe caller to the session topic |
| `run_turn/5` | Append a user message and start a turn |
| `continue_turn/4` | Retry without appending a user message |
| `cancel_turn/1` | Request cooperative cancellation |

Only one turn can run per Runner. Concurrent `run_turn`/`continue_turn` calls
return `{:error, :turn_in_progress}` without disturbing the accepted turn.

`replace_state/3` also returns `{:error, :turn_in_progress}` while a task is
active. Prefer `snapshot/1` over separate state/status calls so a LiveView does
not race a running turn.

### Correlated/pre-persisted inputs

`run_turn/5` accepts these optional correlation values:

- `:user_message_id` — non-empty binary, at most 255 bytes;
- `:pre_persisted_message?` — boolean; `true` requires `user_message_id`;
- `:turn_metadata` — either `%{}` or exactly `kind` + `source_session_id` with
  bounded binary values.

Invalid values return `{:error, {:invalid_turn_option, field}}`. The closed
metadata shape prevents arbitrary caller data from entering durable routing and
telemetry paths.

## PubSub contract

Subscribe with:

```elixir
Tackle.Phoenix.Runner.subscribe(config, user_id, session_id)
```

The subscriber receives:

```elixir
{:agent_event, %Tackle.Event{}}
{:agent_turn_done, {:ok | :error | :cancelled, %Tackle.State{}}}
{:agent_turn_failed, reason}
```

Topic names are:

```text
agent:session:current:<user_id>   # no persisted session yet
agent:session:<session_id>        # durable session
```

When the first user message creates a persisted session during the turn,
`broadcast_turn/4` sends to both the current-user topic and new session topic.
Preserve this behavior in wrappers; otherwise a LiveView subscribed before the
session existed will silently lose first-turn updates.

## LiveView integration

### Implement MessageView

The EventReducer deliberately does not decide what a message bubble looks like:

```elixir
defmodule MyAppWeb.AgentMessageView do
  @behaviour Tackle.Phoenix.MessageView

  @impl true
  def group_messages(messages) do
    Enum.map(messages, &{:visible, &1})
  end

  @impl true
  def new_streaming_message do
    %{content: "", html: ""}
  end

  @impl true
  def append_streaming_delta(entry, delta) do
    content = entry.content <> delta
    %{entry | content: content, html: MyApp.Markdown.to_html(content)}
  end
end
```

A richer host can group assistant tool-call and tool-result messages into
collapsible internal-work blocks while leaving final answers visible. The
reducer treats the returned block shape as opaque stream content.

### Initialize the stream

```elixir
alias Tackle.Phoenix.EventReducer

@impl true
def mount(_params, _session, socket) do
  user_id = socket.assigns.current_scope.user.id
  session_id = nil

  if connected?(socket) do
    :ok = MyApp.AgentSession.subscribe(user_id, session_id)
  end

  snapshot = MyApp.AgentSession.snapshot(user_id, session_id: session_id)

  {:ok,
   socket
   |> assign(:tackle_message_view, MyAppWeb.AgentMessageView)
   |> assign(:agent_state, snapshot.agent_state)
   |> assign(:processing, snapshot.turn_active?)
   |> assign(:runner_pid, snapshot.runner_pid)
   |> EventReducer.init_stream(snapshot.agent_state)}
end
```

The reducer requires these assigns:

- `:agent_state`
- `:streaming_messages`
- `:tackle_message_view`

It manages the `:agent_messages` LiveView stream. Keep its stream container
mounted at all times; do not conditionally mount a `phx-update="stream"`
container while events may arrive.

### Reduce events and settle turns

```elixir
@impl true
def handle_info({:agent_event, %Tackle.Event{} = event}, socket) do
  socket =
    socket
    |> handle_domain_event(event)
    |> Tackle.Phoenix.EventReducer.handle_tackle_event(event)

  {:noreply, socket}
end

def handle_info({:agent_turn_done, {status, %Tackle.State{} = state}}, socket)
    when status in [:ok, :error, :cancelled] do
  socket =
    socket
    |> assign(:agent_state, state)
    |> assign(:processing, false)
    |> assign(:runner_pid, nil)
    |> Tackle.Phoenix.EventReducer.sync_message_stream(state)
    |> Tackle.Phoenix.EventReducer.clear_streaming_messages()

  {:noreply, socket}
end

def handle_info({:agent_turn_failed, reason}, socket) do
  {:noreply,
   socket
   |> assign(:processing, false)
   |> assign(:runner_pid, nil)
   |> assign(:agent_error, reason)
   |> Tackle.Phoenix.EventReducer.clear_streaming_messages()}
end
```

`EventReducer` handles `:message_start`, visible content
`:message_delta`, and `:message_end`. It intentionally ignores reasoning and
tool-input deltas for the visible bubble. Handle domain-specific events such as
navigation, resource previews, or current-tool indicators before/after invoking
the reducer.

### Start and cancel a turn

```elixir
case MyApp.AgentSession.run_turn(user_id, socket.assigns.agent_state, input,
       session_id: socket.assigns.session_id,
       tenant_id: socket.assigns.current_scope.tenant.id
     ) do
  {:ok, runner_pid} ->
    {:noreply, assign(socket, processing: true, runner_pid: runner_pid)}

  {:error, reason} ->
    {:noreply, assign(socket, processing: false, agent_error: reason)}
end
```

```elixir
def handle_event("cancel", _params, socket) do
  :ok = MyApp.AgentSession.cancel_turn(socket.assigns.runner_pid)
  {:noreply, socket}
end
```

Cancellation is cooperative. The Runner owns and deletes the signal, while the
Tackle loop, provider adapter, and long-running tools must observe it.

## Persistence and recovery design

A robust durable host normally uses this sequence:

1. Load ordered persisted messages and rebuild a fresh `%Tackle.State{}` with
   current trusted tools, prompt, model policy, and authorization.
2. Before a turn, re-authorize persisted user/tenant identity and gate quota.
3. Persist the user message before provider work.
4. Optionally insert a pending assistant row at `:message_start`.
5. Finalize messages idempotently by their stable Tackle IDs.
6. On error/cancel/crash, mark pending rows interrupted rather than presenting
   them as completed.
7. Settle usage/billing exactly once with an idempotency key tied to the turn.
8. On Runner restart, reload state and recover any durable pending deliveries.

Do not persist and later trust `%Tackle.State.context` wholesale. Authorization,
organization membership, and tool availability may have changed. Rebuild them
from current server-side state.

## Telemetry

Runner turns emit:

```text
[:tackle, :phoenix, :turn, :start]
[:tackle, :phoenix, :turn, :stop]
[:tackle, :phoenix, :turn, :exception]
```

Stop measurements include duration, count, iteration count, and tool-call count.
Metadata includes operation (`:run`/`:continue`) and bounded outcome. Supply
bounded host correlation under `telemetry_metadata:` when starting a turn.

An optional `:telemetry_adapter` in Runner config may implement
`with_context(telemetry_ref, fun)` to carry an OpenTelemetry span/context into
the supervised turn task and tool execution. ExampleHost uses this to preserve
parent/child span relationships without placing prompts or payloads in
telemetry metadata.

Core Tackle separately emits tool-execution telemetry documented in the core
README.

## ExampleHost host implementation

ExampleHost is a reference implementation, not a dependency of these packages.
Its wiring is split as follows:

| Layer | File | Responsibility |
|---|---|---|
| Supervision | `lib/my_app/application.ex` | Registry, DynamicSupervisor, Task.Supervisor, PubSub |
| Host session API | `lib/my_app/agent/session.ex` | Runner config, DB bootstrap, reload/switch/subscribe API |
| Store | `lib/my_app/agent/session_store.ex` | Ecto persistence, tenant reauthorization, quota, billing, recovery |
| Agent factory | `lib/my_app/agent/agent.ex` | tools, model, prompt, hooks, session auth reconstruction |
| LLM adapter | `lib/my_app/ai/tackle_adapter.ex` | OpenRouter/native-tool translation and streaming |
| Persistence hook | `lib/my_app/agent/hooks/persistence.ex` | incremental idempotent message finalization |
| LiveViews | `lib/my_app_web/live/agent_panel_live.ex`, `agent_sessions_live/show.ex` | subscription, submit/retry/cancel, domain events |
| MessageView | `lib/my_app_web/components/agent_chat.ex` | grouping, markdown, rich tool presentation |
| Telemetry | `lib/my_app/telemetry/open_telemetry/agent_workflow.ex` | generic telemetry to OpenTelemetry spans |

### ExampleHost-specific policies

These are intentionally outside `tackle_phoenix`:

- organization is the tenant boundary;
- persisted session identity is re-authorized before every turn;
- organization subscription limits gate the turn before the LLM call;
- normalized usage is charged at settlement, including consumed usage on
  failures/cancellation;
- user, assistant, and tool messages are stored in Ecto with stable ordering;
- pending assistant rows are recovered/marked interrupted after crashes;
- UI tools and data tools have different surface allowlists;
- durable child agents use Store mailbox callbacks plus host database state;
- only an explicitly safe subset of tools is exposed through MCP.

The reusable lesson is to keep these policies in the Store, agent factory, and
tool implementations rather than adding tenant assumptions to Tackle itself.

## Production checklist

- [ ] Start Registry, DynamicSupervisor, Task.Supervisor, and PubSub.
- [ ] Hide Runner config behind a host facade.
- [ ] Implement every required Store callback.
- [ ] Fail closed in `before_turn/2`.
- [ ] Derive tenant scope from trusted identity in `enrich_state/3`.
- [ ] Persist user messages before starting provider work.
- [ ] Make message and billing settlement idempotent.
- [ ] Recover or interrupt pending rows after crashes.
- [ ] Use `snapshot/1` for atomic UI reconciliation.
- [ ] Handle all event, done, and failed PubSub messages.
- [ ] Keep the LiveView stream container mounted.
- [ ] Observe cancellation in provider adapters and long-running tools.
- [ ] Plan node affinity/distributed ownership for a clustered deployment.
- [ ] Attach bounded telemetry without prompt/tool payloads.
- [ ] Do not rely on `Tackle.Phoenix.Chat` until it has a real implementation.

## Source guide

- `lib/tackle_phoenix/runner.ex` — authoritative process/turn lifecycle
- `lib/tackle_phoenix/store.ex` — host persistence/policy contract
- `lib/tackle_phoenix/pub_sub.ex` — topic and dual-broadcast contract
- `lib/tackle_phoenix/event_reducer.ex` — LiveView stream reducer
- `lib/tackle_phoenix/message_view.ex` — host rendering behaviour
- `lib/tackle_phoenix/chat.ex` — future mixin scaffold
