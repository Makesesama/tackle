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
without an inbox rejects `:deliver`; the Phoenix backend currently does so
instead of acknowledging an undelivered message.

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
`Tackle.Phoenix` provides `Tackle.Phoenix.RuntimeBackend`, which executes every
root and child turn through `Tackle.Phoenix.Runner` and the host's
`Tackle.Phoenix.Store` callbacks.

## Per-request model selection

`Tackle.Runtime.request_agent/4` accepts `model: "provider/model"` to override a
child's model for one run; the subagent tool exposes it as its optional `model`
argument. The runtime checks it is a non-empty string and passes it, after
`prepare_child/2`, to the backend's optional `select_model/2` callback, which
must resolve it only against the child's trusted configuration. Backends that
do not implement `select_model/2` refuse such requests with
`{:error, {:model_selection_unsupported, model}}` before admission.
`Tackle.Runtime.RootBackend` implements it; `Tackle.Phoenix.RuntimeBackend`
currently does not.

## Delegated inactivity timeouts

Delegated requests have no total runtime cap. `AgentSpec.timeout`,
`Limits.run_timeout`, and the request's `:timeout` option measure the maximum
interval without child events (five minutes by default). Model steps, streaming
output, tool boundaries, and tool progress renew that interval for foreground
and background runs. A silent model/tool call can still expire the idle window.
Auxiliary events, whose data carries `auxiliary: true` (for example notices from
agent services), are still forwarded but do not renew the interval.
The subagent tool's `timeout_ms` override likewise sets an inactivity window.

Backends must support `:subscribe` before `:submit` and deliver child events to
the subscribing request, even when no caller event callback is provided.
Subscription failure settles the request as a setup error; events are transient,
not retained. Explicit `await/2` wait timeouts remain absolute and are separate
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

## Deployment boundary

The built-in Registry and ownership model are node-local and in-memory. A
multi-node host must provide node affinity or a distributed ownership layer;
this package does not claim cluster-wide process discovery or durable run
retention.
