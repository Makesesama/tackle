# Tackle runtime architecture for subagents, workflows, and fleets

Status: accepted architecture. The scoped runtime and its public facade are implemented; the concrete APIs recorded in section 5.1 describe the shipped behaviour. Boundaries and defaults are decisions rather than alternatives.

Scope: in-memory execution, supervision, subagents, workflows, fleets, inter-agent communication, cancellation, and resource limits. Session persistence, recovery after BEAM shutdown, and distributed execution are explicitly out of scope for this stage.

This document extends the package and harness boundaries in [`architecture-spec.md`](architecture-spec.md) and follows the host/runtime model described in [`../packages/tackle_lib/README.md`](../packages/tackle_lib/README.md). `Tackle.Lib` remains the provider-neutral loop. The root Tackle harness owns runtime composition and orchestration.

## 1. Agreed direction

1. A subagent is an ordinary Tackle agent. It runs the same `Tackle.Lib` loop and uses the same adapter, tool, hook, prompt, state, event, and cancellation contracts as any other agent.
2. Do not add a second loop implementation for subagents, workflows, or fleets.
3. Each agent has its own dedicated GenServer and `%Tackle.Lib.State{}`. An agent GenServer exists only for the lifetime of that agent and is never reset or reused for a different agent.
4. Coding-harness subagents are initially ephemeral, delegated agents: “research this task and return a result.” Long-lived named agents and general-purpose autonomous inboxes are not an initial requirement.
5. Workflows are host-defined coordinators. They are not implicitly agents and do not need an LLM unless a workflow explicitly launches an agent for a step.
6. Fleets are lifecycle, membership, concurrency, and resource-policy boundaries. A fleet is not itself a workflow.
7. Runtime communication initially uses correlated request/reply. General free-form agent chat, broadcast messaging, and durable mailboxes are deferred.
8. Runtime entities are addressed through stable IDs and a Registry. PIDs are internal implementation details.
9. A single model tool batch may execute concurrently when the host opts in with `Tackle.Lib.Tool.Policy` `:concurrent`; the runtime supplies the per-session tool supervisor and the loop still commits results in call order. General parallel orchestration (fan-out, aggregation, fleets) belongs in workflows or explicit batch orchestration, not in a second agent loop.
10. Parent-owned work follows structured cancellation: cancelling a parent
    cancels its attached descendants. A background subagent is explicitly detached
    from the launching turn, but remains owned by the parent session and root scope.
11. Crashed in-memory agents and workflows are not silently restarted as if their state had survived. Crashes are reported as terminal runtime failures.
12. Persistence is not required for this architecture. All agents, workflows, requests, and fleet state may disappear when their owning process or the BEAM terminates.
13. Every top-level agent owns one physical execution scope. The root agent, all of its descendant agents, workflows, and active turn Tasks live in that scope.
14. For the initial coding harness, one root-agent scope is one fleet. A separate fleet process above multiple independent root agents is deferred.
15. Descendant agents do not receive supervisors of their own. They share the root scope's work supervisor while the scope coordinator retains their logical parent/child relationships.

### 1.1 Accepted implementation defaults

The first implementation uses these defaults:

- The CLI's primary agent is created in an explicit root-agent scope with an empty trusted profile allowlist.
- A global DynamicSupervisor owns root-agent scopes; each root-agent scope physically owns one root `Tackle.Session`, one scope coordinator, and one DynamicSupervisor for all descendant work.
- The scope work supervisor owns subagent sessions, workflows, request helpers, and supervised turn Tasks. There is no separate supervisor per subagent or workflow.
- The scope coordinator enforces fleet limits and records logical ownership. It is a control-plane process and does not relay streaming token events.
- Subagent configuration is selected from trusted named profiles resolved by the harness.
- The subagent tool is opt-in initially rather than part of every agent's default tool set.
- Descendant agents cannot create further descendants unless their trusted profile explicitly grants that capability. Spawn-depth and fleet limits apply even when delegation is granted.
- The runtime preserves a child's full terminal outcome internally; the subagent tool projects the appropriate final answer or error into a parent tool result.
- A busy ephemeral child rejects additional work. General-purpose agent inboxes and queues are deferred.
- Fleet concurrency overflow is rejected explicitly in the initial implementation rather than queued.
- Scoped runtime processes are temporary. Lost in-memory state is not restarted or reconstructed.
- Subagents, workflows, scopes, and fleets are root-harness responsibilities. The one library-side capability the runtime relies on is the `:concurrent` tool policy (`Tackle.Lib.Tool.Policy.concurrent/0`) with a host-supplied `:tool_supervisor`. The harness pins concurrency for every session and exposes no tool-policy option; all orchestration above one tool batch stays in the harness.

## 2. Current foundation

The current harness already has the correct basic process split:

```text
frontend
  │
  ▼
Tackle.Session                         temporary GenServer
  ├── owns the settled Tackle.Lib.State
  ├── allows one active turn
  ├── owns subscribers and cancellation
  └── starts a supervised Task
        │
        ▼
      Tackle.Lib.run/3 or continue/2
        │
        ▼
      Tackle.Lib.Loop                  synchronous ReAct loop
        ├── calls the selected LLM adapter
        ├── executes tools
        ├── produces a new immutable State
        └── emits events through a callback
```

`Tackle.Lib.Loop` is synchronous code. It is not a GenServer and should remain independent of OTP runtime policy. The root harness runs each turn as a temporary Task child of the owning scope's `Tackle.AgentScope.WorkSupervisor`; `Tackle.Session` remains responsive while the task performs provider calls and tool execution.

This “one stateful process per agent, one supervised Task per active turn” model is the foundation for subagents. A subagent is another dedicated session process configured for a delegated role.

