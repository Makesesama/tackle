# Tackle

Tackle is an Elixir agent harness for developers, built around a small core and
an extensible, plugin-first architecture.

It starts with an in-house agent library already used in a SaaS application.
The reusable library now lives at [`packages/tackle_lib`](packages/tackle_lib)
under the `Tackle.Lib` namespace, while the repository root remains the `Tackle`
developer harness—not the SaaS application turned into a CLI.

## Goals

- **Small core:** keep lines of code and dependencies low. Prefer removing
  unnecessary machinery to adding abstractions, without sacrificing clarity.
- **High code quality:** readable, idiomatic Elixir; explicit contracts;
  focused modules; deterministic tests.
- **Extensibility first:** users should be able to add capabilities without
  modifying the core. Optional features belong in plugins.
- **CLI first:** begin with a simple, usable command-line frontend, separate
  from the agent engine.
- **Binary distribution:** package the harness with Burrito after the basic
  CLI and extension boundaries are working.

## Architecture direction

| Layer | Responsibility |
| --- | --- |
| `packages/tackle_lib` | Reusable, provider- and frontend-independent agent library (`Tackle.Lib`). |
| Developer harness | Minimal composition and runtime glue for the library, configuration, and plugins. |
| CLI frontend | Terminal input/output and interaction; no duplicate agent loop. |
| Plugins | Provider adapters and optional capabilities, using explicit extension contracts. |
| Burrito release | Binary packaging of the harness, not a new runtime abstraction. |

Keep the core focused on the agent loop and the contracts needed to extend it.
Provider protocols, frontend concerns, and optional integrations must not drive
core policy or force unrelated dependencies into it. Reuse existing library
behaviours and hooks before inventing a parallel extension framework.

### Adapters and plugins

Provider adapters are user-provided plugins. **OpenAI Codex is the only adapter
this project plans to implement and maintain**, and it should use the same
extension contracts as third-party adapters, not a privileged core code path.

MCP is available as an optional harness plugin in
[`plugins/tackle_mcp`](plugins/tackle_mcp). It uses Anubis as an MCP **client**
and turns external MCP tools into ordinary `Tackle.Lib.Tool` modules; it is not
a required root dependency. The inherited Anubis MCP **server** bridge remains
in `packages/tackle_anubis`, so both directions stay outside the MCP-free core.
Other optional integrations should follow the same separation. Phoenix and
SaaS-specific concerns are not requirements for the standalone harness.

Plugin discovery, loading, and distribution are not yet specified. In
particular, how user-provided plugins work with a Burrito binary needs to be
resolved and tested before promising a binary plugin workflow.

## Current state

This repository is a starting point, not a finished CLI:

- The root Mix project provides frontend-independent adapter/model
  configuration, composes the reusable scoped runtime, a supervised credential store,
  and built-in `read`, `bash`, `elixir_eval`, `edit`, and `write` developer tools
  under `Tackle.Tools.*`. It composes a coding system prompt with global and
  project `AGENTS.md` guidance, and discovers Agent Skills from `.agents/skills`
  directories so the model can load them on demand. Configuration loads from
  `~/.tackle/config.json`, environment, and explicit overrides without loading
  modules from data.
- [`packages/tackle_lib`](packages/tackle_lib/README.md) contains the existing
  agent library and its API documentation (`Tackle.Lib.*`).
- [`packages/tackle_runtime`](packages/tackle_runtime/README.md) contains the
  reusable scoped OTP runtime: supervision, limits, subagents, fan-out, and
  workflows (`Tackle.Runtime.*`).
- [`packages/tackle_phoenix`](packages/tackle_phoenix/README.md) contains the
  Phoenix integration and a runtime backend that preserves Store lifecycle
  hooks for root and delegated agents; it is not the intended CLI foundation.
- The library carries no MCP code or dependency. The inherited Anubis MCP bridge
  was extracted into [`packages/tackle_anubis`](packages/tackle_anubis/README.md)
  (`:tackle_anubis` / `Tackle.Anubis.*`), a breaking rename of the former
  `Tackle.Lib.Integrations.Anubis`; `tackle_lib` keeps only the provider-neutral
  `Tackle.Lib.Integrations.Registry` seam.
