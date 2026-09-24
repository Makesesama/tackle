# Tackle harness

`packages/tackle` is the frontend-independent developer harness (`:tackle`,
`Tackle.*`). It composes the [agent library](../tackle_lib/README.md)
(`:tackle_lib`, `Tackle.Lib.*`) and the [scoped OTP runtime](../tackle_runtime/README.md)
(`:tackle_runtime`, `Tackle.Runtime.*`) with developer tools, configuration,
credentials, coding profiles, and durable root sessions. Bring adapter and tool
modules in trusted application code; the [CLI](../../apps/tackle_cli/README.md)
is one frontend, not a requirement for embedding the harness.

This package requires Elixir `~> 1.20`. Within this checkout it uses sibling
path dependencies. Plugin/project discovery and loading from configuration are
not supported: adapter modules must already be part of the running application.

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

The harness accepts already-loaded adapter and capability modules. Configure
adapters as trusted code with `config :tackle, adapters: [MyAdapter]` (for
example, in `config/config.exs`), or pass them explicitly to the loader.
General extension-project discovery remains out of scope; configuration data
and frontend arguments only select models declared by modules supplied by the
distribution. If no model is configured, the harness picks the first model
reference exposed by the configured adapters.

Execution is scoped. `Tackle.start_scope/1` starts one root agent plus every
descendant it may create and returns a PID-free `Tackle.Runtime.Scope`:

```elixir
# In config/config.exs, configure an already-loaded Tackle.Lib.LLM adapter:
config :tackle, adapters: [MyAdapter]
```