## 3. Runtime concepts

### 3.1 Agent

An agent is one stateful conversation capable of running turns. Its GenServer owns:

- a stable runtime agent identity;
- one `%Tackle.Lib.State{}`;
- the active turn, if any;
- cancellation ownership;
- subscribers or correlated completion destinations;
- its parent workflow/agent and fleet identity;
- a bounded request queue if queuing is introduced.

Each agent process is dedicated to exactly one agent. When an ephemeral delegated agent returns its result and no further work belongs to it, the runtime stops that agent process. A later subagent request receives a new agent process and new state rather than recycling the old process.

The actual LLM loop must continue to run in a supervised Task. It must not run directly inside the agent GenServer because that would block cancellation, status inspection, message delivery, and lifecycle operations.

### 3.2 Turn or run

A turn is one invocation of `Tackle.Lib.run/3` or `Tackle.Lib.continue/2`. It has:

- a turn/run ID;
- an owning agent ID;
- an optional parent workflow and parent turn;
- a cancellation signal;
- an event stream;
- a terminal outcome;
- request/reply correlation.

A normal library outcome remains one of:

```elixir
{:ok, %Tackle.Lib.State{}}
{:error, %Tackle.Lib.State{}}
{:cancelled, %Tackle.Lib.State{}}
```

A Task or agent-process crash is a distinct runtime failure and must not be represented as a normal library error.

### 3.3 Subagent

A subagent is an ordinary, usually ephemeral agent started to perform a delegated task. The typical lifecycle is:

```text
parent requests delegated work
  → fleet admits the request
  → runtime starts a dedicated child agent
  → child runs one or more turns required by that task
  → child returns a correlated result
  → result is delivered to the requester
  → child agent process stops
```

Subagent configuration is explicit and trusted. A model may select among capabilities made available by the harness, but model-generated data must not name arbitrary modules, supervisor processes, or executable code.

### 3.4 Workflow

A workflow is a deterministic host coordinator for agents and runs. It can implement:

- sequential steps, such as researcher → reviewer → writer;
- parallel fan-out and aggregation;
- conditional retries or escalation;
- bounded debate or review patterns;
- cancellation of outstanding descendants.

A workflow owns workflow state, outstanding request references, accumulated results, and child ownership. It should initially be implemented as a regular GenServer. `:gen_statem` can be considered later if workflows acquire enough explicit states and transitions to justify it.

There is no initial workflow DSL. Host-defined modules and explicit runtime calls are preferable to a speculative general workflow language.

### 3.5 Root-agent scope and fleet

A root-agent scope physically groups one top-level agent and all work originating from it. For the initial coding harness, this scope is also the fleet boundary:

```text
one root agent scope = one fleet
```

The scope owns:

- the root agent;
- all descendant agents and workflows;
- active supervised turn Tasks;
- maximum active agents;
- maximum concurrent turns;
- spawn depth and fan-out limits;
- workflow and run timeouts;
- attached-child cancellation;
- fleet status and inspection data.

The physical process tree under a scope can remain flat while the scope coordinator records a logical tree such as root → researcher → specialist. This logical ownership is required for branch cancellation, depth accounting, per-agent child limits, cycle prevention, and result routing.

A scope or fleet does not run LLM loops and should not relay every streaming event. It is a control-plane and physical cleanup boundary, not a token-event bottleneck. A future fleet containing several independent root-agent scopes may add a higher grouping layer, but that is outside the initial design.

## 4. Supervision architecture

OTP supervision is responsible for process lifecycle, cleanup, and failure isolation. Supervisors do not coordinate workflow state, route every message, or enforce budgets themselves; those responsibilities belong to the scope coordinator and ordinary runtime modules.

The accepted initial process tree is:

```text
Tackle.Supervisor
├── Tackle.Auth.Store
├── Tackle.Runtime.Registry
└── Tackle.AgentSupervisor                 global DynamicSupervisor
    ├── AgentScope A                        Supervisor; one per root agent
    │   ├── ScopeCoordinator                GenServer
    │   ├── Root SessionSupervisor          Supervisor; root agent
    │   │   ├── Task.Supervisor             root tool execution
    │   │   └── Tackle.Session              root agent loop owner
    │   └── WorkSupervisor                  DynamicSupervisor
    │       ├── root turn Task
    │       ├── researcher SessionSupervisor
    │       │   ├── Task.Supervisor         researcher tool execution
    │       │   └── Tackle.Session
    │       ├── researcher turn Task
    │       ├── reviewer SessionSupervisor
    │       ├── workflow process
    │       └── deeper delegated agents
    └── AgentScope B
        └── ...
```

`Tackle.AgentSupervisor` owns root-agent scopes rather than every session directly. All agents, including the CLI root, enter through a scope; there is no global session or turn supervisor and no unscoped session fallback.

Each `AgentScope` is a small static Supervisor containing:

1. the root `Tackle.Session.Supervisor` (which owns the root session and its tool supervisor);
2. the scope coordinator; and
3. one `WorkSupervisor` DynamicSupervisor.

The root session is not itself a supervisor. It runs beneath a small per-session `Tackle.Session.Supervisor` whose sibling is the session's tool `Task.Supervisor`. A GenServer does not start an ad hoc supervisor beneath itself because that reverses normal OTP ownership and makes crash cleanup less reliable; the tool supervisor therefore gets its own supervised parent instead.

Every session — root or descendant — runs under its own `Tackle.Session.Supervisor` so that concurrent tool execution has a dedicated, session-local `Task.Supervisor`. Descendant session supervisors are temporary children of the scope `WorkSupervisor`; the root session supervisor is a static child of `AgentScope`. There is exactly one tool supervisor per agent, so a subagent never shares tool tasks with its parent, and terminating a session subtree cleans up every in-flight tool task for exactly one agent.

