# Tackle.Workflow

`Tackle.Workflow` runs **Lua-scripted workflows** on top of
[`Tackle.Runtime`](../tackle_runtime/README.md). A host — or an agent acting
for a user — describes a flow ("scout, then plan, then implement, then
review, then fix the review", or "spawn agents until the goal is done"), and
the flow is expressed as ordinary Lua code that the sandboxed
[`lua`](https://hex.pm/packages/lua) VM executes inside the scope.

```text
tackle_lib
    ↑
tackle_runtime
    ↑
tackle_workflow
```

Workflows are a *front-end* to the runtime's existing primitives: every
`tackle.spawn` goes through the same allowlisted profiles, admission limits,
spawn depth, and cancellation as the subagent tool. A workflow is deterministic,
auditable, and re-runnable in a way "the model orchestrates in its head" is not.

## The workflow surface

Workflows call the `tackle` table (`Tackle.Workflow.API`):

* `tackle.spawn(profile, prompt)` — starts one delegated run and returns an
  opaque run handle immediately, so several spawns overlap;
* `tackle.await(run)` — blocks the workflow until the run settles and returns
  `{ok, status, text}`; expected failures are returned, never raised, so the
  workflow owns the failure policy;
* `tackle.parallel(items, fn, opts)` — bounded fan-out: one delegated run per
  item, at most `limit` in flight, one result table per item in input order;
* `tackle.cancel(run, reason)` — cooperative cancellation of one run;
* `tackle.log(message)` — progress reporting to the host's log callback.

A review loop:

```lua
local findings = tackle.await(tackle.spawn("scout", "Map the code paths."))
local plan     = tackle.await(tackle.spawn("planner", "Plan: " .. findings.text))
local impl     = tackle.await(tackle.spawn("worker", "Implement: " .. plan.text))

local review = tackle.await(tackle.spawn("reviewer", "Review the change."))
while not review.ok do
  impl   = tackle.await(tackle.spawn("worker", "Fix: " .. review.text))
  review = tackle.await(tackle.spawn("reviewer", "Re-review the change."))
end

return review.text
```

Fan-out is bounded and explicit. `tackle.parallel/2,3` calls a callback once
per item and asks it for that item's `profile, prompt`:

```lua
local answers = tackle.parallel(pull_requests, function(pull, index)
  return "reviewer", index .. ". Review " .. pull.title
end, {limit = 3})

for _, answer in ipairs(answers) do
  if answer.ok then
    tackle.log(answer.text)
  end
end
```

* At most `limit` runs are in flight, and a settled run hands its slot to the
  next item immediately, so a slow run does not idle the whole fan-out.
* `items` must be a sequence table numbered 1..n with no holes and no other
  keys.
* The limit defaults to the scope's concurrency ceiling — the smaller of its
  `max_children_per_agent` and `max_concurrent_turns` limits — and is clamped
  to it: a workflow cannot widen its own concurrency by asking for more.
* Every item produces exactly one table in input order —
  `{index = 2, ok = true, status = "ok", text = "..."}`. `status` is the run's
  outcome status, or `"callback_error"` when the callback raised or returned
  something other than two strings, `"spawn_error"` when the runtime refused
  the spawn on policy (an unknown profile, a spawn-depth limit, delegation
  not allowed), `"capacity"` when the scope stayed at its concurrency limit
  for as long as the fan-out is willing to wait, and `"unavailable"` when a
  settled run's outcome could not be collected.
* The runtime refuses rather than queues at capacity, so a refusal is not
  final: the fan-out waits briefly for a slot released a moment after its
  settlement (or for one of its own runs to settle in the meantime) and retries.
  It reports `"capacity"` only after roughly 250 ms without progress, so a
  `"capacity"` item may well succeed in a later call.
* Item failures are returned, never raised, and runs are never retried: a
  retried agent run is a second paid model call that may answer differently.
  The workflow decides what to do with a failed item.

Overlapping spawns remain available directly when the workflow needs finer
control:

```lua
local a = tackle.spawn("researcher", "Topic A")
local b = tackle.spawn("researcher", "Topic B")
local first = tackle.await(a)
local second = tackle.await(b)
```

## Running a workflow

```elixir
{:ok, ref} = Tackle.Workflow.run(handle, script, timeout: :timer.minutes(10))
Tackle.Workflow.await(ref, 30_000)
#=> {:ok, ["final review text"]}
```

`run/3` starts one temporary runner under the scope work supervisor and
returns a stable `Tackle.Workflow.Ref`. `await/2` waits for the settled result:
`{:ok, values}` — the values the workflow returned — or `{:error, reason}` for
workflow errors, cancellation, and timeouts. `cancel/2` stops the workflow and
its runs. Stopping the scope tears everything down.

Two options narrow a workflow beyond its parent's grants. `:profiles` is an
explicit allowlist of the profile names the workflow may spawn; without it, the
scope's own trusted profiles decide. `:owner` is a PID whose lifetime the
workflow shares, so a request that goes away does not leave delegated runs
behind:

```elixir
{:ok, ref} =
  Tackle.Workflow.run(handle, script,
    profiles: ["scout", "worker"],
    owner: task_pid
  )
```

## Running a workflow from an agent

`Tackle.Workflow.Tool` is the model-facing surface of the same runner: an opt-in
`Tackle.Lib.Tool` named `run_workflow` that an agent calls with Lua source. The
host grants it like any other trusted tool and, optionally, narrows the
profiles workflows may spawn:

```elixir
{:ok, spec} =
  Tackle.Coding.scope_spec(
    root_tools: [Tackle.Workflow.Tool],
    overrides: [context: %{workflow_profiles: ["scout", "worker"]}]
  )
```

* The tool needs the same runtime handle and delegation grant as the `subagent`
  tool; without either it returns a model-facing refusal instead of running.
* `:workflow_profiles` is *host* configuration, never workflow input, and it can
  only narrow what the scope already allows. Model-visible data can therefore
  never widen delegation. Without it, the scope's trusted profiles decide — the
  same set `subagent` can already name.
* The values the workflow returns are the tool result, one per line. A sequence
  table such as `return {a, b}` gives one line per element, like `return a, b`;
  any other table — `{ok = true, text = "..."}`, or a table nested in a
  sequence — is rendered as JSON. NaN becomes `null` inside JSON, keys that would
  collide as JSON strings (`1` and `"1"`) fall back to Elixir's `inspect/1`, and
  functions and userdata become `<function>` and `<userdata>` placeholders.
* Workflow errors, rejected
  spawns, cancellations, and deadline timeouts are returned as readable
  messages the agent can act on.
* The tool call owns the workflow: the workflow is cancelled when the call ends
  (including a cancelled turn, where the harness runs the tool body in its own
  supervised process) and when it exceeds the session's `workflow_timeout`.
* Workflow-spawned runs are not yet reported as `subagent_*` progress events, so a
  long workflow is opaque to a frontend beyond its tool call; `tackle.log/1` falls
  back to the host's `Logger`.

## Guarantees

* **Sandboxed.** The pure-Elixir Lua 5.3 VM runs with the default sandbox: no
  file system, no network, no `os.execute`, no `require`/`load`. A
  deterministic instruction budget (default 1,000,000 VM instructions,
  overridable) stops spin loops that never await.
* **Bounded.** The workflow runs under an absolute deadline (default: the
  parent's `workflow_timeout` limit). `tackle.parallel/3` keeps at most the
  scope's concurrency ceiling in flight, clamped to the requested `limit`.
  Cancellation kills the workflow process tree; the runtime cancels every run
  the workflow owns, however the workflow ends.
* **Authorized.** A workflow may only delegate as far as its parent may: the
  runner builds its handle from the parent agent's effective grants, exactly
  as the subagent tool does. An explicit `:profiles` allowlist can
  only narrow that further, so a host can hand out workflow delegation without
  handing out every profile the session has.
* **Fail-fast with policy hooks.** Argument errors and rejected spawns raise
  catchable Lua errors with source lines (`pcall`), while settled failures
  arrive as outcome tables the workflow can branch on. `tackle.parallel` is the
  one exception: argument errors raise, but a spawn the runtime refuses is
  reported on the item it belongs to.

## Placement

This package is optional for hosts: neither the harness nor the web app depends
on it at runtime. (The harness's own test suite has a test-only dependency, to
prove that a real session can grant and run this tool.) The CLI bundles it and
grants `run_workflow` to the root agent alongside the subagent tools; named
profiles only get the tool by listing it explicitly. Hosts that want scripted flows
add `:tackle_workflow` and either call `Tackle.Workflow.run/3` with a handle from
their own runtime integration, or grant `Tackle.Workflow.Tool` to a session's root
agent.