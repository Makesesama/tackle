# Narrator — implementation plan

Status: **implemented** (all six steps). The plan below is kept as written;
"Implementation notes" at the end records where the code deviates from it and
how the open questions were decided.

The narrator writes a short, live status line for each running subagent and
workflow child ("reading the session tests to find where titles are stored"),
produced by a small local chat model (for example `ollama/gemma4:12b`). It
follows the pattern of the bash watchdog (`Tackle.Watchdog`): an optional
per-session service, configured in `~/.tackle/config.json`, that never affects
the agent when it fails.

## Decision: one narrator on the root session

Two shapes were considered:

- **A. A narrator beside every child session**, publishing into its own
  session so the existing wrappers (`Tackle.Tools.Subagent` →
  `:subagent_progress`, `Tackle.Workflow.Progress` → `:workflow_progress`)
  carry it to the root with the right `run_id`/`tool_call_id`.
- **B. One narrator on the root session**, observing the forwarded
  `:subagent_progress` and `:workflow_progress` events and publishing
  `:narration` events into the root session.

We pick **B**:

- A local Ollama server processes requests one after another. One process
  with one in-flight call and "newest pending update per run" fairness across
  all runs is the design the earlier handoff asked for; with A, N children make
  N concurrent calls and the queue moves into Ollama.
- The root already sees each run's task: the `subagent` tool's `:tool_start`
  arguments (`prompt`) and workflow `:run_started` (`prompt`). A child-side
  narrator would have to reconstruct it from its own stream.
- The root TUI addresses sidebar rows and workflow nodes by `run_id`, which
  both envelopes carry.

Costs of B, accepted: the narrator must unwrap two envelope shapes (and nested
ones for grandchildren), and it only sees what the root session forwards
(foreground progress during the parent turn, background progress always —
`session.ex` `handle_info({:tackle_event, ...})` clauses). That is exactly what
the TUI can show anyway.

## Steps

Each step is one reviewable change with its own tests.

### 1. Publish seam for auxiliary events (harness + runtime + lib)

Today nothing outside a turn can publish an event into a session except the
`{:background_finished, ...}` cast.

- `Tackle.Lib.Event`: add `:narration` to the type union.
  Data: `%{run_id: String.t(), tool_call_id: String.t() | nil, text: String.t(),
  auxiliary: true}`.
- `Tackle.Session.publish_event(session, %Event{})`: a cast that broadcasts
  `{:tackle_event, session_id, nil, event}` to subscribers. Accept only events
  marked `auxiliary: true`; never persist them, never project them into the
  transcript or usage.
- Runtime access mirrors `cancel_tool_call`: an optional
  `:publish_event` agent-backend operation, `Tackle.Runtime.publish_event/2`,
  and `{:error, {:unsupported_agent_operation, :publish_event}}` for backends
  without it. `RootBackend` maps it to `Session.publish_event/2`.
- Check `packages/tackle_sdk/PROTOCOL.md` (event list near line 147): either
  document `narration` or filter it out of the SDK stream for now.

Tests: session broadcasts with `nil` turn id while idle and mid-turn; refuses
non-auxiliary events; nothing reaches the journal; runtime op round trip and
unsupported-backend error.

### 2. Config: `Tackle.Config.Narration`

Copy `Tackle.Config.Watchdog`, but resolve with `Tackle.Lib.LLM.select/2`
(chat model), not `Decision.select/2`.

```json
"narration": {"enabled": true, "model": "ollama/gemma4:12b",
              "interval_seconds": 5, "first_after_seconds": 5}
```

- `model` is required: no fallback to the session model, which could be a paid
  remote model.
- Wire through `config/file.ex` (`@known_fields`, `narration_options/2`),
  `config.ex` (option key, struct field, `load/1`), like the watchdog.
