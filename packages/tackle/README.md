# Tackle harness

`packages/tackle` is the frontend-independent developer harness (`:tackle`,
`Tackle.*`). It composes the [agent library](../tackle_lib/README.md)
(`:tackle_lib`, `Tackle.Lib.*`) and the [scoped OTP runtime](../tackle_runtime/README.md)
(`:tackle_runtime`, `Tackle.Runtime.*`) with developer tools, configuration,
credentials, coding profiles, and durable root sessions. Bring adapter and tool
modules in trusted application code; the [CLI](../../apps/tackle_cli/README.md)
is one frontend, not a requirement for embedding the harness.

This package requires Elixir `~> 1.20` and, to build the `gix_ex` NIF that code
review ([`tackle_review`](../tackle_review/README.md)) uses to read Git
repositories, a Rust toolchain (`cargo`). Within this
checkout it uses sibling path dependencies. Nothing discovers plugin projects:
adapter, tool, and hook modules are either part of the running application or
come from precompiled projects explicitly enabled in `$TACKLE_HOME/plugins.json`
(see [Plugin projects](#plugin-projects)).

## Installation

The monorepo packages are Git dependencies, not Hex releases. To embed the
harness, add `:tackle` from a published tag or commit SHA to your `mix.exs`:

```elixir
defp deps do
  [
    {:tackle,
     git: "https://github.com/Makesesama/tackle.git",
     ref: "REF",
     subdir: "packages/tackle"}
  ]
end
```

Then run `mix deps.get`; sibling dependencies resolve from the same checkout.
For library-only use without developer-harness policy, see the
[`tackle_lib` installation guide](../tackle_lib/README.md#status-and-installation).
For local development, run Mix from `packages/tackle` rather than the repo root.

## Basic harness API

The harness accepts already-loaded adapter and capability modules, which
trusted host code passes explicitly: `Tackle.Config.load/1` takes them as
`:available_adapters` or through a `Tackle.Plugins.Catalog` (`:catalog`), and
`Tackle.Providers` and `Tackle.Auth.Flows` take them as their first argument.
There is no application-environment adapter list.
General extension-project discovery remains out of scope; configuration data
and frontend arguments only select models declared by modules supplied by the
distribution. Each adapter module is an adapter *type*; sessions select
models from *providers*, configured instances of those adapters (see
[Providers](#providers)). If no model is configured, the harness picks the
first model reference exposed by the available providers.

Execution is scoped. `Tackle.start_scope/1` starts one root agent plus every
descendant it may create and returns a PID-free `Tackle.Runtime.Scope`:

```elixir
# MyAdapter is an already-loaded Tackle.Lib.LLM adapter.
{:ok, config} =
  Tackle.Config.load(
    available_adapters: [MyAdapter],
    overrides: [model: "my-provider/my-model", thinking: "high"]
  )

root_spec = Tackle.Runtime.AgentSpec.new!(name: "root", config: config)
scope_spec =
  Tackle.Runtime.ScopeSpec.new!(
    backend: Tackle.Runtime.RootBackend,
    root_spec: root_spec,
    profiles: %{}
  )

{:ok, scope} = Tackle.start_scope(scope_spec)

{:ok, _snapshot} = Tackle.subscribe(scope.root_agent_ref)
{:ok, _turn_id} = Tackle.submit(scope.root_agent_ref, "Inspect this project")

:ok = Tackle.stop_scope(scope.scope_ref)
```

`Tackle.Config.load/1` loads exactly one agent's execution configuration. Trusted host or distribution code composes it
into an `AgentSpec` and `ScopeSpec` before starting the runtime; model-generated
data may only select a trusted profile name. `Tackle.Runtime.RootBackend` is
supplied by this package as the backend for its durable root session. For the
built-in coding profiles instead of an empty `profiles` map, use
`Tackle.Coding.scope_spec/2`. A host that builds several configurations for
one workspace reads their sources (the environment, `$TACKLE_HOME/config.json`,
the project's `.tackle/config.json`, the accounts, the skills, and the prompt
files) once with `Tackle.Config.Sources.read/1`, which takes `load/1`'s
options, and builds each with `Tackle.Config.from_sources/2`, as
`Tackle.Coding.scope_spec/2` does for the root and every profile. A built
configuration changes only through `Tackle.Config.update/2` (model, thinking
level, step limit, context, and adapter options, checked as `new/1` checks
them).

Subscribers receive provider-neutral library events and turn results with
session and turn correlation; `Tackle.Session.Events` documents each message:

```elixir
{:tackle_event, session_id, turn_id, %Tackle.Lib.Event{}}
{:tackle_event, session_id, nil, %Tackle.Lib.Event{}}  # outside any turn
{:tackle_turn_started, session_id, turn_id, reason}    # a turn the session started
{:tackle_input_returned, session_id, turn_id, messages} # queued input a cancel hands back
{:tackle_turn_finished, session_id, turn_id, result}
{:tackle_turn_failed, session_id, turn_id, reason}
{:tackle_session_reconfigured, session_id, %Tackle.Session.Snapshot{}}
{:tackle_session_compacted, session_id, %Tackle.Session.Snapshot{}, record}
{:tackle_session_navigated, session_id, %Tackle.Session.Snapshot{}, outcome}
{:tackle_session_title_changed, session_id, title}
{:tackle_storage, session_id, :delayed | :ready}
```

Events outside a turn include a manual compaction's progress, background
subagent progress and completion, `:subagent_message_received` when the session
takes another agent's message into its conversation, and auxiliary events such
as narration.

Each `%Tackle.Session.Snapshot{}` carries the settled `agent_state`; aggregate
usage and context pressure derive from it (`Tackle.Lib.State.usage/1`,
`Tackle.Lib.ContextUsage.estimate/1`), so no duplicate mutable totals are kept.
Usage events carry priced normalized usage, the selected model's metadata, and
context pressure when model metadata is available.

Each agent permits one active turn; `Tackle.submit/2` may return
`{:ok, :queued}` when a turn is already running, and `Tackle.withdraw_queued/2`
removes a matching queued message before it starts. `Tackle.continue/1`
retries the settled conversation without adding another user message.
`Tackle.cancel/1` requests cooperative cancellation of the active turn or, while
the agent is idle, of a running `Tackle.compact/2`, and `Tackle.stop_scope/1`
stops the whole scope. A cancelled turn stops the agent: the user's messages
still queued come back unsent in `{:tackle_input_returned, ...}` for the
frontend to restore, and other agents' messages and background notices stay
queued for the next turn without starting one.
`Tackle.reconfigure/2` can change the selected model and thinking level while an
agent is idle without discarding its conversation. `Tackle.monitor_agent/1`
returns a monitor reference for crash detection without exposing a runtime PID.
Subscribe before starting a turn; active-turn attachment is deferred until event
replay or projection semantics are defined. Agents use `Tackle.Tools.default/0`
unless an embedding host explicitly supplies `:tools`; a host can set
`context: %{cwd: path}` to change the filesystem tools' working directory.
These tools inherit the Tackle process's
filesystem and operating-system permissions and are not a sandbox. `Tackle.Lib` provides the
`:telemetry` runtime dependency used by tool execution.

## Built-in tools

`Tackle.Tools.default/0` supplies `read`, `bash`, `edit`, and `write` to
configured agents. They and their executors live in
[`tackle_tools`](../tackle_tools/README.md), so other hosts can use them
without the harness.
Embedding hosts can supply a trusted `:tools` list instead; set
`context: %{cwd: path}` to choose the filesystem tools' working directory.
By default, tools run with the Tackle process's filesystem and OS permissions,
not in a sandbox.

The tools keep their logic on the host and send filesystem and process
primitives to the executor in `context.executor` (see `Tackle.Executor`).
Without one they use `Tackle.Executor.Local`. A host can start a
`Tackle.Exec.Client` for a jailed exec-server and pass
`Tackle.Executor.Jailed.new(client, workspace: path)` to run the same
primitives inside the jail; the launcher must mount the workspace at the same
path as on the host. Put the executor in the loader overrides
(`overrides: [context: %{executor: executor}]`) so subagent profiles get it
too; `Tackle.Config` rejects a malformed executor rather than falling back to
the local one. With a jailed executor, `AGENTS.md`, skills, and project agent
definitions inside the workspace are also read through the jail (see
`Tackle.ProjectFiles`), so symlinks planted by jailed code cannot expose host
files; those files are limited to 1 MiB. Files outside the workspace, such as
`~/.agents/skills` or `$TACKLE_HOME/workflows`, are read and written on the
host, but if one of their symlinks leads into the workspace, the rest of the
path goes through the jail too, so a symlinked user skill still loads and
jailed code cannot retarget it at a host file. A custom executor must implement
every `Tackle.Executor` callback, including `stat/2`, `list/2`, and `workspace/1`. Cancelling or timing out `bash` kills the command's whole process
group.

`bash` retains a bounded output tail and incrementally spills oversized output
as sanitized UTF-8 to an exclusively created, mode-0600 temporary log in the
executor's temporary directory. Truncated results include its path; callers are
responsible for removing retained logs.
If spilling fails, the bounded result is still returned without a full-output
path. `read` scans text in fixed-size chunks, retaining only a bounded selection;
exact line counts and UTF-8 validation still require scanning the entire file.
Supported images are limited to 5MB. These collection bounds do not bound
memory retained by host progress callbacks or queued process messages.

## Coding scopes and subagents

`Tackle.Coding.scope_spec/2` builds a scope with built-in and discovered agent
profiles, guidance, and delegation tools. Start the returned spec with
`Tackle.start_scope/1`; unlike a plain `ScopeSpec`, this opts into the coding
harness's subagent composition.

### Configured subagents

The coding harness includes `scout`, `reviewer`, and `worker` profiles (plus the
unadvertised code review stages described below) and discovers additional
subagent definitions from Markdown files. User definitions live recursively
under `$TACKLE_HOME/agents` (by default `~/.tackle/agents`); project definitions live under the nearest
`.tackle/agents` directory at or above the configured working directory,
up to the Git root (without one, up to your home directory when the working
directory is under it, otherwise only the working directory); `$TACKLE_HOME`
itself is never a project directory. Precedence is built-in, then user, then
project, so a valid project definition replaces a same-named user or built-in
definition.

An agent file contains a deliberately small YAML-frontmatter subset followed by
its system prompt:

```markdown
---
name: reviewer
description: Reviews changes for correctness and regressions
tools: read, bash
model: my-provider/my-model
thinking: high
timeoutMs: 300000
advertise: true
allowDelegation: false
---

Review the requested change. Report concrete findings with file and line
references. Do not edit files.
```

`name` and `description` are required, as is a non-empty prompt body. Supported
optional fields are `tools`, `model`, `thinking`, `timeoutMs`, `maxIterations`,
`advertise`, `allowDelegation`, and `instructions`. Tool lists may be
comma-separated, a flow list such as `[read, "bash"]`, or an indented `- read`
block list (`YamlFrontmatter.list/1`); an empty `tools:` leaves the list unset,
so the profile gets the default tools, while `tools: []` selects none.
`timeoutMs` is at most `300000` (five minutes). Unknown fields, invalid
values, duplicate definitions within one source, unavailable models, and tools
the root agent does not have (other than the review output tools) fail startup
explicitly. Built-in profiles instead drop the tools a host did not configure,
so a host that restricts its tools restricts them too.

Default profiles are implemented as modules conforming to
`Tackle.Agents.Default`; each returns an inert `Tackle.Agents.Definition`.
User and project files can override these defaults by name.

Agent files are inert configuration. Tool names resolve only against modules
already selected by trusted harness code; they cannot load modules or arbitrary
code. Omitting `tools` inherits the root's trusted tools. Omitting `model` makes
the child use the requesting parent's current model and thinking selection;
setting `model` pins the configured selection. A `thinking` override requires an
explicit `model`. `allowDelegation` independently grants the child the subagent
tool and raises the coding scope's spawn-depth ceiling to one nested generation;
all other inherited fleet limits remain authoritative. `instructions: false`
(default `true`) gives the profile a lean system prompt: only its own prompt and
the working directory, without `APPEND_SYSTEM.md`, `AGENTS.md` files, skills, or
the `load_skill` tool.

Advertised profiles are included in the root prompt with their descriptions.
Profiles that omit `advertise: true` remain callable by exact name but are not
listed proactively.

### Default subagents

`Tackle.Coding.scope_spec/2` enables three built-in profiles by default:

- `scout` performs fast, read-only codebase reconnaissance with `read` and `bash`;
- `reviewer` performs read-only correctness, regression, and security review with
  `read` and `bash`;
- `worker` performs implementation tasks with the harness's trusted coding tools.

It also defines `review-detector` and `review-verifier`, the model stages of
`Tackle.Review` (code review; experimental, in
[`tackle_review`](../tackle_review/README.md)), from `Tackle.Review.Stages`.
They are not advertised to the root and carry the review output tools
`report_findings` and `report_verdict` (`Tackle.Tools.review/0`), which only
work in runs started by `Tackle.Review`.
Both run with `instructions: false`, so their system prompt is only their
assignment and the working directory. `AGENTS.md` guides agent loops and chats,
not reviews: a convention a review should enforce is a review rule
(`Tackle.Review.Rules`, such as `.tackle/review/rules/no-jason.md`). Both are
limited to 6 steps (model calls per run), and each detector run is told its
budget of tool-call rounds and to read only the code a suspected finding
depends on; this keeps reviews cheap and still finds bugs whose cause lies in
another file. `review.max_steps` in `config.json` changes the limits, and the
budget follows. Projects can override their prompts with
`.tackle/agents/review-detector.md` or `review-verifier.md`; an override must
keep its output tool, and should set `instructions: false` to stay lean. Agent
files may select these two tools by name even though the root does not have
them.

A failed delegated run never invalidates a review. Detectors report findings
with `report_findings` as they confirm them (`done: false`) and finish with a
last call without it; a detector override should keep that instruction. When a
run fails before its last report (an agent error, the step limit, a timeout, a
crash, or the run alone being cancelled), the findings it already reported are
still verified and ranked, and its unit is listed in
`Result.summary.incomplete_units`. Units whose runs reported nothing are listed
in `summary.failed_units`; only when every unit is in that list does the review
fail. A verifier keeps the verdicts it reported before failing.

`Tackle.Tools.Review` (`review_changes`) is an opt-in tool that lets an agent
review the current Git change with `Tackle.Review` and get back a compact list
of findings to fix; a host grants it like `run_workflow` (the CLI grants it to
the root agent). It runs the review through `Tackle.LocalReview`, which adds
the session's review settings, the user's and project's rules
(`Tackle.LocalReview.Rules`, which refuses rule files larger than
`Tackle.Review.Rules.max_file_bytes/1` without reading them), and the history.
Reviews are recorded by
`Tackle.LocalReview.History` in
`$TACKLE_HOME/review/<project-key>/` (`runs.jsonl`, `findings.jsonl`, private
to the current user). Rules and history use the session's Tackle home, the
one its configuration was loaded with (`Tackle.Config.homes/1`). The project
key is the Git repository root encoded with `Tackle.Paths.project_key/1`, as
session storage encodes project directories. Findings dismissed there are not reported again. A line left
incomplete by a crash or a full disk is skipped, and the next write starts on a
new line, so the lines after it are kept.

Reviews read the change with [`gix_ex`](../gix_ex/README.md) (gitoxide)
in the host process rather than with `git` through the session executor;
`Tackle.Review.Change` documents why that is safe for a jailed session.
`Tackle.Review.Units` shows each change inside its enclosing function, found by
`Tackle.Review.FunctionContext` with Git's per-language function patterns
(like `git diff -W` with `diff=<language>` attributes) and a JavaScript and
TypeScript pattern of its own.

The former `explorer` profile is no longer built in. The root calls `subagent`
with one of these profile names and a self-contained `prompt`. Each child has a
fresh conversation, shares the configured working directory, and returns its
result to the root. Built-in children cannot delegate; scout and reviewer are
instructed not to edit files.
**This is not a read-only sandbox:** bash retains the harness's filesystem,
network, and OS permissions. Do not use this profile as an isolation boundary.

`Tackle.Coding.scope_spec/2` owns this composition in the harness package. It loads
normal global/project guidance for root and child agents, advertises the profiles to the
root, and limits the scope to two simultaneous children plus the root. Excess
requests are rejected rather than queued. Children have unlimited loop iterations
by default and a five-minute inactivity timeout, renewed by model steps, streaming
output, and tool progress. There is no total run-duration cap. `timeoutMs` (and
the tool's `timeout_ms` override) sets the idle window, not total runtime; a tool
that produces no progress for that window can still time out. `maxIterations`
or a narrower root iteration limit can still bound an individual child.
Stopping the scope cleans up children.

Each built-in child request uses the requesting root's current model and thinking
level, including the selection restored by resume and later idle model changes.
Already-running children keep the selection they started with. Only these two
settings are inherited: prompts, tools, limits, context, and adapter options
remain the child's trusted configuration; parent history and credentials are
not copied. The selected model must be available through the child's configured
adapters, otherwise the request fails before admitting a child.

The requesting agent may also choose a model for one child run: the subagent
tool takes an optional `model` argument (`"provider/model"`), and workflows pass
`{model = "provider/model"}` as `tackle.spawn`'s third argument or a
`tackle.parallel` callback's third return value. The requested model replaces
the profile's configured or inherited model for that run only; the profile's
thinking level, prompt, tools, and limits are kept. It is model-chosen input, so
it resolves only against the child's configured adapters, exactly like a
profile's `model` field, and an unavailable model fails before admission.

This is the provider-neutral `AgentSpec.model_source: :parent` policy. Generic
profiles default to `:configured` and keep their explicitly configured model;
model-generated arguments cannot select or change this policy.

Child transcripts are not persisted: the durable root records the subagent tool
call and returned findings, not the child's full history. Subagent calls wait by
default. A call with `background: true` returns a stable run ID immediately. The
root-only `subagent_wait` tool blocks until that run finishes and consumes its
retained outcome; `subagent_status` checks without blocking and consumes an
already-complete outcome. Cancelling a wait leaves the background run available.
The root-only `subagent_cancel` tool stops a run that is no longer needed: it
cancels the child cooperatively, terminates it after a short grace period, and
consumes the run without queuing a completion notice. A run that already
finished is collected instead, so its result is returned rather than lost.
Hosts can do the same through `Tackle.Runtime.cancel_run/3`.
Every terminal outcome queues a notice in the root session's bounded inbox and
automatically continues the root once its current turn is idle. That continuation
is a normal model turn and contributes normal provider usage. Background work is
independent of the launching root turn: cancelling that turn does not stop
the child, and the root may accept new direction while it keeps running. It remains owned by the
same root session and scope, so stopping that scope cleans it up. If cancellation wins
the race before the launch tool result is committed, the run ID is queued into
the root agent's next turn so it can still use `subagent_wait` or
`subagent_status`. Root session usage does **not** include child usage or total delegation cost.
Persistent child conversations and reusable agents remain deferred. General
runtime scopes and `Tackle.Tools.default/0` do not automatically gain subagent
capability.

### Scripted workflows (optional)

The optional [`tackle_workflow`](../tackle_workflow/README.md) package adds
`Tackle.Workflow.Tool`, a `run_workflow` tool that takes either inline Lua
(`script`) or a saved workflow name (`workflow`), but not both. A workflow drives
the same delegated runs as `subagent`, so it inherits the scope's limits,
admission rules, and cancellation:

```elixir
{:ok, spec} =
  Tackle.Coding.scope_spec(
    root_tools: [Tackle.Workflow.Tool],
    overrides: [context: %{workflow_profiles: ["scout", "worker"]}]
  )
```

`Tackle.Workflow.Tool` is not in `Tackle.Tools.default/0`; a host grants it as a
root tool, exactly like any other trusted module. `:workflow_profiles` is host
configuration that narrows the profiles a workflow may spawn — it can never widen
what the scope allows — and without it the scope's own profiles decide. The tool
then needs the same runtime reference and delegation grant as `subagent`, returns
the workflow's values as its result, and cancels the workflow when the tool
call ends. The harness itself only depends on `tackle_workflow` in its own test
suite, which proves this wiring.

Saved workflows are flat `<name>.lua` files in `$TACKLE_HOME/workflows` or the
nearest project `.tackle/workflows` at or above cwd, within the bounds used for
`.tackle/agents`. Project files override user files by name; new project
workflows go to that directory or `<cwd>/.tackle/workflows`, and
`Tackle.Workflows.create/3` returns `{:error, :no_project_dir}` where that would
be `$TACKLE_HOME/workflows` itself. Names use lowercase letters,
numbers, and single hyphens. The first-line `-- description` comment describes
the workflow; configuration belongs in locals at the top, not tool parameters.
Use the normal file tools to co-author scripts and tell the user their path.
Re-read before editing because the user may change them between turns; only run
them when asked. There is no approval gate.

`Tackle.Workflows` provides discovery, live fetching/loading, saving, exclusive
project creation, and starter templates. Hosts enable named execution with:

```elixir
loader = Tackle.Workflows.loader([cwd: cwd, executor: executor] ++ Tackle.Paths.homes(env: env))
overrides: [context: %{workflow_loader: loader}]
```

`Tackle.Paths.homes/1` resolves the Tackle home and the user's home directory
from the environment the session's configuration is loaded with
(`Tackle.Config.load(env: env)`), so workflows come from the same
`$TACKLE_HOME` as the session's agents, rules, and review history; without
`:home` and `:user_home` the loader resolves them from the process
environment. The CLI supplies this automatically. All workspace reads and
writes use the session executor, including directory creation.

## Durable sessions

A root scope can own one durable session journal. Add a
`Tackle.Session.Spec` to the `ScopeSpec`. The scope stores an append-only
internal `:disk_log` in the project-specific `$TACKLE_HOME/sessions/` directory
(or in a legacy flat session directory). The CLI uses this for its root
conversations; embedding hosts can opt in.

A new session is materialized on its first prompt. Starting a scope and closing
it again without submitting a turn creates no session directory, journal,
lock, or catalog entry: `Tackle.Session.Journal.projection/1` reports a
provisional empty projection, and reconfiguring the idle agent only updates the
metadata that the eventual `session.created` commit records. Resuming an
existing session still opens and validates its journal immediately.

```elixir
{:ok, session} = Tackle.Session.Spec.new()
{:ok, spec} =
  Tackle.Runtime.ScopeSpec.new(
    backend: Tackle.Runtime.RootBackend,
    root_spec: root_spec,
    session: session
  )
{:ok, scope} = Tackle.start_scope(spec)
```

The spec's `storage` options are limited to `:home` (the `TACKLE_HOME`
directory), `:env` (the environment `TACKLE_HOME` is read from), and
`:journal_timeout` (below); `Tackle.Session.Spec.new/1` refuses any other.

Durability is fail-closed and write-behind. A turn's `turn.started` commit is
appended before its Task starts, and its settled messages, tool intents, and
terminal event are appended in order, all without waiting for the disk:
`:disk_log` hands them to the OS within about two seconds, so an application
crash keeps them, while power loss can lose the unsynced tail. The journal is
synced where an irreversible effect depends on it: before a tool with external
effects runs, everything appended so far is made durable; read-only tools skip
that sync. A provider call only waits until earlier journal requests have
completed, never for a sync. Compactions, navigations, and configuration and
title changes are synced before they take effect. If a journal append or sync
fails, the session stops instead of continuing with memory-only state. A write
the journal refuses before writing anything (data it cannot record, a commit
that would not replay) returns an error and leaves the journal usable; a
message refused that way fails the turn with `{:message_not_journaled, reason}`,
and the session rebuilds its state from the journal.

An independent deadline process uses a 15-second threshold. A live append or
`sync` that exceeds it while waiting for the disk pauses durable progress
instead of killing the session. The original request stays in flight with the
same pending commit ID and sequence: it is neither re-appended nor retried.
Successful completion resumes automatically. Session snapshots and
cancellation remain responsive; subscribers receive
`{:tackle_storage, session_id, :delayed | :ready}` and snapshots expose `storage`.
Cancellation is cooperative and settlement still waits for storage; effects
already running are not rolled back.

While delayed, submissions that would start a turn and state-changing
operations return `{:error, :storage_busy}` rather than retaining more input;
input for an active turn is still queued in the bounded inbox, since queueing
writes nothing. The journal admits
one outstanding request and at most 64 queued requests totaling 24 MiB of
encoded request data; excess requests return `{:error, :journal_busy}`. Queued
requests cannot append until the outstanding request completes. One-shot runtime
launch/completion notices still enter the bounded inbox (128 deferred notices,
32 ordinary messages, and 24 MiB of encoded entries in total), but cannot start
a continuation while storage is pending.
The harness gates every provider dispatch (including retries and compaction
summaries) behind outstanding journal work. A title-model request also waits
behind outstanding journal work, without syncing.

Startup/replay, stalls outside the disk waits (validation, projection, the
catalog update after a write, an owner that stops responding), and termination
cleanup still have hard deadlines. Expiry there stops the
scope and requires ordinary replay/recovery, not a blind retry. Actual storage
errors also remain fail-closed. Trusted hosts can override the threshold in
milliseconds with `storage: [journal_timeout: 30_000]` on `Tackle.Session.Spec`.
Direct journal inspection retains its 60-second client deadline; Session
snapshots do not wait for storage.

A fatal stall automatically captures the operation, stage, sequence, elapsed time,
queue length, and payload-free stack frames. The deadline process logs this diagnostic
and makes a bounded, best-effort attempt to save `journal-failure.json` beside
`session.dlog` with private file permissions, including when the TUI mutes console
logging. Unexpected journal exits (including disk errors and writer-lock loss)
also produce a report with a payload-free failure category and the last
stage/sequence before cleanup. Crash reports and `:sys.get_status/1` of the
journal, its deadline process, the catalog, the bash watchdog, and the narrator
show no transcript, command, or option values either, and the watchdog and the
narrator log failures by kind (an adapter crash by the exception it raised) and
stopped commands by tool call id, never a command, its output, or a model
request. Normal shutdown does not create a
failure report. Check `recorded_at`: a report from an earlier crash is retained
when the session resumes. If storage itself is stuck, saving that diagnostic may
also fail; scope shutdown does not depend on it. Prompts, tool arguments, and
conversation payloads are not included in the diagnostic.

Killing the owner cannot retract a write already dispatched to `:disk_log`.
The commit outcome is therefore unknown until journal replay. Existing durable
history is not intentionally discarded; resume follows the ordinary explicit
repair and interrupted-turn recovery policy below. This is fail-closed recovery,
not automatic retry or a guarantee against storage/device failure.

A session whose journal ends with `turn.started` and no terminal event is
interrupted. Resuming it requires an explicit recovery decision; while it is
unresolved, `Tackle.submit/2` and `Tackle.continue/1` return
`{:error, {:recovery_required, info}}`. `Tackle.Session.Snapshot.recovery`
exposes the unresolved turn and any tools whose external effects are uncertain.

To resume, start a scope whose `Tackle.Session.Spec` names the session:

```elixir
{:ok, session} = Tackle.Session.Spec.new(session_id: session_id)
{:ok, spec} = Tackle.Runtime.ScopeSpec.new(%{scope_spec | session: session})
{:ok, scope} = Tackle.start_scope(spec)

case Tackle.snapshot(scope.root_agent_ref) do
  {:ok, %{recovery: nil}} -> :ok
  {:ok, %{recovery: recovery}} -> handle_interrupted(recovery)
end

:ok = Tackle.abandon_turn(scope.root_agent_ref)
```

Session inspection and management never expose a PID or the journal process:

- `Tackle.inspect_session/2` reads and projects a session without starting one;
- `Tackle.session_usage_timeline/2` and `Tackle.all_usage_timeline/1` return
  timestamped settled assistant-message usage for one or every durable session;
  the global scan replays independent journals with bounded concurrency;
- `Tackle.list_sessions/1` and `Tackle.search_sessions/2` use the rebuildable
  derived catalog with stable cursor pagination (filters include `:cwd`,
  `:status`, given as an atom or its name, `:model`, `:tags`, and `:archived`);
  while the catalog rebuilds at startup, from each session's `summary.etf`
  sidecar while its journal is unchanged and otherwise by replaying it, they
  wait for it, so they never list a partial index;
- `Tackle.fork_session/2` materializes a self-contained session from validated
  parent history, so the child survives deletion of the parent;
- `Tackle.session_summary/2` returns a session's catalog summary;
- `Tackle.archive_session/2` and `Tackle.unarchive_session/2` move an inactive
  session to and from `sessions/archive/`;
- `Tackle.delete_session/2` moves an inactive session into `sessions/trash/` and
  refuses to delete an active one (`:session_active`, or
  `{:session_in_use, owner}` when another process holds its writer lock);
  nothing purges the trash;
- `Tackle.flush_session/1` syncs a live session's journal, an explicit
  durability barrier; and
- `Tackle.compress_idle_sessions/1` replaces journals idle for a week with a
  verified zstd copy, `session.dlog.zst`, which reads, lists, and resumes like
  the plain journal (resuming restores it first).

Internal `.dlog` files are trusted local state, never a portable interchange
format, and are not accepted as imports. Search indexes the title, user and
assistant text, `cwd`, and tags by default; it excludes reasoning, provider
continuation state, tool arguments, and tool output. Checkpoints and in-place
migration are deliberately not implemented yet. See
[`docs/SESSION_ARCHITECTURE.md`](../../docs/SESSION_ARCHITECTURE.md) for the accepted
architecture and its remaining deferrals.

The [CLI guide](../../apps/tackle_cli/README.md) documents `run --resume`,
`--abandon`, session search, and the terminal usage chart. A journal that was
not closed cleanly is repaired only when the spec allows it
(`Tackle.Session.Spec.new(session_id: id, repair: true)`, which the CLI uses
to resume); otherwise its journal refuses to open with
`{:journal_open_failed, session_id, {:repair_required, path}}` and the scope
does not start. Repair
preserves the original under the session's `recovery/` directory, marks the
session recovered, and does not silently resolve an interrupted turn. Hosts
must decide whether to abandon it.

## Conversation trees

Every agent state keeps its history as a conversation tree (`Tackle.Lib.Tree`),
so a session can hold alternative paths instead of a single linear transcript. The
engine owns the tree rules; the harness package owns durable records and the CLI
owns the picker. Branching is session policy: durable root sessions enable it by
default (`Tackle.Session.Spec` `tree: true`), while a durable session with
`tree: false` and every session without a journal (delegated agents, and root
scopes started without a `Tackle.Session.Spec`) keep a single-branch tree and
reject `Tackle.navigate/3` with `{:error, :tree_disabled}`. The snapshot's
`agent_state.tree` holds the tree either way.

Three surfaces are deliberately distinct:

- the **canonical tree** holds every settled entry on every branch, once;
- the **active transcript** (`state.messages`) is the selected branch and is
  never compacted; and
- the **model context** (`Tackle.Lib.State.model_messages/1`) is the selected
  branch with the compactions that occur on that path applied.

`Tackle.Lib.State.usage/1` aggregates assistant usage across the whole archive
while `Tackle.Lib.State.branch_usage/1` follows the active path.
`Tackle.Lib.ContextUsage.estimate/1` reports the model projection, so branch
switches reset context pressure to the selected branch.

Navigation is an idle, committed operation: it validates the destination,
persists `tree.navigated`, and only then installs the new position. It never
runs a turn, re-executes a tool, or edits entries, and an incomplete tool batch
is inspectable but not selectable.

```elixir
{:ok, scope} = Tackle.start_scope(scope_spec)
{:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "investigate the cache")

# After the turn finishes (observe `{:tackle_turn_finished, ...}`),
# move to the parent of an earlier user message and get it back as a draft.
{:ok, _snapshot, outcome} = Tackle.navigate(scope.root_agent_ref, {:edit, user_message_id})
outcome.draft.content
outcome.change.to_id # the parent, now the active position

# Return to the empty conversation before the first message.
{:ok, _snapshot, _outcome} = Tackle.navigate(scope.root_agent_ref, nil)
```

The [CLI guide](../../apps/tackle_cli/README.md#conversation-tree-tree)
documents the terminal tree picker. Navigation changes conversation history,
not workspace files; it never undoes tool side effects.

Journals of sessions without branching keep their format (messages and
compactions without parent ids, each attached to the entry before it) and load
into a single-branch tree; resuming such a session with branching enabled
records an explicit `tree.enabled` transition rather than rewriting the source
file. `Tackle.fork_session/2`
remains sequence-based and copies the tree and active position into the
self-contained child. See [`docs/SESSION_TREE_PLAN.md`](../../docs/SESSION_TREE_PLAN.md)
for the implemented first version and the deliberately deferred increments.

## Breaking migration to scoped runtime

This is the developer-harness scope migration: `Tackle.start_session/1`,
`Tackle.start_configured_session/1`, and PID-based `Tackle.close/1` are removed.
Agent operations now take a `Tackle.Runtime.AgentRef` and shutdown takes a
`Tackle.Runtime.ScopeRef`. The `allow_recursion` grant is renamed
`allow_delegation`. There is no compatibility wrapper: a session PID is not the
lifecycle or addressing unit of the runtime.

Library users must also migrate the old `packages/tackle` / `Tackle.*` /
`:tackle` library identity to `packages/tackle_lib` / `Tackle.Lib.*` /
`:tackle_lib` (including application configuration); the current `:tackle`
package is the developer harness, not the former library.

## Agent Skills

`Tackle.Skills` discovers `SKILL.md` files in project `.agents/skills`
directories from the working directory up to the Git root (without one, up to
your home directory when the working directory is under it, otherwise only the
working directory), and in
`~/.agents/skills`. The system prompt includes only skill names, descriptions,
and directories. The model loads a skill's instructions on demand with the
`load_skill` tool (`Tackle.Tools.LoadSkill`), which every agent offered a skill
is granted. The tool serves only offered skills, by name. The harness reads the
file itself when the tool is called, through the same jail-aware routing as
`AGENTS.md`, so user skills load even under a jailed executor. Files a skill
references relative to its directory are still read with the agent's own
tools. Project skills nearest the working directory take precedence. Missing
descriptions, unreadable files, or malformed frontmatter cause a warning and
the skill is skipped; invalid names or overlong descriptions warn but still
load. Unlike subagent definitions under `$TACKLE_HOME/agents` and
`.tackle/agents`, user skills live under `~/.agents/skills` **regardless of
`TACKLE_HOME`**.

A host can also ship built-in skills, such as a guide for a tool it bundles.
`Tackle.Skills.builtin/2` builds one from `SKILL.md` text, optionally with
`requires_tools:`, and `Tackle.Config.load/1` and `Tackle.Coding.scope_spec/2`
accept the result as `:builtin_skills`. Each agent is offered only the skills
whose required tools it has. Built-in skills keep their instructions in memory,
so they work in escripts, which have no `priv` directory, and they must be
self-contained. A file skill with the same name replaces the built-in one
without a warning. The CLI uses this mechanism to offer the `tackle-workflows`
guide to agents that have `run_workflow`.

## Configuration and credentials

`Tackle.Config.load/1` applies this precedence:

```text
built-in defaults < ~/.tackle/config.json < .tackle/config.json < TACKLE_MODEL/TACKLE_THINKING < explicit overrides
```

Each setting takes its value from the highest source that sets it, and only
that value is checked: an invalid `TACKLE_THINKING` fails the load only when no
override sets the thinking level. An override sets it with `thinking:` or with
`llm_opts: [reasoning_effort: ...]`; both win over the files and the
environment, and `thinking:` wins over `reasoning_effort`. Each file is still
validated as a whole.

`TACKLE_HOME` (default `~/.tackle`) changes the directory containing
`config.json`, `auth.json`, and `plugins.json`.

A project can carry its own `.tackle/config.json`. The harness uses the nearest
one at or above the working directory, within the bounds used for
`.tackle/agents`, and reads it through the session executor like `AGENTS.md`.
It accepts the same fields as the user file except `providers`,
`show_subagent_sidebar`, and `jail`: a repository chooses among the providers and accounts
you configured but cannot declare its own, which could send your credentials
to another endpoint, nor pass host environment variables into the CLI's jail. Each file is validated on its own; JSON objects then merge
recursively, so a project can change one review stage or one agent setting and
keep the rest of your user configuration. In either file, `null` leaves a
field, or a member of an object, unset in that file, so a project value of
`null` removes the user's value and the setting falls back to the default (or
to `TACKLE_MODEL` and `TACKLE_THINKING`): `"model": null` selects the first
available model, `"thinking": null` the model's default level, and
`"agents": {"scout": null}` drops the user's settings for that profile. A
project may not set `providers`, `show_subagent_sidebar`, or `jail`, not even
to `null`. An error in a file names it: `{:config_file, path, reason}`, where
`reason` is `:malformed`, `:expected_object`, `{:unreadable, posix}`,
`{:unknown_fields, fields}`, `{:invalid_field, field}`, `{:invalid_agent,
name}`, `{:invalid_provider, id}`, or the error of an invalid value, such as
`{:unknown_model, ref}`. A merged object both files set is blamed on the user
file when the user's value fails on its own, and otherwise on the project
file. For example:

```json
{
  "model": "openai-codex/gpt-5.5",
  "thinking": "medium",
  "agents": { "scout": { "model": "openai-codex/gpt-5.5-codex-mini", "thinking": "low" } },
  "review": { "profile": "quiet" }
}
```

An optional `agents` object, in either file, sets subagent profiles' `model`
and `thinking` by profile name, replacing the values from the profile's
Markdown definition (built-in, user, or project). A profile given a model runs
on it instead of following the root's current model. Names without a
discovered profile are ignored, but their models must still be available.
The configuration file accepts `model` and `thinking` harness fields and the
CLI-only boolean `show_subagent_sidebar` (default `true`), which does not affect
agent sessions, and the CLI-only `jail` object, whose `env` list names host
environment variables passed to commands in the CLI's jail (`Tackle.CLI.Jail`).
Frontends read their own fields with `Tackle.Config.File.read/1`, which
validates the whole user file as the harness does and returns its JSON object
as written. It also accepts a `session_titles` object configuring automatic
LLM-generated session titles: after an untitled durable session settles the
first message the user wrote (or, for a resumed untitled session, the next
one; messages from other agents, background notices, and hook feedback never
count), one tool-free generation call produces a concise title that is
committed through the journal and shown in session listings and the terminal
window title. Titles are enabled by the harness loader (`Tackle.Config.load/1`)
and can be disabled with `"session_titles": false`; an optional `model` field
names a canonical model reference such as `"openai-codex/gpt-5.5"` for the
title call, defaulting to the session's configured model:

```json
{
  "model": "openai-codex/gpt-5.5",
  "session_titles": { "model": "openai-codex/gpt-5.5-codex-mini" }
}
```

`Tackle.Config.new/1` treats an absent `session_titles` option as disabled, so
embedding hosts opt into the extra LLM call explicitly.

The switchable features `session_titles`, `watchdog`, `narration`, and
`compile_gate` each take an object, `true`, or `false`, in either file. `true`
is the same as `{"enabled": true}` and `false` as `{"enabled": false}`, so a
project file's `true` turns on a feature with the user's settings for it, and
`"watchdog": true` without a `model` in either file fails like
`{"enabled": true}` does.

An optional `watchdog` object enables the command watchdog (`Tackle.Watchdog`),
which is off by default because it needs a local decision model. Every session
(root, subagent, and workflow child) then runs one beside it as a runtime
service. It watches `bash` calls without an explicit `timeout`; after
`after_seconds` (default 60) it asks the decision model whether the command is
progressing, a long-running service, waiting for input, in an infinite loop, or
stalled, and backs off exponentially while it looks healthy. A stop verdict with
probability at or above `threshold` (default 0.85) stops just that call; the
agent receives the reason as the command's error and continues. A failing
decision model never stops anything. `model` is a decision model reference
such as `"ollama/tev1:4b"` (see `Tackle.Lib.Decision`). `after_seconds` is a
positive number of seconds up to 4,294,967.295, the longest Erlang timer:

```json
{ "watchdog": { "model": "ollama/tev1:4b", "after_seconds": 60, "threshold": 0.85 } }
```

The Elixir compile gate (`Tackle.Elixir.CompileGate` from
[`tackle_elixir`](../tackle_elixir/README.md)) is off by default; a user
configuration with `"compile_gate": true`, or a `compile_gate` object, turns it
on for sessions built by `Tackle.Config.load/1`. When a turn changes Elixir sources of a Mix
project through `edit` or `write`, the gate compiles the project in its
project node (`Tackle.Elixir.ProjectNodes`, through the session's executor)
before the first change and again when the model answers; new errors and
warnings
continue the turn with one message reporting them, up to `max_rounds` times.
It logs every decision to `$TACKLE_HOME/logs/compile_gate.jsonl`. A
`compile_gate` object tunes it (`enabled`, `max_rounds`, `timeout_seconds`,
`warnings`), and `"compile_gate": false` turns it off; a project file can tune
or turn it off but cannot turn it on unless the user did. `"max_rounds": 0`
checks and logs without continuing turns:

```json
{ "compile_gate": { "max_rounds": 1, "timeout_seconds": 300, "warnings": false } }
```

`Tackle.Config.new/1` treats an absent `compile_gate` option as off, as for
session titles.

Tools can use decision models too. When any session provider's adapter
implements `Tackle.Lib.Decision`, the session context carries `:decisions`
(those providers and a default model), which the workflow tool hands to
`tackle.classify`. An optional top-level
`decision_model` sets that default; without it scripts must name a model:

```json
{ "decision_model": "ollama/tev1:4b" }
```

An optional `review` object sets defaults for code reviews (`Tackle.Review`)
requested from the session, such as through the `review_changes` tool or
`tackle review` (`Tackle.Review.Settings`). Every field is optional:

- `thinking` and `models` give the `detector`, `verifier`, and `scorer` stages
  their own thinking levels and canonical model references; stages left out
  use the profile's or the requesting session's model and level;
- `max_steps` sets the `detector` and `verifier` step limits (model calls per
  run), replacing their profiles' `maxIterations`;
- `profile` is the default display level: `quiet`, `default`, or `assertive`;
- `default_rules` lists the built-in rules to apply; without it all apply, and
  `[]` applies none. User and project rules apply either way.

A review's own options (`Tackle.Review.run/2`, CLI flags, or the tool's
`profile` argument) override these, per stage for the stage objects:

```json
{
  "review": {
    "profile": "quiet",
    "models": { "verifier": "openai-codex/gpt-5.5-codex-mini" },
    "thinking": { "detector": "low", "verifier": "low" },
    "max_steps": { "verifier": 6 },
    "default_rules": ["unhandled-error", "injection", "secret-exposure"]
  }
}
```

Unknown models and rule ids fail configuration.

Classifications by a local decision model (a provider whose adapter answers
`true` from `local?/1` or `local?/0`, such as a local Ollama server) are not
counted against workflow token budgets; a remote decision model's tokens are.

An optional `narration` object enables the narrator (`Tackle.Narrator`), which
is off by default because it calls a chat model of its own. Only the root
session runs one, as a runtime service; it follows the delegated runs the root
forwards (subagents and workflow children, counting nested runs toward their
top-level run) and, for each run that has worked for `first_after_seconds`
(default 5) and changed since its last line, asks the model for one short
status line at most every `interval_seconds` (default 5) per run. One request
is in flight at a time, the run narrated longest ago goes first, and only the
newest state is sent. Lines are published to the root session's subscribers as
auxiliary `:narration` events (`%{run_id, tool_call_id, text, auxiliary:
true}`, with a `nil` turn id) through `Tackle.Runtime.publish_event/2` and
`Tackle.Session.publish_event/2`; they are never persisted or added to the
transcript. The root agent's own turn is not narrated. `model` is required —
there is no fallback to the session model, which may be a paid remote one —
and must be a chat model reference such as `"ollama/gemma4:12b"`. The request
is tool-free with `reasoning_effort: :none` and `max_tokens: 60`, so the
model's adapter should accept both. A failing model logs one warning and is
retried with back-off; it never affects the agents. Both intervals are positive
numbers of seconds up to 4,294,967.295, the longest Erlang timer:

```json
{ "narration": { "model": "ollama/gemma4:12b", "interval_seconds": 5, "first_after_seconds": 5 } }
```

Thinking may be
`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`; supported levels can vary
by model. `TACKLE_THINKING` overrides the file in the same way that
`TACKLE_MODEL` overrides `model`. Adapter modules are always supplied as
executable code, never converted from JSON strings.

Configured sessions retry transient provider-message failures three times by
default, using jittered exponential delays of about 2, 4, and 8 seconds with a
60-second cap, and wait at least as long as a provider's `Retry-After` asks.
Programmatic callers can set `retry: false` or pass
`retry: [max_retries: ..., base_delay_ms: ..., max_delay_ms: ..., jitter?: ...]`
to `Tackle.Config.new/1`. Only transient `Tackle.Lib.LLM.Error` kinds
(connection failures, timeouts, rate limits, overload, and server errors) are
retried; authentication, quota/billing, context overflow, cancellation, and
unknown failures are not.

Configured sessions also build an effective coding prompt for their working
directory. The built-in prompt lists the selected tools and core coding
guidelines. The following optional UTF-8 files customize it:

- `$TACKLE_HOME/SYSTEM.md` replaces the built-in base prompt;
- `$TACKLE_HOME/APPEND_SYSTEM.md` appends global user guidance;
- `$TACKLE_HOME/AGENTS.md` supplies global agent instructions; and
- `AGENTS.md` files of the working directory and its ancestors are included
  from broadest to most specific: up to your home directory when the working
  directory is under it (also above a Git root, so `~/AGENTS.md` applies),
  otherwise up to the Git root, or only the working directory outside a Git
  repository. Directories other users can write, such as `/tmp`, are not
  searched on behalf of a project below them.

The append and `AGENTS.md` layers are retained when an embedding caller supplies
an explicit `:system_prompt` override to `Tackle.Config.load/1`. Pass `:cwd` to
`Tackle.Config.load/1` when the session should target a directory other than the
process working directory; the same path is placed in session context for the
built-in filesystem tools. `Tackle.Config.new/1` remains filesystem-independent:
it supplies the built-in prompt but does not discover prompt files.

```json
{
  "model": "my-provider/my-model",
  "thinking": "high"
}
```

### Providers

A provider is one configured instance of an adapter: its id is the prefix of
model references (`codex-work/gpt-5.5`) and the namespace of its credentials.
One adapter can back several providers, each with its own settings and login.
`Tackle.Providers.available_providers/2` merges them from three sources, lowest
precedence first:

1. the default providers of each configured adapter (usually one, whose id is
   the adapter's `adapter_id/0`);
2. accounts created with `tackle auth login ID --as NAME`, recorded in
   `auth.json`; and
3. the `providers` object of `config.json`.

Each `config.json` entry names an adapter type id under `adapter`; every other
key is an opaque setting passed to the adapter as `:provider_settings`, never
interpreted by the harness:

```json
{
  "model": "ollama-gpu-box/gpt-oss:20b",
  "providers": {
    "codex-work":     { "adapter": "openai-codex" },
    "ollama":         { "adapter": "ollama", "models": ["qwen3:8b"] },
    "ollama-gpu-box": { "adapter": "ollama", "base_url": "http://gpu:11434/v1",
                        "api_key": "none", "local": true, "models": ["gpt-oss:20b"] }
  }
}
```

An entry for an existing provider id must name the same adapter; its settings
are merged over the earlier ones (here `ollama` gains a model list). An entry
naming a different adapter than a default provider of that id fails with
`{:provider_adapter_conflict, id}`; an entry without an `adapter` or with an
invalid id is also an error. `config.json` and `auth.json` are shared by every
host on the machine, so an entry naming an adapter type the running host does
not include is skipped, and so is an account whose adapter the host does not
include, whose id is the id of a default provider of any of the host's
adapters, or whose id a `config.json` entry declares for another of the
host's adapters. A model
reference always names a provider, never an adapter type. The former
`provider_options` field is removed; declare settings under `providers`
instead.

`ID` in `tackle auth login ID --as NAME` is a provider id or an adapter type
id. An account records its adapter type and, when `ID` was a provider id, that
base provider: `"accounts": {"cloud2": {"adapter": "ollama", "base":
"ollama-cloud"}}` (`Tackle.Auth.accounts/0`, `Tackle.Auth.put_account/2`). An
account's settings are its base provider's merged settings (defaults plus
`config.json`) without `"api_key_env"`, so a second account never silently
uses the first one's environment key; an account created from an adapter type
id, or whose base is gone, starts without settings. A `config.json` entry for
the account's own id merges over that. `login --as` refuses, before the
adapter's login runs, a `NAME` that is a default provider's id
(`{:default_provider_name, NAME}`; log in to that provider without `--as`)
and a `NAME` already used by a `config.json` provider or recorded account of
another adapter, including an account for an adapter the running host lacks
(`{:provider_adapter_conflict, NAME}`); the account is recorded only after the
login succeeded and its credentials were stored.

`Tackle.Config.load/1` reads both sources itself (pass `:accounts` to supply
the accounts explicitly), and `Tackle.Config.new/1` takes `:providers`:
`Tackle.Lib.LLM.Provider` structs, or adapter modules standing for their
default providers.

### Credentials

`Tackle.Auth` stores one opaque map per provider id in `$TACKLE_HOME/auth.json` and
injects only a non-secret `Tackle.Lib.CredentialStore` handle into adapter
options. `Tackle.Auth.Flows` runs an adapter's login, logout, status, and
usage flows for one provider, passing the provider's id and settings to the
adapter. `login(adapters, id, as: name)` creates the account `name` on the adapter that
`id` names (a provider id or an adapter type id) and stores its credentials
under `name`; a failed login leaves no account behind. Logging out of an
account deletes its credentials and its record; logging out of a default or
`config.json` provider deletes only its credentials. The file is a version 2
envelope with credentials under `providers` and accounts under `accounts`
(`{"codex-work": {"adapter": "openai-codex"}}`); a version 1 file loads with no
accounts and is rewritten as version 2, so older binaries cannot read it after
the next change. Credential-shaped `llm_opts` keys (including nested token, API-key,
password, and authorization fields) are rejected; provider secrets belong only
in the credential store. The file is plaintext protected by filesystem
permissions (`0700` for the directory and `0600` for the file), not encryption.
Writes are atomic and serialized within one Tackle application. Several VMs
(two CLIs, or a CLI and an SDK server) can share the file: every change
re-reads it and applies only its own change to what it finds, and a read
loads the file again when its device, inode, size, or modification time
differs from the last read, or it was modified in the second that read began.
Every change holds a write lock, `.auth.json.lock` beside the file, from its
re-read to its rename, so changes from two VMs at the same instant are applied
one after the other; a change waits up to five seconds for it and then fails
with `{:error, {:auth_file_locked, path}}`. `Tackle.Auth.with_lock/2` (the
store's `Tackle.Lib.CredentialStore.with_lock/3`) runs a function while
holding a lock on one provider namespace (`.auth.json.<hash>.lock`), such as
an OAuth refresh that spends a rotating refresh token, so that only one VM
refreshes at a time; it waits up to 60 seconds, is released when the function
returns or raises or the caller dies, and does not block other namespaces.
The Codex and Anthropic adapters hold it while they refresh a login, and the
CLI while it refreshes an MCP server's OAuth credentials.
Both are `Tackle.FileLock`s: operating-system locks where `flock` exists,
owner records only as strong as the recorded PID elsewhere. OS keyrings are
not implemented. A file that becomes
unreadable or invalid while the store runs makes reads and changes return
`{:error, reason}` and is never overwritten. `Tackle.Auth.accounts/0`, the
one way to read the accounts, returns `{:ok, accounts}`, or
`{:error, {:accounts_unavailable, reason}}` when the file cannot be read or
the store is not running. An account record is checked by
`Tackle.Auth.validate_account/2` wherever it comes from: its id, `"adapter"`,
and `"base"`, if any, must be valid provider ids (a `null` base is no base).

### Plugin projects

`Tackle.Plugins.Loader.load/1` loads the adapters, tools, and hooks of
precompiled Mix projects listed in `$TACKLE_HOME/plugins.json` and returns
them as a validated `Tackle.Plugins.Catalog`; it never discovers, fetches, or
builds projects, and an absent file enables none. It is meant to run once,
when the host starts: loaded code cannot be unloaded. The CLI calls it at
startup and merges the result into its own catalog; embedding hosts need not
use it. See [plugin loading](../../docs/PLUGINS.md) for the file's format and
the checks the loader applies.

## Development

From `packages/tackle`, run:

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted
```

These are separate Mix projects, not an umbrella. See the
[repository guide](../../README.md#development) for checks in other packages.