`WorkSupervisor` accepts heterogeneous temporary child specifications. It owns descendant `Tackle.Session.Supervisor` subtrees (each session plus its tool supervisor), workflows, request helpers, and turn Tasks. A supervised turn can be started as a temporary `Task` child that sends a correlated terminal result to its owning session; the session monitors it and handles crash outcomes. This removes the need for separate global session, workflow, and Task supervisors while retaining the existing rule that the LLM loop never runs inside a GenServer callback.

Stopping one `AgentScope` physically terminates its root agent, all descendants, workflows, active turn Tasks, and request helpers. No global coordinator has to enumerate and individually terminate every member to clean up the root agent.

### 4.1 Physical and logical ownership

All descendants may be physical siblings under `WorkSupervisor`:

```text
WorkSupervisor
├── researcher
├── reviewer
├── researcher's child
└── workflow
```

The scope coordinator separately records their logical relationships:

```text
root
├── researcher
│   └── researcher's child
└── reviewer
```

Physical supervision provides complete scope cleanup. Logical ownership provides selective branch cancellation, spawn-depth calculation, child limits, cycle detection, authorization, and correlated result routing. It remains necessary even though every process is physically beneath the same root scope.

No descendant agent receives a dedicated scope of its own. If a descendant is allowed to launch another agent, it asks the same root scope to start that agent under the shared `WorkSupervisor` and records itself as the logical parent. What every descendant does receive is a small per-session supervisor owning that agent's session and its tool `Task.Supervisor`; that pair is a single cleanup and failure unit, not a nested scope or workflow boundary.

### 4.2 Scope API

The low-level supervisor API should remain small and PID-free at its public boundary. Conceptually:

```elixir
Tackle.AgentSupervisor.start_agent(root_spec)
Tackle.AgentSupervisor.stop_agent(root_ref)

Tackle.AgentScope.start_child(scope_ref, child_spec)
Tackle.AgentScope.terminate_child(scope_ref, child_ref)
```

Normal callers use higher-level runtime operations instead:

```elixir
Tackle.Runtime.request_agent(parent_ref, agent_spec, prompt)
Tackle.Runtime.start_workflow(parent_ref, workflow_module, input)
Tackle.Runtime.cancel(runtime_ref)
```

The exact function and module names may change during implementation, but the single global scope supervisor and one shared work supervisor per root agent are architectural decisions.

### 4.3 Restart and failure policy

The runtime is intentionally in memory. Restarting an agent or coordinator after it crashes would create an empty process without the state it previously owned. Therefore:

- `AgentScope` is a temporary child of the global `Tackle.AgentSupervisor` and is not restarted after it terminates;
- the root session, scope coordinator, and work supervisor are scope-critical processes;
- failure of a scope-critical process terminates the complete scope instead of reconstructing empty state;
- a per-session supervisor uses `:one_for_all` with no restart allowance: an abnormal exit of a session or its tool supervisor tears the session subtree down instead of reconstructing an empty session;
- a root session or root tool supervisor failure therefore terminates the complete scope, while a descendant session or descendant tool supervisor failure is isolated to that descendant;
- descendant agents, workflows, helpers, and Tasks are temporary dynamic children and are not restarted;
- a descendant failure is reported to its requester and does not terminate unrelated sibling work;
- normal `Tackle.Lib` errors and cancellation are terminal outcomes, not crashes;
- Task crashes and process exits remain distinct runtime failures;
- explicit root close stops the `AgentScope`, not only the root session.

The implementation may enforce critical-child teardown with an appropriate static Supervisor strategy and restart intensity or with explicit monitored shutdown. The required externally observable behavior must be tested: a root/coordinator failure removes the complete scope, while one descendant failure is isolated and reported.

A future persistence design may introduce state reconstruction and different restart policies, but it is not part of this stage.

## 5. Identity and addressing

Runtime APIs should use stable references rather than public PIDs. The identity model should distinguish:

```text
fleet_id
agent_id
workflow_id
turn_id
message_id
correlation_id
```

A future reference may have a shape such as:

```elixir
%Tackle.Runtime.AgentRef{
  fleet_id: "fleet-1",
  agent_id: "agent-2"
}
```

The exact struct and names are deferred. The architectural rules are:

- the Registry maps stable runtime references to live local processes;
- callers do not retain raw PIDs as durable identity;
- stale references produce explicit `:not_found` or terminated outcomes;
- `Tackle.Lib.State.session_id` remains the conversation/provider-cache identity and need not represent fleet, workflow, or parentage;
- events and terminal outcomes carry enough IDs to reject stale or unrelated deliveries.

### 5.1 Implemented public facade

Starting the harness returns a PID-free `Tackle.Runtime.Scope`:

```elixir
%Tackle.Runtime.Scope{
  scope_ref: %Tackle.Runtime.ScopeRef{scope_id: scope_id},
  root_agent_ref: %Tackle.Runtime.AgentRef{scope_id: scope_id, agent_id: agent_id}
}
```

The scope supervisor PID stays below the runtime boundary. `Tackle.AgentSupervisor.start_scope/2` still returns it internally, but `Tackle.Runtime.start_scope/2` and `Tackle.start_scope/1` never expose it.

The root facade exposes only the scoped model:

```elixir
Tackle.start_scope(%ScopeSpec{})        :: {:ok, %Scope{}} | {:error, term()}
Tackle.stop_scope(%ScopeRef{})          :: :ok | {:error, term()}
Tackle.scope_snapshot(%ScopeRef{})      :: {:ok, map()} | {:error, term()}

Tackle.submit(%AgentRef{}, input)       :: {:ok, turn_id} | {:error, term()}
Tackle.continue(%AgentRef{})            :: {:ok, turn_id} | {:error, term()}
Tackle.cancel(%AgentRef{})              :: :ok | {:error, term()}
Tackle.reconfigure(%AgentRef{}, opts)   :: {:ok, %Snapshot{}} | {:error, term()}
Tackle.snapshot(%AgentRef{})            :: {:ok, %Snapshot{}} | {:error, term()}
Tackle.subscribe(%AgentRef{})           :: {:ok, %Snapshot{}} | {:error, term()}
Tackle.unsubscribe(%AgentRef{})         :: :ok | {:error, term()}
Tackle.monitor_agent(%AgentRef{})       :: {:ok, reference()} | {:error, term()}
```

`Tackle.load_config/1` remains the per-agent configuration loader. `Tackle.Runtime.agent_snapshot/1` remains the PID-free coordinator/lifecycle snapshot and is deliberately distinct from the conversation snapshot returned by `Tackle.snapshot/1`.

Frontends hold only `ScopeRef` and `AgentRef` values. `Tackle.monitor_agent/1` centralizes the Registry lookup/monitor race so a frontend can detect crashes without retaining a session PID.

### 5.2 Breaking changes from the PID-oriented facade

This migration is intentionally breaking and retains no compatibility wrapper:

- session-PID startup (`Tackle.start_session/1`, `Tackle.start_configured_session/1`) is replaced by scope startup;
- agent operations address a `Tackle.Runtime.AgentRef`;
- shutdown addresses a `Tackle.Runtime.ScopeRef` through `Tackle.stop_scope/1`;
- `allow_recursion` is renamed `allow_delegation` throughout the root runtime;
- `Tackle.Session.start_child/1`, the unscoped `start_turn_task(nil, fun)` fallback, and the global `Tackle.SessionSupervisor` and `Tackle.TaskSupervisor` are removed.

A session without scoped runtime ownership is an initialization error rather than an implicit global-supervisor fallback. `Tackle.Phoenix.Runner` is unaffected: it does not use the root `Tackle.Session` runtime.

### 5.3 Trusted profiles versus model-selected names

`Tackle.Config` describes exactly one agent loop. `Tackle.Runtime.AgentSpec` is the trusted, resolved description of one runtime agent (name, `Tackle.Config`, per-run timeout, delegation grant). `Tackle.Runtime.ScopeSpec` is the trusted description of one root scope (root `AgentSpec`, trusted profile allowlist, fleet `Limits`).

Model-visible or file-generated data may only select an allowlisted profile *name*. It can never name a module, construct a profile implementation, widen limits, or address a process. File/model configuration that selects a trusted profile name does not, by itself, inject the subagent tool: tool exposure, the `allow_delegation` grant, and a matching trusted profile are three independent controls.

## 6. Inter-agent communication

### 6.1 Initial communication model

The first communication primitive is correlated request/reply. A conceptual runtime envelope is:

```elixir
%Tackle.Runtime.Envelope{
  id: message_id,
  kind: :request | :reply | :signal,
  from: agent_or_workflow_ref,
  to: agent_or_workflow_ref,
  correlation_id: request_id,
  parent_turn_id: parent_turn_id,
  payload: payload
}
```

The exact fields remain a proposal, but the distinctions are required:

- **events** are observational and do not request new work;
- **requests** ask an agent or workflow to perform work;
- **replies** settle one correlated request;
- **signals** carry control operations such as cancellation.

Do not reuse the frontend event-subscriber channel as a command bus.

Useful initial operations are conceptually:

```text
request(agent, input) → run reference
reply(request, result)
cancel(run | workflow | fleet)
```

In addition to correlated request/reply, `Runtime.tell/3` delivers text between
agents in the same scope through a bounded in-memory inbox. Messages become user
messages at the recipient's next turn boundary; inbox overflow is rejected.
There is no broadcast command bus. Durable mailboxes, free-form autonomous chat,
and reconstruction of queued messages after process or BEAM failure remain
deferred.

### 6.2 Routing

A central message-bus GenServer is unnecessary for a local in-memory runtime and would serialize unrelated communication. Routing can be an ordinary module:

```text
runtime reference
  → Registry lookup
  → GenServer call/cast to recipient
```

The routing boundary validates envelope shape, correlation, fleet membership, and allowed operations without becoming a single runtime process through which all events and payloads flow.

### 6.3 Busy agents and queues

The current interactive session rejects overlapping submissions with `:turn_in_progress`. That behavior should not silently change.

Ephemeral subagents are normally dedicated to one delegated request, so they do not initially require general-purpose inboxes. If workflows later target an already-busy agent, the runtime may either:

1. reject the request and let the workflow decide whether to retry; or
2. enqueue it in a separately defined, bounded runtime request queue.

If queuing is added, it must have explicit limits, cancellation behavior, and ordering. It should use a separate API rather than changing the semantics of the existing frontend-facing `submit/2` operation.

## 7. Connecting subagents to an agent turn

Subagent orchestration belongs in the root Tackle harness, not in `Tackle.Lib`. `Tackle.Lib` remains unaware of fleets, parent/child relationships, and workflow policy.

A parent agent can receive subagent capability through a host tool:

```text
parent Tackle.Lib loop
  → subagent tool
  → Tackle runtime
  → start a dedicated child agent
  → submit delegated request
  → await correlated child result
  → return that result as the parent's tool result
  → parent Tackle.Lib loop continues
```

The tool can receive an opaque runtime handle through `Tackle.Lib.State.context`, for example:

```elixir
%{
  runtime: runtime_handle,
  fleet_id: fleet_id,
  agent_id: agent_id,
  workflow_id: workflow_id
}
```

The handle should expose only authorized runtime operations and limits. Model-visible arguments must not include raw PIDs, supervisor names, arbitrary module names, or unrestricted child configuration.

This preserves the boundary described in `packages/tackle_lib/README.md`: parent/child orchestration is a host capability built with tools and runtime state; it is not part of the provider-neutral agent loop.

## 8. Synchronous and parallel delegation

### 8.1 Initial synchronous subagent tool

The simplest initial parent-agent capability is conceptually:

```text
run_subagent(spec, prompt)
  → start child
  → await child result
  → return answer
```

Waiting in the parent turn Task is acceptable on the BEAM; it does not block a scheduler thread. It does consume an active parent turn and therefore requires:

- a timeout;
- cooperative cancellation;
- attached-child cleanup;
- spawn-depth and fan-out limits;
- cycle prevention;
- explicit handling of child error, cancellation, and crash outcomes.

The accepted core runtime API separates request creation from waiting even though the initial model-facing tool remains synchronous:

```text
request_agent(parent, spec, prompt) → run reference
await(run reference, timeout) → correlated outcome
```

The subagent tool performs these operations back-to-back and therefore behaves synchronously from `Tackle.Lib`'s perspective. Workflows can retain several run references and await them independently, which provides one shared primitive for sequential and parallel orchestration independently of how `Tackle.Lib` executes an individual tool batch.

### 8.2 Parallel execution

`Tackle.Lib` executes tool calls sequentially by default. The host may opt a session into `:concurrent` tool execution with `Tackle.Lib.Tool.Policy.concurrent/0`; the runtime then passes the session's own tool `Task.Supervisor` as the `:tool_supervisor` run option. The loop runs every call in one batch as a supervised task and commits results in the model's call order, so the transcript is identical to the sequential one. A tool crash is isolated to its task and surfaces as a tool error; cancelling the turn shuts the batch down.

If a model emits multiple individual subagent tool calls in one batch, those calls can now start their children in parallel under that same policy. That is a property of the batch, not of delegation: subagents themselves remain ordinary agents in the same scope.

Do not build fleets by changing core tool execution policy. Parallel fan-out and aggregation that spans multiple turns, depends on intermediate results, or needs its own failure policy should still happen through either:

1. an explicit batch orchestration tool that starts several child agents concurrently and awaits all results; or
2. a host workflow that starts concurrent child runs, collects correlated outcomes, and launches any aggregation step.

Substantial parallel orchestration belongs in workflows. Concurrent tool execution is limited to one model-requested batch and keeps its concurrency policy explicit and host-owned.

## 9. Agent specifications and trusted configuration

A subagent needs an explicit agent specification describing the configuration the harness may use, including as required:

- model or model-selection policy;
- system prompt or role;
- allowed tools;
- hooks;
- context supplied by the host;
- maximum loop iterations;
- runtime limits and timeout;
- parent/fleet metadata.

The implemented `AgentSpec` carries a trusted `name`, a resolved `Tackle.Config`, an `allow_delegation` grant, a per-run timeout, and `model_source` (`:configured` by default). With `model_source: :parent`, `request_agent/4` reads the requesting agent's current model and thinking level outside the coordinator and re-resolves them against the child's configured adapters before admission. No other options or conversation state are inherited, and existing runs are unchanged. The coding explorer uses this policy so resume and idle root model changes affect subsequent requests. Model-visible tool data cannot set this policy. The configuration policy is:

- the harness constructs executable configuration from trusted modules already present in the running distribution;
- model-generated input may select only a trusted named profile exposed by the host;
- profile resolution produces the actual adapter, model, prompt, tools, hooks, context, and limits;
- the initial subagent tool is opt-in rather than added to every default tool set;
- child profiles do not include the subagent tool unless delegation is explicitly granted;
- a subagent receives a fresh `%Tackle.Lib.State{}` unless an explicit same-agent continuation is requested;
- a child cannot widen its own tools, spawn budget, scope, or runtime permissions;
- credentials remain opaque handles supplied at the adapter boundary.

## 10. Cancellation and ownership

Cancellation is hierarchical by default:

```text
cancel fleet
  → cancel workflows
  → cancel active agent turns
  → discard queued requests
  → stop owned ephemeral agents

cancel workflow
  → cancel outstanding runs
  → stop agents exclusively owned by that workflow

cancel parent turn
  → cancel attached child runs
  → stop attached ephemeral child agents
  → leave explicitly backgrounded child runs active
```

A background subagent is turn-independent rather than scope-independent. It may
outlive the tool task and the root turn that launched it, allowing the same root
session to accept new direction while the child continues. It retains its logical
parent for authorization, result collection, and next-turn completion delivery,
and stopping the root scope still terminates it. Work detached from the parent
session or root scope remains deferred.

Cancellation remains cooperative inside a turn:

- the runtime cancels the existing `Tackle.Lib.Cancellation` signal;
- adapters and long-running tools must observe that signal;
- waiting subagent tools must propagate cancellation to their children;
- the owning runtime process may perform bounded forced Task shutdown during cleanup, as the current session does;
- cancellation-signal storage is cleaned up exactly once at terminal settlement.

Parentage is a logical ownership relationship even when parent and child processes are siblings under the root scope's `WorkSupervisor`. The scope coordinator must maintain and enforce that relationship. Stopping the entire root scope relies on physical supervision; cancelling only one branch relies on this logical ownership graph.

## 11. Resource and recursion limits

`Tackle.Lib.State.max_iterations` limits only one agent's internal LLM/tool loop. It does not bound recursive agent creation. The runtime therefore needs separate limits such as:

```text
max_agents_per_fleet
max_concurrent_turns
max_spawn_depth
max_children_per_agent
max_pending_requests
run_timeout
workflow_timeout
```

Token and monetary budgets may be added later using normalized usage, but they are not required to establish the in-memory process architecture.

Limits must fail explicitly and predictably. A rejected spawn or request becomes a typed tool/workflow result; it must not crash the parent or silently exceed the configured boundary.

The runtime should also prevent obvious wait cycles. The initial ephemeral parent-to-child model naturally forms a tree; requests that would wait on an ancestor should be rejected rather than allowed to deadlock two single-turn agents.

## 12. Event and result flow

Streaming events should follow the shortest useful route:

```text
child turn Task
  → child AgentSession
  → interested frontend/workflow subscriber
```

The scope coordinator should observe lifecycle and terminal accounting events, not every token delta. A workflow normally needs correlated terminal outcomes and selected progress events rather than the full UI stream.

Terminal result delivery must distinguish:

- successful library completion;
- expected library error;
- cooperative cancellation;
- turn Task crash;
- agent process termination;
- timeout;
- fleet or workflow policy rejection.

A parent agent's child result normally returns through its waiting orchestration tool and becomes a linked tool result in the parent's transcript. It should not be injected into the parent conversation as an unrelated user or assistant message.

## 13. Implementation plan

The work is organized as incremental, testable tasks. Each task should preserve existing CLI behavior and avoid modifying `Tackle.Lib` unless implementation discovers a missing provider-neutral extension seam that cannot be supplied by the host.

### Task 1: runtime contracts and stable identities

Define small root-harness types for:

- root scope/fleet references;
- agent references;
- workflow references;
- run references;
- `AgentSpec`;
- fleet limits;
- terminal runtime outcomes.

The identity model must carry the root scope, agent, workflow, run, parent, and correlation identifiers needed by routing and cancellation. Runtime references must not expose PIDs.

Candidate source locations are under `lib/tackle/runtime/`; exact filenames are implementation details.

Acceptance criteria:

- IDs are unique and validated.
- Runtime references can be compared and safely logged without exposing prompt or credential data.
- Invalid and stale references have explicit errors.
- `AgentSpec` uses trusted resolved configuration or a trusted named profile; it cannot accept arbitrary executable modules from model data.
- Public types and functions have useful documentation and specs.

### Task 2: root-agent scope supervision

Add the accepted physical supervision tree:

```text
Tackle.AgentSupervisor
└── AgentScope
    ├── ScopeCoordinator
    ├── Root Tackle.Session
    └── WorkSupervisor
```

Add `Tackle.Runtime.Registry` to the application tree. Register scopes and runtime entities by stable identity. Provide the minimal low-level operations to start and stop a root-agent scope and to start temporary work within it.

The work supervisor must support descendant sessions, workflows, request helpers, and supervised turn Tasks. Root-scope shutdown must physically terminate all of them.

Acceptance criteria:

- Starting a root agent creates exactly one scope and one shared work supervisor.
- Stopping a root reference terminates every process in that scope.
- Two root agents are isolated in different scopes.
- No supervisor is created for an individual subagent or workflow.
- A critical root-session, coordinator, or work-supervisor crash tears down the scope without restarting empty state.
- A temporary descendant crash does not terminate an unrelated sibling.
- Registry entries disappear when their processes terminate.

### Task 3: make `Tackle.Session` scope-aware

Keep `Tackle.Session` as the only stateful agent GenServer. Extend its start options and state with:

- `AgentRef` and root scope reference;
- optional logical parent agent, workflow, and run;
- `:explicit` or `:ephemeral` lifetime;
- a terminal result destination and correlation ID;
- the scoped work-supervisor reference;
- coordinator/owner monitoring.

Scoped turn execution moved from the former global `Tackle.TaskSupervisor` to temporary Task children under the root scope's `WorkSupervisor`. The existing event and Task-crash handling semantics are preserved.

An explicit root session remains alive until the root scope is closed. An ephemeral descendant delivers its correlated terminal outcome and is then terminated. Every descendant starts with a fresh `%Tackle.Lib.State{}` and is never reset for another identity.

Acceptance criteria:

- Agent operations address an `AgentRef`; scope shutdown addresses a `ScopeRef`; no frontend operation requires a session PID.
- Existing one-active-turn enforcement remains unchanged.
- A terminal destination is installed before submission, eliminating subscription/result races.
- Ephemeral agents terminate after delivering their result.
- Turn Tasks are killed when their containing root scope stops.
- Task crashes remain distinct from `Tackle.Lib` error outcomes.
- Existing root and CLI session tests continue to pass.

### Task 4: scope coordination and fleet limits

Implement `ScopeCoordinator` as the fleet control plane for one root-agent scope. It records:

- live agents, workflows, and runs;
- logical parent/child relationships;
- active-turn and child counts;
- spawn depth;
- cancellation state;
- configured resource limits;
- monitors and terminal accounting.

Admission must be serialized by the coordinator so concurrent spawn requests cannot exceed limits. The initial behavior rejects excess concurrency rather than maintaining a queue.

Initial required limits are:

```text
max_agents_per_fleet
max_concurrent_turns
max_spawn_depth
max_children_per_agent
max_pending_requests
run_timeout
workflow_timeout
```

`max_pending_requests` may initially be zero beyond immediately admitted work because busy-agent queues are deferred.

Acceptance criteria:

- Concurrent admission cannot oversubscribe a limit.
- Agent and turn exits release accounting exactly once.
- Parent and depth metadata is inherited rather than trusted from child input.
- The coordinator monitors members and removes stale entries.
- Streaming deltas do not pass through the coordinator.
- Limit rejection is a typed runtime outcome rather than a process crash.