```elixir
{:ok, config} =
  Tackle.load_config(
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

`Tackle.load_config/1` delegates to `Tackle.Config.load/1` to load exactly one
agent's execution configuration. Trusted host or distribution code composes it
into an `AgentSpec` and `ScopeSpec` before starting the runtime; model-generated
data may only select a trusted profile name. `Tackle.Runtime.RootBackend` is
supplied by this package as the backend for its durable root session. For the
built-in coding profiles instead of an empty `profiles` map, use
`Tackle.Coding.scope_spec/2`.

Subscribers receive provider-neutral library events and terminal outcomes with
session and turn correlation:

```elixir
{:tackle_event, session_id, turn_id, %Tackle.Lib.Event{}}
{:tackle_turn_finished, session_id, turn_id, result}
{:tackle_turn_failed, session_id, turn_id, reason}
{:tackle_session_reconfigured, session_id, %Tackle.Session.Snapshot{}}
```

Each `%Tackle.Session.Snapshot{}` includes derived `%Tackle.Session.Stats{}`
with aggregate assistant-message usage, latest generation usage, selected-model
metadata, and current context pressure. No duplicate mutable totals are kept.
Usage events also carry priced normalized usage and context pressure when model
metadata is available.

Each agent permits one active turn; `Tackle.submit/2` may return
`{:ok, :queued}` when a turn is already running, and `Tackle.withdraw_queued/2`
removes a matching queued message before it starts. `Tackle.continue/1`
retries the settled conversation without adding another user message.
`Tackle.cancel/1` requests cooperative cancellation, and `Tackle.stop_scope/1` stops the whole scope.
`Tackle.reconfigure/2` can change the selected model and thinking level while an
agent is idle without discarding its conversation. `Tackle.monitor_agent/1`
returns a monitor reference for crash detection without exposing a runtime PID.
Subscribe before starting a turn; active-turn attachment is deferred until event
replay or projection semantics are defined. Agents use `Tackle.Tools.default/0`
unless an embedding host explicitly supplies `:tools`; a host can set
`context: %{cwd: path}` to change the filesystem tools' working directory.
`elixir_eval` is a development-only tool: `Tackle.Tools.default/0` includes it
only when the `TACKLE_DEV` environment variable is truthy (the devshell and
jail set this automatically). It runs stateless code inside the live Tackle BEAM
with a five-second default timeout; VM side effects persist, but variable
bindings do not carry between calls. These tools inherit the Tackle process's
filesystem and operating-system permissions and are not a sandbox. `Tackle.Lib` provides the
`:telemetry` runtime dependency used by tool execution.

## Built-in tools

`Tackle.Tools.default/0` supplies `read`, `bash`, `edit`, and `write` to
configured agents. `elixir_eval` is included only when `TACKLE_DEV` is truthy.
Embedding hosts can supply a trusted `:tools` list instead; set
`context: %{cwd: path}` to choose the filesystem tools' working directory.
Tools run with the Tackle process's filesystem and OS permissions, not in a
sandbox. `elixir_eval` executes code inside the live BEAM and must only be
used in development.

## Coding scopes and subagents

`Tackle.Coding.scope_spec/2` builds a scope with built-in and discovered agent
profiles, guidance, and delegation tools. Start the returned spec with
`Tackle.start_scope/1`; unlike a plain `ScopeSpec`, this opts into the coding
harness's subagent composition.

### Configured subagents

The coding harness includes `scout`, `reviewer`, and `worker` profiles and discovers additional
subagent definitions from Markdown files. User definitions live recursively
under `$TACKLE_HOME/agents` (by default `~/.tackle/agents`); project definitions live under the nearest
`.tackle/agents` directory at or above the configured working directory,
stopping at the Git root. Precedence is built-in, then user, then project, so a
valid project definition replaces a same-named user or built-in definition.

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
`advertise`, and `allowDelegation`. Tool lists may be comma-separated, a simple
`[read, bash]` list, or an indented `- read` block list. Unknown fields, invalid
values, duplicate definitions within one source, unavailable models, and tools
not already available to the harness package fail startup explicitly.

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
all other inherited fleet limits remain authoritative.

Advertised profiles are included in the root prompt with their descriptions.
Profiles that omit `advertise: true` remain callable by exact name but are not
listed proactively.

### Default subagents

`Tackle.Coding.scope_spec/2` enables three built-in profiles by default:

- `scout` performs fast, read-only codebase reconnaissance with `read` and `bash`;
- `reviewer` performs read-only correctness, regression, and security review with
  `read` and `bash`;
- `worker` performs implementation tasks with the harness's trusted coding tools.

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
by default and a five-minute run timeout; `maxIterations` or a narrower root
iteration limit can still bound an individual child. Stopping the scope cleans up children.

Each built-in child request uses the requesting root's current model and thinking
level, including the selection restored by resume and later idle model changes.
Already-running children keep the selection they started with. Only these two
settings are inherited: prompts, tools, limits, context, and adapter options
remain the child's trusted configuration; parent history and credentials are
not copied. The selected model must be available through the child's configured
adapters, otherwise the request fails before admitting a child.

This is the provider-neutral `AgentSpec.model_source: :parent` policy. Generic
profiles default to `:configured` and keep their explicitly configured model;
model-generated arguments cannot select or change this policy.

Child transcripts remain ephemeral: the durable root records the subagent tool
call and returned findings, not the child's full history. Subagent calls wait by
default. A call with `background: true` returns a stable run ID immediately. The
root-only `subagent_wait` tool blocks until that run finishes and consumes its
retained outcome; `subagent_status` checks without blocking and consumes an
already-complete outcome. Cancelling a wait leaves the background run available.
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

Durability is fail-closed. A turn's `turn.started` commit is synced before its
Task starts, every settled message is committed before the loop performs the
next provider or tool effect, and the terminal event is synced before terminal
outcomes are delivered. If a journal append, sync, or validation fails, the
session stops instead of continuing with memory-only state.

A session whose journal ends with `turn.started` and no terminal event is
interrupted. Resuming it requires an explicit recovery decision; while it is
unresolved, `Tackle.submit/2` and `Tackle.continue/1` return
`{:error, {:recovery_required, info}}`. `Tackle.Session.Snapshot.recovery`
exposes the unresolved turn and any tools whose external effects are uncertain.

```elixir
{:ok, scope} = Tackle.resume_session(session_id, scope_spec)

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
  derived catalog with stable cursor pagination;
- `Tackle.fork_session/2` materializes a self-contained session from validated
  parent history, so the child survives deletion of the parent;
- `Tackle.delete_session/2` moves an inactive session into `sessions/trash/` and
  refuses to delete an active one; and
- `Tackle.flush_session/1` runs an explicit durability barrier.

Internal `.dlog` files are trusted local state, never a portable interchange
format, and are not accepted as imports. Search indexes the title, user and
assistant text, `cwd`, and tags by default; it excludes reasoning, provider
continuation state, tool arguments, and tool output. Checkpoints and in-place
migration are deliberately not implemented yet. See
[`docs/SESSION_ARCHITECTURE.md`](../../docs/SESSION_ARCHITECTURE.md) for the accepted
architecture and its remaining deferrals.

