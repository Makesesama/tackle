# Tackle.Runtime

`Tackle.Runtime` is the optional OTP orchestration layer above
[`Tackle.Lib`](../tackle_lib/README.md). It provides scoped agent supervision,
stable PID-free references, admission limits, cancellation, subagents,
background runs, and fan-out without depending on Phoenix or the root developer
harness.

```text
tackle_lib
    ↑
tackle_runtime
   ↗       ↖
tackle   tackle_phoenix
```

## Performance benchmarks

Repository-only Benchee suites cover delegated lifecycles, retained
request memory, and synthetic streaming bursts. See the
[benchmark guide](../../bench/README.md) for commands, saved baselines, and
cross-process measurement limitations. Benchee is dev-only, not a runtime dependency.

## Responsibilities

The runtime owns:

- root scopes and logical parent/child ownership;
- per-agent tool `Task.Supervisor` processes;
- per-agent service supervision for backend-provided services;
- concurrency, depth, and child limits;
- delegated request/await/collect/cancel lifecycle;
- generic subagent tools.

A host backend owns:

- construction of the concrete agent process;
- authorization, quota, persistence, and billing;
- turn submission, cancellation, snapshots, and event delivery;
- backend-specific parent configuration inheritance;
- model-facing message delivery through one `:deliver` backend operation.

`Tackle.Runtime.Messaging.deliver/2` routes validated
`Tackle.Runtime.Envelope` values to an in-scope recipient. `Runtime.tell/3`
uses it for ordinary agent text. Deferred work uses `:launch` envelopes
correlated with a turn and tool call, and `:completion` envelopes that may wake
an idle agent. Hosts own queueing, presentation, and capacity: the root harness
bounds ordinary text separately from deferred envelopes and returns an error
on overflow. Envelopes are transient unless the host persists them. A host
without an inbox rejects `:deliver` instead of acknowledging an undelivered
message.

Implement `Tackle.Runtime.AgentBackend`, put trusted opaque configuration in an
`AgentSpec`, and select the backend in the `ScopeSpec`:

```elixir
root = Tackle.Runtime.AgentSpec.new!(
  name: "root",
  config: my_backend_config,
  allow_delegation: true
)

scope_spec = Tackle.Runtime.ScopeSpec.new!(
  backend: MyApp.AgentBackend,
  root_spec: root,
  profiles: %{"worker" => worker_spec}
)

{:ok, scope} = Tackle.Runtime.start_scope(scope_spec)
```

The root harness provides `Tackle.Runtime.RootBackend` for `Tackle.Session`.
`Tackle.Phoenix` provides no backend: its `Tackle.Phoenix.Bridge` relays any
backend's agent events over Phoenix PubSub.

## Ready-made backend: `Tackle.Runtime.LoopAgent`

Hosts that only need to run `Tackle.Lib` loops do not have to write a
backend. `Tackle.Runtime.LoopAgent` runs one in-memory conversation per agent
and one turn at a time in a linked task with the agent's tool supervisor:

```elixir
{:ok, config} =
  Tackle.Runtime.LoopAgent.Config.new(
    providers: providers,
    model: "provider/model",
    tools: tools,
    hooks: [MyApp.AgentHooks],
    system_prompt: "You review code.",
    credential_store: MyApp.CredentialStore.handle(owner_id)
  )

scope_spec =
  Tackle.Runtime.ScopeSpec.new!(
    backend: Tackle.Runtime.LoopAgent,
    root_spec: Tackle.Runtime.AgentSpec.new!(name: "root", config: config)
  )
```

It supports `:submit`, `:continue`, `:cancel`, `:cancel_tool_call`,
`:subscribe` (events arrive as `{:tackle_event, session_id, turn_id, event}`;
subscribers are monitored), `:unsubscribe`, `:snapshot` (`%{agent_state:, active_turn:}`;
during a turn its transcript already holds the messages the turn has settled),
`:publish_event`, and `:reconfigure`, plus `prepare_child/2`,
`select_model/2`, `configure/2`, `describe/1`, and `llm/1`, so it runs
subagents, workflows, and code reviews. Models resolve only against the
configuration's own providers, and a `:credential_store` handle stays in
every model call's options. A crashed turn task publishes `:turn_end` with
status `:error`, keeps the messages the turn settled before the crash, and
reports a `:runtime_error` outcome.

It persists nothing and has no inbox (`:deliver` is unsupported). A host
gates turns before submitting them and puts persistence or billing in
`Tackle.Lib.Hook`s, or writes its own backend when it needs durable sessions
or message delivery.

To resume a conversation the host saved, for example with an
`after_message/3` hook, the host loads it and passes it in; the runtime
stores and looks up nothing:

```elixir
Tackle.Runtime.LoopAgent.Config.new(
  providers: providers,
  model: "provider/model",
  hooks: [MyApp.PersistenceHook],
  # The host's saved transcript, in order (or `tree:` for a branching host).
  messages: MyApp.Chats.load_messages(conversation),
  # Only a label: keeps `state.session_id` and the events' session id the
  # same as before, so hooks keyed on it keep writing to this conversation.
  session_id: conversation.session_id
)
```

The agent starts from that transcript; tool calls a crash left unanswered are
repaired when the next turn starts.

## Per-request model selection

`Tackle.Runtime.request_agent/4` accepts `model: "provider/model"` to override a
child's model for one run; the subagent tool exposes it as its optional `model`
argument. The runtime checks it is a non-empty string and passes it, after
`prepare_child/2`, to the backend's optional `select_model/2` callback, which
must resolve it only against the child's trusted configuration. Backends that
do not implement `select_model/2` refuse such requests with
`{:error, {:model_selection_unsupported, model}}` before admission.
`Tackle.Runtime.RootBackend` and `Tackle.Runtime.LoopAgent` implement it.