### Task 5: correlated delegated request/reply

Implement the shared primitive used by both tools and workflows. Conceptually:

```elixir
{:ok, run_ref} =
  Tackle.Runtime.request_agent(parent_ref, agent_spec, prompt)

{:ok, outcome} = Tackle.Runtime.await(run_ref, timeout)
```

The request path must:

1. resolve and authorize the parent scope;
2. ask the coordinator to admit the descendant;
3. start one fresh ephemeral `Tackle.Session` under `WorkSupervisor`;
4. establish terminal delivery before submitting the prompt;
5. return a stable run reference;
6. deliver one correlated terminal outcome;
7. stop the ephemeral session and release accounting.

The internal outcome distinguishes at least:

```elixir
{:ok, agent_state}
{:error, agent_state}
{:cancelled, agent_state}
{:runtime_error, reason}
{:timeout, reason}
{:rejected, reason}
```

The implemented `Tackle.Runtime.Outcome` carries the status, the settled agent state for library settlements, a reason for runtime failures, and the owning agent reference.

Acceptance criteria:

- Several concurrent requests cannot consume each other's results.
- A fast child cannot finish before terminal routing exists.
- Timeout cancels and cleans up the child.
- Requester death cleans up attached work.
- A child Task crash, agent crash, normal agent error, cancellation, timeout, and admission rejection remain distinguishable.
- No child process or Registry entry remains after settlement.

### Task 6: structured cancellation

Implement cancellation across the logical ownership graph while retaining physical root-scope cleanup:

```text
cancel root scope
  → stop the complete AgentScope

cancel workflow or parent run
  → cancel its attached runs
  → stop its exclusively owned ephemeral agents

cancel one descendant
  → cancel that agent's turn
  → cancel its attached descendants
```

Waiting orchestration code must observe the parent's existing `Tackle.Lib.Cancellation` signal and promptly propagate it to child runs. Cancellation-signal cleanup remains exactly-once. Bounded forced Task shutdown remains available when provider or tool code fails to cooperate.

Acceptance criteria:

- Parent cancellation reaches all attached descendants.
- Cancelling one branch does not stop unrelated siblings.
- Scope shutdown terminates every scoped Task even during an active provider or tool operation.
- A child cannot publish a stale success after its request was cancelled or timed out.
- Repeated cancellation is idempotent.
- Parent Task and workflow crashes trigger descendant cleanup.

### Task 7: opt-in subagent tool

Add a root-harness tool, `Tackle.Tools.Subagent`, with a narrow model-visible schema such as:

```text
profile: trusted profile name
task: delegated prompt
```

The tool receives an opaque runtime handle through `Tackle.Lib.State.context`, resolves the selected profile through a trusted host allowlist, calls `request_agent`, awaits the result, and returns the child's answer or typed failure as the parent's linked tool result.

The tool is not part of `Tackle.Tools.default/0` initially. The coding root also
receives `Tackle.Tools.SubagentStatus`: setting `background: true` on a subagent
call returns a stable run ID immediately, and the status tool polls or consumes
the retained outcome. Completion is queued in the parent's bounded next-turn
inbox and published as a `:subagent_finished` event. Background requests are
owned by the logical parent session rather than the short-lived tool task, but
remain attached to structured parent and scope cancellation. A child profile
does not receive delegation tools unless recursive delegation is explicitly
granted.

Acceptance criteria:

- A fake parent adapter can call the tool, receive a fake child answer, and continue its own loop.
- Parent and child have different agent identities and independent states.
- The child answer is represented as a tool result, not injected as an unrelated conversation message.
- Unknown profiles and exhausted limits produce expected tool errors.
- Parent cancellation reaches a child while the tool is waiting.
- The ephemeral child exits after returning its result.

Completion of Tasks 1–7 is the first useful vertical slice:

```text
root agent
  → subagent tool
  → scope admission
  → fresh ephemeral child
  → supervised child turn
  → correlated result
  → child termination
  → parent loop continuation
```

### Task 8: host-defined workflows

Add a small workflow process contract under the root harness. A workflow owns its state, outstanding run references, accumulated results, and failure policy. It uses the same request/reply primitive as the subagent tool.

The contract should support initialization, correlated result handling, failure handling, and cancellation. Begin with regular GenServers; do not introduce a workflow DSL or `:gen_statem` without demonstrated complexity.

Add deterministic test workflows for:

1. researcher → reviewer → writer;
2. parallel researchers → aggregator.

Acceptance criteria:

- Sequential outcomes feed later steps explicitly.
- Parallel child runs actually overlap.
- Results remain correctly correlated regardless of completion order.
- Child failure follows explicit workflow policy.
- Workflow cancellation cancels every outstanding attached run.
- A completed or failed workflow terminates and releases scope accounting.

### Task 9: explicit parallel and batch orchestration

Provide host-side helpers for parallel fan-out across delegated runs. These orchestrate several agents over multiple turns; they are independent of how one `Tackle.Lib` tool batch executes. Conceptually:

```elixir
request_many(parent_ref, requests)
await_many(run_refs, timeout)
```

A future batch tool may wrap these helpers, but workflows are the initial consumer.

Acceptance criteria:

- Parallel requests obey scope concurrency and agent limits.
- Overflow is rejected explicitly rather than silently queued.
- Results preserve unambiguous run correlation and documented ordering.
- Partial error, cancellation, and timeout behavior is deterministic.
- Cancelling the aggregate operation cancels all still-attached runs.

### Task 10: recursive-delegation and deadlock protection

Recursive delegation means an explicitly authorized child profile also has the subagent capability. It remains disabled by default. When enabled, every descendant is placed under the same root scope and receives inherited, non-increasing limits.