- [`plugins/tackle_codex`](plugins/tackle_codex/README.md) contains the
  first-party OpenAI Codex adapter, including ChatGPT OAuth protocol helpers,
  token refresh, Responses SSE transport, and provider-neutral translation.
- [`plugins/tackle_mcp`](plugins/tackle_mcp/README.md) contains the optional
  Anubis-based MCP client plugin. Trusted host startup can connect STDIO or
  Streamable HTTP servers, discover their tools, and add the returned proxy
  modules to a session's normal `:tools` list. The plugin currently bridges
  tools only and is not bundled by the CLI.
- [`frontends/tackle_cli`](frontends/tackle_cli/README.md) contains the default
  Optimus/ex_ratatui CLI entrypoint. Its Burrito release produces a fixed
  distribution that bundles the first-party Codex and DeepSeek plugins; runtime
  plugin discovery remains deferred. The frontend relies on the root harness
  for credentials, sessions, and turn execution. Its footer reports current
  context pressure plus aggregate input/output, preceding-prompt cache reuse,
  and cost when the selected adapter exposes them.
- General extension project loading remains planned work; Burrito packaging is
  now configured in the CLI frontend.

The root harness owns OTP application `:tackle` and namespace `Tackle`. The
reusable library owns OTP application `:tackle_lib` and namespace `Tackle.Lib`;
the reusable runtime owns OTP application `:tackle_runtime` and namespace
`Tackle.Runtime`; the CLI frontend owns OTP application `:tackle_cli` and
namespace `Tackle.CLI`. These identities are intentionally separate. This is a breaking
library migration: downstream users must change package paths, module
references, and library configuration from `:tackle`/`Tackle.*` to
`:tackle_lib`/`Tackle.Lib.*`. The Phoenix integration keeps its
`:tackle_phoenix` and `Tackle.Phoenix.*` identities.

## CLI during development

Fetch the separate frontend project's dependencies once, then run the CLI from
the repository root:

```sh
(cd frontends/tackle_cli && mix deps.get)
mix tackle --help
mix tackle
```

The root task delegates to `frontends/tackle_cli` so its terminal and provider
dependencies remain outside the root harness. Running `mix tackle` directly
inside `frontends/tackle_cli` remains supported.

### Sandboxed dogfooding on Linux