The [CLI guide](../../apps/tackle_cli/README.md) documents `run --resume`,
`--abandon`, session search, and the terminal usage chart. Journal repair
preserves the original under the session's `recovery/` directory; it does not
silently resolve an interrupted turn. Hosts must decide whether to abandon it.

## Conversation trees

Durable root sessions can keep their history as an optional conversation tree,
so a session can hold alternative paths instead of a single linear transcript. The
engine owns the tree rules in `Tackle.Lib.Tree`; the harness package owns durable
records and the CLI owns the picker. A tree is opt-in for library hosts
(`Tackle.Lib.new(tree: true)`), and durable root sessions enable it by default.

Three surfaces are deliberately distinct:

- the **canonical tree** holds every settled entry on every branch, once;
- the **active transcript** (`Tackle.Lib.messages/1`) is the selected branch and
  is never compacted; and
- the **model context** (`Tackle.Lib.model_messages/1`) is the selected branch
  with the compactions that occur on that path applied.

`Tackle.Lib.usage/1` aggregates assistant usage across the whole archive while
`Tackle.Lib.branch_usage/1` follows the active path. `Tackle.Lib.context_usage/1`
reports the model projection, so branch switches reset context pressure to the
selected branch.

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

# Return to the empty conversation before the first message.
{:ok, _snapshot, _outcome} = Tackle.navigate(scope.root_agent_ref, nil)
```

The [CLI guide](../../apps/tackle_cli/README.md#conversation-tree-tree)
documents the terminal tree picker. Navigation changes conversation history,
not workspace files; it never undoes tool side effects.

Existing linear journals still load unchanged: their chain becomes the initial
tree, and the first branching write records an explicit `tree.enabled`
transition rather than rewriting the source file. `Tackle.fork_session/2`
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
directories from the working directory up to the Git root, and in
`~/.agents/skills`. The system prompt includes only skill names, descriptions,
and paths; the model loads the body with its file tool on demand. Project skills
nearest the working directory take precedence. Missing descriptions, unreadable
files, or malformed frontmatter cause a warning and the skill is skipped;
invalid names or overlong descriptions warn but still load. Unlike subagent
definitions under `$TACKLE_HOME/agents` and `.tackle/agents`, user skills live
under `~/.agents/skills` **regardless of `TACKLE_HOME`**.

## Configuration and credentials

`Tackle.Config.load/1` applies this precedence:

```text
built-in defaults < ~/.tackle/config.json < TACKLE_MODEL/TACKLE_THINKING < explicit overrides
```

`TACKLE_HOME` changes the directory containing `config.json` and `auth.json`.
The configuration file accepts `model` and `thinking` fields. Thinking may be
`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or `max`; supported levels can vary
by model. `TACKLE_THINKING` overrides the file in the same way that
`TACKLE_MODEL` overrides `model`. Adapter modules are always supplied as
executable code, never converted from JSON strings.

Configured sessions retry transient provider-message failures three times by
default, using deterministic exponential delays of 2, 4, and 8 seconds with a
60-second cap. Programmatic callers can set `retry: false` or pass
`retry: [max_retries: ..., base_delay_ms: ..., max_delay_ms: ...]` to
`Tackle.Config.new/1`. Authentication, quota/billing, context overflow,
cancellation, and unknown failures are not transient retries.

Configured sessions also build an effective coding prompt for their working
directory. The built-in prompt lists the selected tools and core coding
guidelines. The following optional UTF-8 files customize it:

- `$TACKLE_HOME/SYSTEM.md` replaces the built-in base prompt;
- `$TACKLE_HOME/APPEND_SYSTEM.md` appends global user guidance;
- `$TACKLE_HOME/AGENTS.md` supplies global agent instructions; and
- `AGENTS.md` files from the filesystem root through the working directory are
  included from broadest to most specific.

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

`Tackle.Auth` stores one opaque map per provider in `~/.tackle/auth.json` and
injects only a non-secret `Tackle.Lib.CredentialStore` handle into adapter
options. Credential-shaped `llm_opts` keys (including nested token, API-key,
password, and authorization fields) are rejected; provider secrets belong only
in the credential store. The file is plaintext protected by filesystem
permissions (`0700` for the directory and `0600` for the file), not encryption.
Writes are atomic and serialized within one Tackle application; cross-VM
locking and OS keyrings are deferred.

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