Implement:

- spawn-depth propagation;
- maximum children per agent;
- maximum total agents and active turns;
- ancestor-cycle rejection;
- bounded request waits;
- prevention of privilege or budget widening.

Acceptance criteria:

- A child without recursive permission cannot request another child.
- An authorized child can delegate within the configured depth.
- A request beyond maximum depth is rejected as an expected runtime/tool error.
- A child cannot increase inherited tools, limits, or scope permissions.
- Requests that would wait on an ancestor are rejected rather than deadlocked.

### Task 11: inspection and lifecycle events

Add PID-free inspection operations such as:

```elixir
Tackle.Runtime.scope_snapshot(scope_ref)
Tackle.Runtime.agent_snapshot(agent_ref)
Tackle.Runtime.workflow_snapshot(workflow_ref)
```

Snapshots should include status, logical ownership, active run, child and outstanding-request counts, limits, and cancellation state. Emit bounded lifecycle events or telemetry for scope, agent, run, workflow, cancellation, timeout, and admission-rejection transitions.

Do not include prompts, results, tool arguments, credentials, or unrestricted context in inspection metadata.

Acceptance criteria:

- Snapshots remain internally consistent during concurrent activity.
- Stale references return explicit errors.
- Lifecycle instrumentation does not receive token deltas.
- Sensitive request and credential data is absent.

### Task 12: compatibility, documentation, and full validation

Migrate the root `Tackle` facade and CLI to create the primary agent in an implicit default scope while preserving their user-facing behavior. Keep the CLI thin; fleet visualization is not required initially.

Update this document and relevant README/API documentation with implemented module names and any deliberately changed details. Distinguish working behavior from later plans.

Validation for the affected root project must include:

```sh
mix compile --warnings-as-errors
mix test
mix format --check-formatted

git diff --check
git status --short
```

If a public `Tackle.Lib` contract unexpectedly changes, also run the library and Phoenix integration checks required by `AGENTS.md`. The expected implementation should not require such a change.

Acceptance criteria:

- Existing CLI one-shot and interactive behavior remains functional.
- Existing root tests pass alongside the new runtime tests.
- Public runtime behavior is documented.
- The implementation adds no provider-specific behavior to the root runtime or `Tackle.Lib`.
- No dependency, persistence mechanism, or distributed runtime assumption is introduced.

### 13.1 Dependency order

The required implementation order is:

```text
contracts and identities
  → root-agent scope supervision
  → scope-aware Tackle.Session
  → scope coordinator and admission
  → request/reply primitive
  → structured cancellation
  → subagent tool
  → workflows
  → batch orchestration
  → recursive-delegation hardening
  → inspection and compatibility work
```

Workflows and model-visible tools must not implement private child-launch mechanisms; both wait for and reuse the shared request/reply primitive.

### 13.2 Testing priorities

The highest-risk behavior should be tested before adding workflow convenience APIs:

1. terminal result setup versus a child that finishes immediately;
2. scope shutdown during an active turn;
3. parent cancellation while blocked awaiting a child;
4. descendant Task and AgentSession crashes;
5. concurrent admission at exact resource limits;
6. stale result arrival after timeout or cancellation;
7. descendant cleanup after requester or coordinator failure;
8. root-scope isolation when another root scope fails.

Tests should use deterministic fake adapters and tools. They must not require provider credentials, live model calls, sleeps for synchronization where monitors or explicit barriers are possible, or external services.

## 14. Architectural invariants

The runtime is correctly shaped when all of the following remain true:

- There is exactly one provider-neutral agent loop: `Tackle.Lib.Loop`.
- A subagent is an ordinary Tackle agent with its own dedicated process and state.
- `Tackle.Session` remains the single stateful agent GenServer; supervised Tasks execute turns.
- Each top-level agent has one physical root scope, and that scope is the initial fleet boundary.
- A root session, coordinator, and shared work supervisor are siblings under the scope Supervisor.
- All descendants, workflows, helpers, and turn Tasks are temporary children within that root scope.
- No supervisor is created for each subagent or workflow.
- Physical supervision provides complete root-scope cleanup; logical ownership provides selective branch operations.
- A dedicated ephemeral agent stops after its delegated task and is never reused for another agent.
- Workflows coordinate agents but do not become a second loop implementation.
- The scope coordinator enforces lifecycle and resource policy without becoming an event bottleneck.
- Stable IDs and Registry lookup form the public in-memory addressing model.
- Correlated request/reply is distinct from observational events.
- Tools and workflows share the same request/reply runtime primitive.
- Parallelism is explicit in workflow or batch orchestration.
- Parent cancellation reaches attached descendants.
- Recursive delegation is opt-in and bounded independently from per-agent loop iterations.
- In-memory crashes are reported honestly rather than hidden by empty-state restarts.
- Provider, tool, and frontend concerns remain behind their existing package boundaries.

## 15. Deferred decisions

The following are intentionally deferred:

- persistence schemas and serialization;
- reconstruction after process or BEAM failure;
- distributed process discovery and cross-node messaging;
- a fleet containing several independent root-agent scopes;
- durable workflow execution;
- durable/replayable inboxes and queues;
- long-lived named-agent semantics;
- broadcast messaging;
- a workflow DSL;
- detached background work outside the implemented logical-parent ownership policy;
- token and monetary fleet budgets;
- additional public API signatures and module names beyond the implemented scoped facade.

These deferrals must not weaken the accepted in-memory boundaries: ordinary dedicated Tackle agents, one physical execution scope per root agent, host-owned workflows, scope-enforced limits, stable addressing, correlated request/reply, and structured cancellation.