The development shell also provides `jailed-tackle`, a Bubblewrap launcher built
with [`jailed-agents`](https://github.com/andersonjoseph/jailed-agents):

```sh
nix develop
jailed-tackle
```

Run it from the repository root. The jail gives Tackle read-write access to the
entire current working directory, to `~/.tackle`, and to the configured Ketch
research client and its `/home/makussu/.config/ketch/config.json` configuration.
Network access is enabled for provider and research calls. Other home-directory
contents and host control sockets are not mounted, and the host Nix daemon
remains unavailable. Tackle can still
modify or delete anything in the repository, including `.git`, so keep valuable
work committed or backed up. The launcher is Linux-only because it relies on
Bubblewrap and Linux namespaces.

### Production jailed package on Linux

`tackle-cli-jail` provides `bin/tackle`, wraps the production Burrito package,
and runs from any project folder with Nix builds enabled. It is separate from
the checkout-based `jailed-tackle` development launcher above:

```sh
# From the Tackle repository root:
nix build .#tackle-cli-jail --out-link result-jailed
./result-jailed/bin/tackle --version
./result-jailed/bin/tackle
```

The new package requires a multi-user Nix installation with the daemon socket at
`/nix/var/nix/daemon-socket/socket`, `/etc/nix/nix.conf`, and working Bubblewrap
user namespaces. It mounts the current directory and `~/.tackle` read-write;
Burrito extracts into `~/.tackle/burrito/.burrito`. It does not enable
`TACKLE_DEV`, mount Ketch configuration, or require Mix to launch the CLI.
`TACKLE_MODEL` and `TACKLE_THINKING` are forwarded; credentials come from
`~/.tackle/auth.json`. This launcher fixes `TACKLE_HOME` to `~/.tackle`.

**Nix access weakens isolation:** the whole host `/nix` tree is readable, including
store paths containing source or configuration. The daemon socket is accessible,
so the agent can request host builds and other daemon operations allowed for your
user. A trusted Nix user has additional powers; this is not a boundary against a
hostile agent. Network access is enabled, and project files (including `.git`)
and Tackle state can be modified or deleted. Other home files, SSH credentials,
and unrelated host control sockets are not mounted.

Inside the jail, `nix build` and `nix develop --command ...` use the host daemon
with flakes enabled. The full read-only store mount makes new build outputs and
their symlink targets visible immediately, avoiding per-path closure enumeration
and stale/GC'd cached-direnv references. Automatic sourcing of the launch shell's
or nested cached direnv environments is **not implemented**; use `nix develop`
explicitly. Host user Nix configuration, private-fetch credentials, and arbitrary
devshell environment variables are not forwarded. Daemon-side build sandboxing
continues to follow the host's Nix configuration.

A credential-free host smoke test checks a real offline Nix build inside the
jail, visibility of its new output, hidden home files, production environment,
and the packaged CLI's informational commands:

```sh
nix build .#tackle-cli-jail.tests.smoke --out-link result-jail-test
./result-jail-test/bin/test-jailed-tackle-cli
```

Run this on the host, not inside the old development jail or a Nix build sandbox.
Also open the actual jailed TUI and exit with Ctrl+C to check native startup.
The jail wrapper is a Nix package, not a second portable single-file executable;
keep `tackle-cli` for the unjailed, copyable Burrito artifact.

## Basic harness API

The harness accepts already-loaded adapter and capability modules. General
extension-project discovery remains out of scope; configuration data and
frontend arguments only select models declared by modules supplied by the
distribution. If no model is configured, the harness picks the first model
reference exposed by the configured adapters.

Execution is scoped. `Tackle.start_scope/1` starts one root agent plus every
descendant it may create and returns a PID-free `Tackle.Runtime.Scope`:

```elixir
config :tackle, adapters: [MyCodexAdapter]

{:ok, config} =
  Tackle.load_config(
    overrides: [model: "openai-codex/gpt-5.5", thinking: "high"]
  )

root_spec = Tackle.Runtime.AgentSpec.new!(name: "root", config: config)
scope_spec =
  Tackle.Runtime.ScopeSpec.new!(
    backend: Tackle.Runtime.RootBackend,
    root_spec: root_spec,
    profiles: %{}
  )

{:ok, scope} = Tackle.start_scope(scope_spec)

{:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
{:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "Inspect this project")

:ok = Tackle.stop_scope(scope.scope_ref)
```

`Tackle.load_config/1` loads exactly one agent's execution configuration.
Trusted host or distribution code composes that value into an `AgentSpec` and
`ScopeSpec` before starting the runtime; model-generated data may only select a
trusted profile name.

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

Each agent permits one active turn. `Tackle.continue/1` retries the settled
conversation without adding another user message, `Tackle.cancel/1` requests
cooperative cancellation, and `Tackle.stop_scope/1` stops the whole scope.
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
bindings do not carry between calls. These tools inherit the Tackle process's filesystem and
operating-system permissions and are not a sandbox. `Tackle.Lib` provides the
`:telemetry` runtime dependency used by tool execution.

### Configured subagents

The coding harness includes `scout`, `reviewer`, and `worker` profiles and discovers additional
subagent definitions from Markdown files. User definitions live recursively
under `$TACKLE_HOME/agents`; project definitions live under the nearest
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
model: openai-codex/gpt-5.5
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
not already available to the root harness fail startup explicitly.

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

CLI sessions enable three built-in profiles by default, including new sessions
opened inside the TUI and resumed sessions:

- `scout` performs fast, read-only codebase reconnaissance with `read` and `bash`;
- `reviewer` performs read-only correctness, regression, and security review with
  `read` and `bash`;
- `worker` performs implementation tasks with the root harness trusted coding tools.

The former `explorer` profile is no longer built in. The root calls `subagent`
with one of these profile names and a self-contained `prompt`. Each child has a
fresh conversation, shares the configured working directory, and returns its
result through a dedicated inline tool card. The card
shows profile, assignment, status, and a live local elapsed clock; F4 retains
full arguments and findings. Timing is transient observation data, not persisted
provider latency. Parallel calls keep separate cards. Built-in children cannot
delegate; scout and reviewer are instructed not to edit files.
**This is not a read-only sandbox:** bash retains the harness's filesystem,
network, and OS permissions. Do not use this profile as an isolation boundary.

`Tackle.Coding.scope_spec/2` owns this composition in the root harness. It loads
normal global/project guidance for root and child agents, advertises the profiles to the
root, and limits the scope to two simultaneous children plus the root. Excess
requests are rejected rather than queued. Children have unlimited loop iterations
by default and a five-minute run timeout; `maxIterations` or a narrower root
iteration limit can still bound an individual child. Stopping the scope cleans up
children. The one-shot CLI allows six minutes of event silence so it does not
interrupt a child at the previous one-minute frontend timeout.

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
independent of the launching root turn: Esc may cancel that turn and the root
may accept new direction while the child keeps running. It remains owned by the
same root session and scope, so starting a new CLI session or otherwise stopping
that scope cleans it up. If cancellation wins
the race before the launch tool result is committed, the run ID is queued into
the root agent's next turn so it can still use `subagent_wait` or
`subagent_status`. The footer and usage charts currently count root usage only,
**not child usage or total delegation cost**.
Persistent child conversations and reusable agents remain deferred. General
runtime scopes and `Tackle.Tools.default/0` do not automatically gain subagent
capability.

### Durable sessions

A root scope can own one durable session journal. Add a
`Tackle.Session.Spec` to the `ScopeSpec` and the scope stores an append-only
internal `:disk_log` under `$TACKLE_HOME/sessions/<session-id>/session.dlog`.
The CLI does this by default, so every CLI root conversation is durable.

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
[`docs/SESSION_ARCHITECTURE.md`](docs/SESSION_ARCHITECTURE.md) for the accepted
architecture and its remaining deferrals.

The CLI exposes durable sessions directly:

```sh
tackle run "explain this module"          # new durable session
tackle run --resume <session-id> "carry on"
tackle run --resume                       # most recently updated session
tackle run --resume <session-id> --abandon "continue after a crash"
tackle sessions                           # newest sessions first
tackle sessions --query "cache invalidation" --limit 10
```

`--resume` without a session id continues the most recently updated session.
When the terminal frontend exits it prints the `--resume` command for the
session it was last attached to. In the TUI, `F6` opens a cumulative token-usage
chart and switches between the complete current session and the current UTC
calendar week across all durable sessions. Fork-copied message records are
counted once in the global view.

The CLI automatically runs controlled journal repair when a resumed session was
not closed cleanly. The original journal is preserved under the session's
`recovery/` directory and recovered history is validated before use. Repair does
not silently resolve an interrupted turn; pass `--abandon` to record that
separate recovery decision.

### Conversation trees

Durable CLI sessions keep their history as an optional conversation tree, so a
session can hold alternative paths instead of a single linear transcript. The
engine owns the tree rules in `Tackle.Lib.Tree`; the root harness owns durable
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

# Move to the parent of an earlier user message and get it back as a draft.
{:ok, _snapshot, outcome} = Tackle.navigate(scope.root_agent_ref, {:edit, user_message_id})
outcome.draft.content

# Return to the empty conversation before the first message.
{:ok, _snapshot, _outcome} = Tackle.navigate(scope.root_agent_ref, nil)
```

In the terminal, `/tree` (or `F5`) opens a search-first picker over the tree.
Selecting a user message moves to its parent and, when the composer is
untouched, fills it with that message so submitting the edit creates a sibling
branch. Selecting other entries moves to them. Escape closes the picker without
changing the conversation or the draft, and the picker states plainly that
navigation does not undo workspace changes.

Existing linear journals still load unchanged: their chain becomes the initial
tree, and the first branching write records an explicit `tree.enabled`
transition rather than rewriting the source file. `Tackle.fork_session/2`
remains sequence-based and copies the tree and active position into the
self-contained child. See [`docs/SESSION_TREE_PLAN.md`](docs/SESSION_TREE_PLAN.md)
for the implemented first version and the deliberately deferred increments.

### Breaking migration to scoped runtime

Session-PID startup is replaced by scope startup: `Tackle.start_session/1`,
`Tackle.start_configured_session/1`, and PID-based `Tackle.close/1` are removed.
Agent operations now take a `Tackle.Runtime.AgentRef` and shutdown takes a
`Tackle.Runtime.ScopeRef`. The `allow_recursion` grant is renamed
`allow_delegation`. There is no compatibility wrapper: a session PID is not the
lifecycle or addressing unit of the runtime.

## Configuration and credentials

`Tackle.Config.load/1` applies this precedence:

```text
built-in defaults < ~/.tackle/config.json < TACKLE_MODEL/TACKLE_THINKING < explicit overrides
```

`TACKLE_HOME` changes the directory containing `config.json` and `auth.json`.
The configuration file accepts `model` and `thinking` fields. Thinking may be
`off`, `minimal`, `low`, `medium`, `high`, or `xhigh`; supported levels can vary
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
  "model": "openai-codex/gpt-5.6-sol",
  "thinking": "high"
}
```

`Tackle.Auth` stores one opaque map per provider in `~/.tackle/auth.json` and
injects only a non-secret `Tackle.Lib.CredentialStore` handle into adapter
options. Credential-shaped `llm_opts` keys (including nested token, API-key,
password, and authorization fields) are rejected; provider secrets belong only
in the credential store. The file is plaintext protected by filesystem
permissions (`0700` for the directory and `0600` for the file), not encryption.
Writes are atomic and
serialized within one Tackle application; cross-VM locking and OS keyrings are
deferred.

## Initial milestones

1. Build the smallest useful developer harness and CLI around the existing
   library, with explicit extension boundaries.
2. Implement the OpenAI Codex adapter through those boundaries and demonstrate
   that a user-provided adapter can be substituted without editing the core.
3. Package the fixed first-party distribution with Burrito; then design and
   verify the user-provided plugin workflow separately.
4. Add optional capabilities as separate plugins; the first MCP tools client is
   implemented in `plugins/tackle_mcp`, while CLI configuration and general
   extension loading remain later integration work.

Avoid a plugin marketplace, speculative frameworks, or additional frontends
before the minimal harness works.

## Development

The root project requires Elixir `~> 1.20`; the existing packages declare
`~> 1.18`. The Nix development shell selects Elixir 1.20 and Erlang/OTP 29.
Enter it with `nix develop`, or use the repository's direnv setup.

```sh
# Root harness
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted

# Agent library (a separate Mix project)
(cd packages/tackle_lib && mix deps.get && mix test)

# Existing Phoenix integration, when working on it
(cd packages/tackle_phoenix && mix deps.get && mix test)

# First-party OpenAI Codex plugin
(cd plugins/tackle_codex && mix deps.get)
(cd plugins/tackle_codex && mix compile --warnings-as-errors && mix test)
(cd plugins/tackle_codex && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# MCP client plugin
(cd plugins/tackle_mcp && mix deps.get)
(cd plugins/tackle_mcp && mix compile --warnings-as-errors && mix test)
(cd plugins/tackle_mcp && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# CLI frontend
(cd frontends/tackle_cli && mix deps.get)
(cd frontends/tackle_cli && mix compile --warnings-as-errors && mix test)
(cd frontends/tackle_cli && mix format --check-formatted)
(cd frontends/tackle_cli && mix escript.build)
```

These are separate Mix projects, not an umbrella: root checks do not validate
all packages. Dependency fetching needs network access and writable Mix/Hex
caches. No dynamic plugin installation command is available yet. Burrito build
commands and native-library requirements are documented in
[`frontends/tackle_cli/README.md`](frontends/tackle_cli/README.md).

See [AGENTS.md](AGENTS.md) for contributor and coding-agent guidance.