- The local Ollama adapter only lists configured models (no discovery):
  `gemma4:12b` must be added to the `ollama` provider's `"models"` in
  `apps/tackle_cli/config/config.exs` (or the user's config) to be selectable.

Tests: parsing, validation errors, unknown model ref, disabled.

### 3. `Tackle.Narration.Digest` (pure)

Bounded per-run summary, like `Tackle.Watchdog.Digest`:

- task (first ~400 chars of the run's prompt), profile;
- the last N tool calls as `name + shortened argument` (path/command/pattern),
  with ok/error;
- the last ~300 chars of assistant text;
- errors;
- `changed?` since the last narration, and the previous narration text (sent
  to the model so it reports what is new instead of repeating itself).

Input is the *inner* child event; unwrapping happens in the narrator. Tests
cover bounds, UTF-8 safety, ANSI stripping, and change tracking.

### 4. `Tackle.Narrator` service

GenServer started by `RootBackend.services/2` **only for the root session**
(no `context.parent`), next to the watchdog, under the agent's
`ServiceSupervisor`; registered with `Registry.service_name(agent_ref,
__MODULE__)` so the TUI can ask `running?/1`.

- Subscribes like the watchdog, including the retry while a turn is running.
- Tracks runs by `run_id`:
  - `:tool_start` of the `subagent` tool → remember its prompt by
    `tool_call_id`; `:subagent_started` → open the run;
    `:subagent_progress` → feed `data.event` to the digest (recursing into
    nested `:subagent_progress`/`:workflow_progress` so grandchildren count
    toward their top-level row); `:subagent_finished` → drop the run.
  - `:workflow_progress` with `:run_started` / `:run_event` / `:run_finished`
    → same, keyed by the workflow's `run_id` and the event's `tool_call_id`.
  - Turn finished/failed → drop foreground runs.
- Scheduling: one timer; a run is due when it is older than
  `first_after_seconds`, has changed, and was last narrated at least
  `interval_seconds` ago. Pick the due run narrated longest ago. At most one
  model call in flight; the digest is snapshotted when the call starts, so
  only the newest state is ever sent.
- The model call is one `LLM.generate_with(selection, nil, opts)` in an
  unlinked task under the service task supervisor (see
  `Tackle.Session.Title.generate/3` for the call shape):
  `tools: [], tool_choice: "none", temperature: 0.2, reasoning_effort: :none,
  max_tokens: 60`, provider options from the session (base URL),
  `receive_timeout` ~30 s plus a grace timer, like the watchdog.
- Output: one line, trimmed, quotes stripped, ≤ 100 chars; empty or tool-call
  responses are dropped. Publish via `Runtime.publish_event/2` as
  `:narration` on the root agent.
- Failures: warn once, back off, keep watching; never touches the agent.
  Usage is accumulated for diagnostics, not counted against any budget.

Tests (fake LLM adapter, no Ollama): narrates after `first_after`, not before;
one in flight; newest state wins; fairness across two runs; finished runs are
dropped and late results discarded; timeout and crash paths; nested runs
attribute to the top-level row; workflow runs.

### 5. TUI

- `runtime_events.ex`: route top-level `:narration` (session-id guard like the
  others) → set `:narration` on `state.subagents[run_id]` and on the matching
  tool card (match by `run_id`/`tool_call_id`, as `put_subagent_progress`
  does). Clear it when the run finishes.
- Sidebar row: show narration in place of `subagent_work` when present.
  Touches `tui/subagents.ex` (`tracked_task/1`), `widgets/subagents.ex`
  (`from_activity/3`, `wire_task/1`), the Rust row (`native/tackle/src/
  subagents.rs` `WireTask`, `src/widgets/subagents.rs`) and the native stub
  in `lib/tackle_cli/native.ex`.
- Workflow view: add a `:narration` field to the node in
  `tui/workflow_progress.ex`, rendered in place of `:now` when present
  (`:now` keeps updating underneath, so a stale narration does not hide a
  newer activity forever — drop the narration when it is older than
  ~3 × interval).
- Plain output (`output/progress.ex`): ignore `:narration` for now.

Tests: routing, row rendering with and without narration, workflow node.

### 6. Docs

`apps/tackle_cli/README.md` (next to "Command watchdog") and
`packages/tackle/README.md` config section; `packages/tackle_runtime/README.md`
for `publish_event`. Optionally a live bench like
`apps/tackle_cli/bench/watchdog_live.exs` to tune the prompt against a real
Ollama.

## Later, not in this plan

- Narration for review progress (the
  "narrator" item under review UX in `todos.md`).
- A final summary line when a run ends.
- A scope-wide gate if the watchdog and narrator share one Ollama and contend.

## Decisions (formerly open questions)

1. Only delegated runs are narrated (subagents and workflow children). The
   root agent's own turn is not narrated; the narrator runs only beside the
   root session (`RootBackend.services/2` with a root `AgentContext` without a
   parent).
2. Defaults are `interval_seconds` 5 and `first_after_seconds` 5. `model` is
   required; there is no fallback to the session model.
3. `gemma4:12b` is bundled in the `ollama` provider's `"models"` in
   `apps/tackle_cli/config/config.exs`, next to the `tev1:4b` decision model,
   so `ollama/gemma4:12b` is selectable without user configuration (it also
   appears in the CLI's model list).

## Implementation notes

Where the code differs from, or adds to, the steps above:

- **Step 1.** `Tackle.Lib.Event.auxiliary?/1` names the `data.auxiliary ==
  true` rule. `Tackle.Session.publish_event/2` checks it before casting and
  returns `{:error, {:invalid_event, event}}` synchronously; so does
  `Tackle.Runtime.publish_event/2`, before reaching the backend. `:narration`
  is added to the event type union only (not to `normalize/2`, so a provider
  stream cannot produce one). The SDK documents `narration` in `PROTOCOL.md`
  rather than filtering it: the SDK server drives the loop directly, runs no
  session services, and never emits it.
- **Step 2.** As planned (`Tackle.Config.Narration`, `"narration"` in
  `config.json`, `:narration` in `Tackle.Config`).
- **Step 3.** `Tackle.Narration.Digest` keeps the last 6 tool calls and the
  last 3 errors; tool arguments are shortened from `path`, `file_path`,
  `command`, `pattern`, `query`, `url`, `profile`, or `workflow`. Only content
  deltas count as assistant text (reasoning and tool input are ignored).
  `taken/1` clears `changed?` when a request starts; `changed/1` sets it again
  after a failed request.
- **Step 4.** `Tackle.Narrator`:
  - also ends runs when their launching foreground `subagent` call or their
    `run_workflow` call ends, so workflow runs that are never awaited do not
    linger; background subagent runs (`"background": true` in the call's
    arguments or the progress envelope) survive both their call and the turn;
  - backs off globally after a failed request (the model is shared): the delay
    starts at twice `interval_seconds`, doubles up to 60 s, and resets on the
    next answer; the failed run stays due;
  - passes the harness credential store and the session's provider options to
    the call, so a remote chat model would also work; the reaping timer is the
    receive timeout (30 s) plus a grace of at most 5 s;
  - does not republish a line identical to the run's previous narration, but
    counts the answer as the run's narration attempt (as it does for empty
    answers), so it is not asked again before the interval.
- **Step 5.**
  - The TUI routes `:narration` only with a `nil` turn id and before the
    pending-submit clause, so a narration can never be taken for the first
    event of a new turn.
  - A narration naming a `run_workflow` call goes to that call's workflow
    node; otherwise it goes to the running subagent row (tracked run and
    matching tool card). Runs that already settled ignore late narration.
  - The native wire task gained a sixth `narrated` boolean, rendered in
    italics; the NIF signature (and so the stub in `lib/tackle_cli/native.ex`)
    is unchanged.
  - The workflow node's narration expires after a fixed 15 s (3 × the default
    interval) in `WorkflowProgress.refresh/2`, because the event does not carry
    the configured interval.
  - Narration is shown in the sidebar row and the workflow node only, not in
    the inline subagent tool card.
- **Step 6.** Docs updated in `apps/tackle_cli/README.md` ("Narration"),
  `packages/tackle/README.md`, `packages/tackle_runtime/README.md`,
  `packages/tackle_lib/README.md`, `packages/tackle_ollama/README.md`, and
  `packages/tackle_sdk/PROTOCOL.md`. No live bench was added.