## Configuring trusted specs

Code review runs trusted profiles with another model, thinking level, step
limit, or per-run context, without knowing the backend's configuration type.
Backends opt in with three optional callbacks, which the runtime exposes for
the backend of a requester's scope:

- `configure/2` (`Tackle.Runtime.configure_spec/3`) applies `:model`,
  `:thinking`, `:max_steps`, `:context` (merged into the session context), and
  `:llm_opts` (merged into the adapter options), resolving models only against
  the spec's trusted configuration;
- `describe/1` (`Tackle.Runtime.describe_spec/2`) reports the model, thinking
  level, step limit, system prompt, and tool names;
- `llm/1` (`Tackle.Runtime.spec_llm/2`) returns the model client and its
  options, credentials included, for a direct model call outside a run.

`Tackle.Runtime.resolve_profile/2` resolves one of a scope's trusted profiles
by name, as a delegated request does, and `Tackle.Runtime.prepare_spec/2`
applies `prepare_child/2` to a spec, both without starting a run. Backends without a callback return
`{:error, {:unsupported_backend_callback, name}}`, and a raising callback
returns `{:error, {:agent_backend_failed, message}}`.
`Tackle.Runtime.RootBackend` and `Tackle.Runtime.LoopAgent` implement all three.

## Delegated inactivity timeouts

Delegated requests have no total runtime cap. `AgentSpec.timeout`,
`Limits.run_timeout`, and the request's `:timeout` option measure the maximum
interval without child events (five minutes by default). Model steps, streaming
output, tool boundaries, and tool progress renew that interval for foreground
and background runs. A silent model/tool call can still expire the idle window.
Auxiliary events, whose data carries `auxiliary: true` (for example notices from
agent services), are still forwarded but do not renew the interval.
The subagent tool's `timeout_ms` override likewise sets an inactivity window.

Backends must support `:subscribe` before `:submit`: it returns
`{:ok, snapshot}` or `{:error, reason}` and then delivers the agent's events
to the subscribing request as `{:tackle_event, session_id, turn_id, event}`
(`turn_id` is `nil` outside a turn), even when no caller event callback is
provided. Subscription failure settles the request as a setup error; events
are transient, not retained.

The runtime cancels an agent only through the backend's `:cancel` operation:
a request's cancellation calls it directly, and a cancelled branch, run, or
parent calls it from a short-lived process so the scope coordinator never
waits on an agent. Backends need no other cancellation entry point. Explicit `await/2` wait timeouts remain absolute and are separate
from the delegated inactivity timer. Workflows have no runtime limit.

## Process layout

```text
Tackle.AgentSupervisor
└── Tackle.AgentScope
    ├── WorkSupervisor
    ├── Coordinator
    └── Runtime.AgentSupervisor (root)
        ├── Task.Supervisor (tools)
        ├── host backend agent
        └── Runtime.ServiceSupervisor (only with services; temporary)
            ├── Task.Supervisor (service tasks)
            └── backend services
```

Delegated agent subtrees are temporary children of the scope work supervisor
and have the same layout. Stopping a scope terminates the root, descendants,
requests, trusted work children, turn tasks, tool tasks, and agent services.

## Agent services

A backend may implement the optional `services/2` callback to run processes
beside each agent, root and delegated alike, such as a monitor that watches the
agent's tool calls. It receives the agent spec and `AgentContext` and returns
child specs; `[]` (or not implementing the callback) starts nothing.

Services run under a `Tackle.Runtime.ServiceSupervisor` appended after the
backend process, so they start after and stop before the agent. Its first child
is a `Task.Supervisor` named by
`Tackle.Runtime.Registry.service_task_supervisor_name/1` and passed as
`context.service_task_supervisor`, for short-lived asynchronous service work.
Services restart `:one_for_one` up to three times in five seconds. The service
supervisor is a `:temporary` child of the `:one_for_all` agent subtree, so a
crashing service, a service exceeding that bound, a service that fails to start,
or a raising `services/2` callback never stops the agent; the agent simply
continues without the affected services. Services start while the agent
subtree is still starting, after the backend process: a service's `init/1` may
call the running agent (for example to subscribe before its first turn) but
must not call the agent's supervisors.

A service that others need to find can register under
`Tackle.Runtime.Registry.service_name(agent_ref, key)`; `service/2` then
answers whether it runs for that agent, without anyone holding its pid.

Services act on their agent through the public runtime API. For example,
`Tackle.Runtime.cancel_tool_call/3` stops one tool call of the agent's active
turn through the backend's `:cancel_tool_call` operation, so the agent receives
a tool error and continues. Backends without per-call cancellation return
`{:error, {:unsupported_agent_operation, :cancel_tool_call}}`.

`Tackle.Runtime.publish_event/2` lets a service report on its agent outside
any turn, for example a `:narration` status line for a delegated run. It
accepts only auxiliary events (`data.auxiliary == true`, see
`Tackle.Lib.Event.auxiliary?/1`) and returns `{:error, {:invalid_event,
event}}` for anything else. The backend's `:publish_event` operation delivers
the event to the agent's subscribers as `{:tackle_event, session_id, nil,
event}` and never persists it; backends without it return
`{:error, {:unsupported_agent_operation, :publish_event}}`.

## Deployment boundary

The built-in Registry and ownership model are node-local and in-memory. A
multi-node host must provide node affinity or a distributed ownership layer;
this package does not claim cluster-wide process discovery or durable run
retention.
