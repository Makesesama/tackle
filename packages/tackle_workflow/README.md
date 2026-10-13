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

* `tackle.spawn(profile, prompt, opts?)` — starts one delegated run and returns
  an opaque run handle immediately, so several spawns overlap. The optional
  `opts` table `{model = "provider/model"}` overrides the profile's model for
  that run; the host resolves it only against models it already makes
  available;
* `tackle.await(run)` — blocks the workflow until the run settles and returns
  `{ok, status, text, tokens, tool_calls, failed_tool_calls}`; expected
  failures are returned, never raised, so the workflow owns the failure policy;
* `tackle.parallel(items, fn, opts)` — bounded fan-out: one delegated run per
  item, at most `limit` in flight, one result table per item in input order;
  the callback returns `profile, prompt, opts?` with the same `opts` table;
* `tackle.cancel(run, reason)` — cooperative cancellation of one run;
* `tackle.classify(state, questions, opts?)` — asks a host-granted decision
  model typed questions about a string or table (see
  [Classification](#classification));
* `tackle.budget()` — the workflow's token accounting, `{used, limit,
  remaining}` (see [Run facts and token budget](#run-facts-and-token-budget));
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
  for as long as the fan-out is willing to wait, `"budget_exhausted"` when the
  workflow's token budget was used up before the item started, and
  `"unavailable"` when a settled run's outcome could not be collected. Every
  item carries run facts, zeros for an item that never started a run, except
  an `"unavailable"` item.
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

## Run facts and token budget

Every outcome table carries facts the harness recorded while the run worked,
counted from the run agent's own `:step_end`, `:usage`, `:tool_end`, and
`:tool_error` events (`Tackle.Workflow.Meter`), not reported by the agent:

* `tokens` — model tokens the run reported;
* `tool_calls` — tool calls the run settled;
* `failed_tool_calls` — how many of those failed.

A workflow can check a run's claims against them: a round that says it made
progress but called no tools changed nothing. Tokens are counted while runs
work, including runs that fail, time out, or are never awaited. Delegation
inside a run is not counted; it reports to that run, not to the workflow.

`:token_budget` limits what all of one workflow's runs may spend together:

```elixir
{:ok, ref} = Tackle.Workflow.run(handle, script, token_budget: 500_000)
```

`tackle.budget()` returns `{used = n}`, plus `limit` and `remaining` under a
budget. Once `used` reaches `limit`, `tackle.spawn` raises a catchable error and
`tackle.parallel` reports `"budget_exhausted"` for items it has not started.
Runs already in flight finish rather than being cut off mid-edit, so a workflow
can overshoot by what those runs spend (with `tackle.parallel`, up to `limit`
runs at once); scripts keep a reserve and stop starting new work before
`remaining` reaches zero. A streaming model call reports usage more than once,
so tokens are counted once per settled model call (`:step_end`).

Facts and budget depend on the agent backend delivering a run's events before
its terminal result, as `Tackle.Session` and the Phoenix runtime backend do.

These are the pieces of a *goal loop*: a script that pursues one objective
over many fresh worker rounds, stops as blocked when the facts show no
progress, has an independent reviewer audit any claim of completion, and ends
as `budget_limited` when an open-ended goal runs out of budget. The workflow
skill guide (`lib/tackle/workflow/skill/SKILL.md`, "Goal loops") documents the
pattern with a complete script that the test suite runs against fake agents.

## Classification

`tackle.classify(state, questions, opts?)` asks a small decision model
(`Tackle.Lib.Decision`) typed questions about a state, for judgements too
cheap to spend a delegated run on:

```lua
local c = tackle.classify(review.text, {
  verdict = {type = "choice", instructions = "Does the review approve the change?",
             criteria = {approve = "No blocking findings", revise = "Blocking findings"}},
  tests = {type = "noul", instructions = "Does the review mention missing tests?"}
})
if c.ok and c.answers.verdict.choice == "approve" then ... end
```

Questions are `choice`, `noul` (yes/no), or `score`; `Tackle.Workflow.Classify`
documents their specs and answer tables. The result is `{ok, status, model,
tokens, answers}`; a model that cannot answer returns `ok = false` with the
reason in `text`, and argument errors, an unknown model, or a session without
decision models raise. `opts` may set `model` (below) and `label`, a short
name for the call in the host's progress view:

```lua
local c = tackle.classify(review.text, questions, {label = "review gate"})
```

The host grants decision models with the `:decisions` option, a
`Tackle.Workflow.Decisions` grant: trusted providers (`Tackle.Lib.LLM.Provider`
structs, or adapter modules standing for their default providers), the options
passed to every decision call, and an optional default model. A script's
`{model = "provider/model"}` can only select a model those providers offer:

```elixir
Tackle.Workflow.run(handle, script,
  decisions: [providers: providers, options: [receive_timeout: 10_000],
              default_model: "ollama/tev1:4b"]
)
```

Classification tokens count against `:token_budget` like a run's, unless the
selected provider declares its decision models local
(`Tackle.Lib.Decision.local?/1` or `local?/0`, as a local Ollama provider does): a local
classification reports `tokens = 0`, never changes `tackle.budget()`, and still
runs once the budget is spent. A remote one is refused like `tackle.spawn`
when the budget is spent, and counts the tokens its adapter reports: a call
that fails before the model answers, or an adapter that reports no usage,
adds nothing.

## Observing progress

`:on_event` is a one-arity callback that receives the workflow's progress while
it runs, one plain map per event (`Tackle.Workflow.Progress` documents each):

```elixir
Tackle.Workflow.run(handle, script, on_event: fn event -> send(view, {:workflow, event}) end)
```

* `:run_started` / `:run_finished` — a delegated run was admitted (by
  `tackle.spawn`, or as item `i` of a `tackle.parallel` batch), and the
  workflow observed its outcome. A run the script never awaits reports no
  outcome.
* `:run_event` — one event from that run's child agent, such as a tool call.
* `:parallel_started` / `:parallel_finished` / `:item_failed` — the bounds of a
  batch, and items that ended without a run.
* `:classify_started` / `:classify_finished` — a `tackle.classify` call asked
  its decision model (with its `label`, model, and questions), and settled
  with the answers the script receives, probabilities included, or the
  failure reason. Both come from the workflow worker, in that order; a call
  that raises reports neither.
* `:log` — a `tackle.log/1` message, in order with the run events.

Events come from more than one process, so a run's child events can arrive
before its `:run_started`; key runs by `:run_id`. Progress is presentation
only: a callback that raises is logged and ignored, and an unobserved workflow
forwards no run events (its runs' events still feed the workflow's own token
and tool-call accounting).

The CLI draws these events as a live flow chart in the `run_workflow` tool
card: one node per run with its status, clock, and current activity, branches
for overlapping runs and `tackle.parallel` batches (including queued and
failed items), one node per classification with its label and answers, and
the latest log line.

## Running a workflow from an agent

`Tackle.Workflow.Tool` is the model-facing surface of the same runner: an opt-in
`Tackle.Lib.Tool` named `run_workflow` that an agent calls with exactly one of
`script` (Lua source) or `workflow` (a saved workflow name). Saved names require
a host-supplied `:workflow_loader` in session context: `name -> {:ok, script} | {:error, reason}`.
Saved scripts are self-contained and take no parameters; `token_budget` remains
an optional execution budget. The host grants it like any other trusted tool
and, optionally, narrows the profiles workflows may spawn:

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
* `:decisions` in the session context grants `tackle.classify` its decision
  models (see [Classification](#classification)). The Tackle harness fills it
  from the session's providers and the `config.json` `decision_model` default
  whenever a provider offers decision models.
* `:workflow_token_budget` in the session context gives each workflow a token
  budget. The tool's optional `token_budget` argument can only lower it;
  without either, workflows have no token budget. The budget applies to each
  `run_workflow` call separately, so it bounds one workflow, not a session's
  total spend.
* The values the workflow returns are the tool result, one per line. A sequence
  table such as `return {a, b}` gives one line per element, like `return a, b`;
  any other table — `{ok = true, text = "..."}`, or a table nested in a
  sequence — is rendered as JSON. NaN becomes `null` inside JSON, keys that would
  collide as JSON strings (`1` and `"1"`) fall back to Elixir's `inspect/1`, and
  functions and userdata become `<function>` and `<userdata>` placeholders.
* Workflow errors, rejected
  spawns, and cancellations are returned as readable messages the agent can
  act on.
* The tool call owns the workflow: the workflow is cancelled when the call ends
  (including a cancelled turn, where the harness runs the tool body in its own
  supervised process). The tool sets no deadline: a workflow runs until it
  finishes or is cancelled.
* `Tackle.Workflow.Tool.skill_markdown/0` returns a `SKILL.md` guide for
  writing workflow scripts: patterns, sandbox limits, and pitfalls that do not
  fit in the tool description. The text is embedded at compile time. A harness
  host can offer it with
  `Tackle.Skills.builtin(markdown, requires_tools: ["run_workflow"])`, so only
  agents that have the tool see it. The CLI does this.
* When the session context carries an `:event_callback`, the tool reports the
  workflow's progress as `:workflow_progress` events tagged with its
  `:tool_call_id` (see [Observing progress](#observing-progress)), so a frontend
  can draw the runs under the tool call. `tackle.log/1` still goes to `Logger`
  as well.

## Guarantees

* **Sandboxed.** The pure-Elixir Lua 5.3 VM runs with the default sandbox: no
  file system, no network, no `os.execute`, no `require`/`load`. A
  deterministic instruction budget (default 1,000,000 VM instructions,
  overridable) stops spin loops that never await.
* **Bounded.** A workflow has no deadline by default; a host may pass an
  explicit `:timeout` to `Tackle.Workflow.run/3`. An optional token budget
  refuses new runs once spent. `tackle.parallel/3` keeps at most the
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