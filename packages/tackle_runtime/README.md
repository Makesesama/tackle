# Tackle.Runtime

`Tackle.Runtime` is the optional OTP orchestration layer above
[`Tackle.Lib`](../tackle_lib/README.md). It provides scoped agent supervision,
stable PID-free references, admission limits, cancellation, subagents,
background runs, fan-out, and workflows without depending on Phoenix or the
root developer harness.

```text
tackle_lib
    ↑
tackle_runtime
   ↗       ↖
tackle   tackle_phoenix
```

## Responsibilities

The runtime owns:

- root scopes and logical parent/child ownership;
- per-agent tool `Task.Supervisor` processes;
- concurrency, depth, and child limits;
- delegated request/await/collect/cancel lifecycle;
- workflow processes and generic subagent tools.

A host backend owns:

- construction of the concrete agent process;
- authorization, quota, persistence, and billing;
- turn submission, cancellation, snapshots, and event delivery;
- backend-specific parent configuration inheritance;
- durable background notifications.

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

## Process layout

```text
Tackle.AgentSupervisor
└── Tackle.AgentScope
    ├── WorkSupervisor
    ├── Coordinator
    └── Runtime.AgentSupervisor (root)
        ├── Task.Supervisor (tools)
        └── host backend agent
```

Delegated agent subtrees are temporary children of the scope work supervisor.
Stopping a scope terminates the root, descendants, requests, workflows, turn
tasks, and tool tasks.

## Deployment boundary

The built-in Registry and ownership model are node-local and in-memory. A
multi-node host must provide node affinity or a distributed ownership layer;
this package does not claim cluster-wide process discovery or durable run
retention.
