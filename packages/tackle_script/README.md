# Tackle.Script

`Tackle.Script` runs **Lua-scripted agent workflows** on top of
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
tackle_script
```

Scripts are a *front-end* to the runtime's existing primitives: every
`tackle.spawn` goes through the same allowlisted profiles, admission limits,
spawn depth, and cancellation as the subagent tool and host-defined
`Tackle.Runtime.Workflow` modules. A script is deterministic, auditable, and
re-runnable in a way "the model orchestrates in its head" is not.

## The script surface

Scripts call the `tackle` table (`Tackle.Script.API`):

* `tackle.spawn(profile, prompt)` — starts one delegated run and returns an
  opaque run handle immediately, so several spawns overlap;
* `tackle.await(run)` — blocks the script until the run settles and returns
  `{ok, status, text}`; expected failures are returned, never raised, so the
  script owns the failure policy;
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

Fan-out is sequential Lua with overlapping runs, because `spawn` returns
before the agent finishes:

```lua
local a = tackle.spawn("researcher", "Topic A")
local b = tackle.spawn("researcher", "Topic B")
local first = tackle.await(a)
local second = tackle.await(b)
```

## Running a script

```elixir
{:ok, ref} = Tackle.Script.run(handle, script, timeout: :timer.minutes(10))
Tackle.Script.await(ref, 30_000)
#=> {:ok, ["final review text"]}
```

`run/3` starts one temporary runner under the scope work supervisor and
returns a stable `Tackle.Script.Ref`. `await/2` waits for the settled result:
`{:ok, values}` — the values the script returned — or `{:error, reason}` for
script errors, cancellation, and timeouts. `cancel/2` stops the script and
its runs. Stopping the scope tears everything down.

## Guarantees

* **Sandboxed.** The pure-Elixir Lua 5.3 VM runs with the default sandbox: no
  file system, no network, no `os.execute`, no `require`/`load`. A
  deterministic instruction budget (default 1,000,000 VM instructions,
  overridable) stops spin loops that never await.
* **Bounded.** The script runs under an absolute deadline (default: the
  parent's `workflow_timeout` limit). Cancellation kills the script process
  tree; the runtime cancels every run the script owns, however the script
  ends.
* **Authorized.** A script may only delegate as far as its parent may: the
  runner builds its handle from the parent agent's effective grants, exactly
  like `Tackle.Runtime.start_workflow/4`.
* **Fail-fast with policy hooks.** Rejected spawns raise catchable Lua
  errors with source lines (`pcall`), while settled failures arrive as
  outcome tables the script can branch on.

## Placement

This package is optional; nothing in the harness, CLI, or web app depends on
it. Hosts that want scripted flows add `:tackle_script` and call
`Tackle.Script.run/3` with a handle from their own runtime integration.