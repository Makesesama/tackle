# Tackle architecture specification

Status: architectural direction implemented; later plugin/distribution items remain proposals.
Scope: package boundaries, composition, frontend independence, and migration order.
This document distinguishes implemented package boundaries from explicitly future work.

## 1. Agreed decisions

1. The repository-root application is the Tackle developer harness. Its implementation lives in `lib/tackle`, with `lib/tackle.ex` as its public facade.
2. The harness owns configuration reading and plugin composition. Reusable scoped supervision, subagents, limits, and workflows live in `packages/tackle_runtime`; host-specific sessions, persistence, authorization, and billing remain in adapters.
3. Rename the existing reusable library from `packages/tackle` to `packages/tackle_lib`, preserving its implementation and capabilities rather than replacing or copying its engine.
4. Give the library the OTP application identity `:tackle_lib` and namespace `Tackle.Lib.*`. The harness retains `:tackle` and `Tackle.*`.
5. The harness is frontend-agnostic. Build a CLI first; a future web frontend uses the same harness API and session lifecycle.
6. Provider adapters are plugins. The first-party Codex adapter uses the same provider-neutral library contract as third-party adapters.

The package move and library namespace change explicitly supersede the current README/AGENTS requirement to retain the library at `packages/tackle`. Update those instructions when implementing the migration.

## 2. Target repository layout

```text
mix.exs                          # :tackle — developer harness application
lib/
  tackle.ex                      # Public harness facade
  tackle/
    application.ex               # Harness supervision
    config.ex                    # Read, resolve, and validate configuration
    plugins.ex                   # Resolve and compose configured plugins
    session.ex                   # Session ownership and turn coordination

test/                            # Harness tests

packages/
  tackle_lib/                    # :tackle_lib, Tackle.Lib.*
    mix.exs
    lib/
      tackle_lib.ex              # Tackle.Lib facade
      tackle_lib/                # Existing reusable engine and contracts
    test/
  tackle_runtime/                # :tackle_runtime, Tackle.Runtime.* orchestration
  tackle_phoenix/                 # Existing optional Phoenix integration
  tackle_anubis/                  # Optional Anubis MCP bridge (extracted from tackle_lib)

plugins/
  tackle_codex/                  # Planned first-party provider plugin
  tackle_dev_tools/              # Proposed bundled developer-tool package
  tackle_mcp/                    # Future harness-side MCP plugin; not the Anubis bridge

frontends/
  tackle_cli/                    # CLI entrypoint and terminal presentation
  tackle_web/                    # Future web application, not built now
```

The supporting modules above describe responsibilities, not a requirement to create every file immediately. Keep each implementation as small as its actual use case permits.

Retain separate Mix projects rather than introducing an umbrella in this work. Implemented plugins and frontends have their own Mix projects, dependencies, and tests. Do not create empty projects for future features.

Proposed component identities:

| Component | OTP application | Namespace |
| --- | --- | --- |
| Harness | `:tackle` | `Tackle.*` |
| Library | `:tackle_lib` | `Tackle.Lib.*` |
| Scoped runtime | `:tackle_runtime` | `Tackle.Runtime.*` |
| Existing Phoenix integration | `:tackle_phoenix` | `Tackle.Phoenix.*` (unchanged) |
| Anubis MCP bridge | `:tackle_anubis` | `Tackle.Anubis.*` |
| Codex plugin | `:tackle_codex` | `Tackle.Plugins.Codex.*` |
| Developer tools | `:tackle_dev_tools` | `Tackle.Plugins.DevTools.*` |
| CLI | `:tackle_cli` | `Tackle.CLI.*` |
| Future web frontend | `:tackle_web` | `Tackle.Web.*` |

## 3. Responsibility and dependency boundaries

### Reusable library: `packages/tackle_lib`

Owns the existing agent loop, state, messages, usage, snapshots, events, cancellation primitives, tool settlement, and extension behaviours.

Its public facade becomes `Tackle.Lib`; examples of migrated contracts are `Tackle.Lib.LLM`, `Tackle.Lib.Tool`, `Tackle.Lib.Hook`, and `Tackle.Lib.PromptRenderer`.

It must not depend on the harness, a frontend, a concrete provider, or developer-specific tools. A different application can use this package to build its own harness without depending on `:tackle`.

The inherited optional MCP bridge was extracted into `packages/tackle_anubis`
(`:tackle_anubis` / `Tackle.Anubis.*`, a breaking rename of
`Tackle.Lib.Integrations.Anubis`) so the library keeps no MCP dependency and only
the provider-neutral `Tackle.Lib.Integrations.Registry` seam.

### Reusable runtime: `packages/tackle_runtime`

Depends only on `tackle_lib` and owns scoped OTP supervision, stable references,
admission limits, per-agent tool supervision, delegated requests, cancellation,
fan-out, and workflows. Hosts implement `Tackle.Runtime.AgentBackend` so tenant,
persistence, billing, credentials, and local-session policy stay outside the
runtime package.

### Developer harness: root `lib/tackle`

Owns:

- Reading and validating developer-harness configuration.
- Resolving explicitly configured plugins and composing their contributions.
- Selecting model, adapter, tools, hooks, and developer prompts.
- Root `Tackle.Session` persistence, journals, credentials, and the runtime backend that adapts them.
- Handling normal results and task failures through the reusable runtime.
- Exposing shared commands, session snapshots, and event delivery to frontends.

The harness invokes `Tackle.Lib`; it does not implement another agent loop or provider protocol.

Use OTP processes for real ownership, concurrency, and supervision. Configuration parsing and plugin validation can remain ordinary functions. Do not add an application-wide plugin server simply to hold a list of modules.

### Plugins: `plugins/`

Provider translation and optional capabilities live outside the harness and library.

- Codex implements `Tackle.Lib.LLM`, including protocol translation, authentication integration, and streaming normalization through the library contract.
- Developer tools implement `Tackle.Lib.Tool`. Group related filesystem/shell tools in one package initially rather than making one package per operation.
- Hooks and prompt renderers use existing library behaviours.
- A plugin that genuinely needs harness lifecycle services may use a small explicit harness contract; ordinary providers and tools should remain reusable without that dependency.

Bundled plugins have no privileged execution path. Being shipped with the product does not imply being enabled for every session.

### Frontends: `frontends/`

Frontends own user interaction and presentation, not agent execution policy.

The CLI owns argument parsing, terminal input/output, rendering, and signal/shortcut translation. It passes explicit overrides into harness configuration resolution rather than implementing a separate configuration policy.

A future web frontend owns routes, authentication, browser transport, rendering, and authorized access to sessions. It must not trust browser-supplied tool permissions or expose raw session context and credentials.

Neither frontend calls provider APIs, duplicates the agent loop, or becomes the authoritative owner of shared session state.

### Dependency direction and executable composition

```text
CLI / future Web  ──>  Tackle harness  ──>  Tackle.Lib
                                               ^
Provider / tool plugins  ───────────────────────┘

Harness configuration selects available plugin implementations.
```

The root harness does not depend on CLI or Web. Each frontend executable/application depends on the harness and declares the bundled plugin dependencies needed for that distribution. This keeps the dependency graph acyclic while allowing the harness to load and configure those available plugins.

Distinguish distribution composition from runtime composition: the executable supplies available packages; `Tackle.Plugins` resolves and configures their contributions. Exact release/Burrito assembly remains undecided and is not part of this specification's implementation approval.

## 4. Shared frontend contract

Start with a small in-process Elixir API. A future web frontend can translate it into HTTP/WebSocket interactions without requiring the harness to become a network service now.

Required operations, with exact signatures deferred:

- Create/start a session with validated configuration and trusted context.
- Submit input and start a supervised turn.
- Retry/continue without appending the user message again.
- Request cooperative cancellation.
- Read a consistent session snapshot.
- Subscribe/unsubscribe to session events and terminal outcomes.
- Explicitly close a session and clean up its resources.

Suggested lifecycle rules:

- One active turn per session initially; reject overlapping submissions explicitly.
- Session ownership remains in the harness, not in a terminal input loop or LiveView process.
- Tag deliveries with session and turn identity so frontends can reject stale updates.
- Reuse `Tackle.Lib.Event`; add only the delivery metadata needed at the harness boundary.
- Report terminal success, cancellation, expected failure, and task crash distinctly.
- Keep event callbacks fast and avoid doing rendering in the turn task.
- Specify snapshot/subscription ordering before supporting attachment during active turns, so updates cannot silently disappear in the gap.

The initial contract can use callbacks or local process messages. Do not introduce a general event bus, durable event log, or mandatory Phoenix PubSub dependency.

A frontend disconnect must not accidentally define turn semantics. Explicit cancellation and session closure belong to the harness API; graceful CLI exit can invoke them. Crash/disconnect cleanup policy must be documented before implementation.

Future approval prompts must use structured requests and correlated responses, not `IO.gets/1` inside a tool or provider. The UI presents the request; harness/tool policy validates the response. Do not implement this mechanism before an actual approval use case requires it.

## 5. Configuration and plugin loading

The harness owns these concerns; the exact configuration file format, search locations, and plugin distribution mechanism are still open.

Proposed minimal approach:

1. Read explicitly supported configuration sources.
2. Merge them with documented, deterministic precedence.
3. Validate configuration and configured modules before starting provider work.
4. Resolve provider, tools, hooks, and prompt renderer through existing contracts.
5. Freeze resolved execution settings for a turn using the library's snapshot model.

Prefer explicit module/package configuration initially. Do not add filesystem-wide discovery, automatic package installation, arbitrary runtime compilation, hot reload, or a generic plugin manifest framework without a concrete requirement and separate decision.

Loading an already available module is not the same as downloading/installing a plugin. Running BEAM plugin code grants that code the application's privileges; this is not a sandbox or security boundary.

Provider selection must work per session/turn without mutating application-global configuration to switch providers. Inspect the existing adapter resolution path and add the smallest explicit option if needed, while preserving sensible library defaults.

Keep secrets out of logged configuration, events, persisted snapshots, and frontend-visible data. Provider credential resolution stays at the adapter/configuration boundary, never in terminal rendering.

## 6. Existing Phoenix integration

`packages/tackle_phoenix` is a reusable integration package, not the future Tackle web frontend. It can continue serving other applications that use the library directly.

During the library rename, update its dependency, structs, behaviours, and calls to `Tackle.Lib.*`; preserve its existing `Tackle.Phoenix.*` API and semantics otherwise.

Its Runner already contains session supervision, cancellation, and settlement machinery. Inspect that overlap before implementing the harness session owner. Do not make the CLI depend on Phoenix, copy the entire Runner, or silently move/remove the existing API.

If extracting reusable OTP machinery is justified, propose the narrow extraction and compatibility strategy separately. Do not generalize host-specific persistence/billing behaviour into the developer harness merely because the existing Runner supports it.

## 7. Migration and delivery sequence

### Stage 1: Mechanical library identity migration

- Move the maintained package to `packages/tackle_lib`, retaining its tests and functionality.
- Rename the library facade and library-owned `Tackle.*` modules to `Tackle.Lib.*`.
- Rename its Mix project module to a distinct identity such as `Tackle.Lib.MixProject`, and change the OTP application to `:tackle_lib`.
- Move library-owned application configuration reads/writes and examples from `:tackle` to `:tackle_lib`. Root harness configuration remains under `:tackle`.
- Update `tackle_phoenix`, test support, docs, path dependencies, and references in tooling. Classify references by ownership rather than replacing every `Tackle` or `:tackle` occurrence globally.
- Inspect explicit application-loading calls and string-based module references as well as aliases and structs.
- Preserve persisted/wire identifiers and telemetry names unless a separately documented change is necessary; namespace changes do not automatically justify changing event contracts.
- Add the root dependency on `:tackle_lib` only after collisions are resolved.
- Update README and AGENTS paths and migration guidance for downstream consumers.
- Regenerate affected generated dependency metadata using its owning tool when needed; do not hand-edit generated Nix output.

This is an intentional breaking library migration. Do not add broad compatibility aliases without a specific consumer requirement: old `Tackle` names now belong to the harness.

### Stage 2: Small frontend-neutral harness

- Resolve the Phoenix lifecycle overlap described above.
- Implement validated explicit configuration and module composition.
- Expose minimal session/turn/cancellation/events operations.
- Demonstrate the full flow with fake adapters and tools, without a frontend.
- Establish per-session provider isolation and resource cleanup tests.

### Stage 3: CLI and shipped capabilities

- Implement a thin CLI using only the shared harness operations for execution.
- Implement Codex through the same contract exercised by fake/third-party adapters.
- Select and implement the initial developer tools as an explicitly scoped package.
- Keep adapter protocol tests, harness tests, and terminal interaction tests separate.

### Later, separately scoped

- Decide and validate binary packaging and third-party plugin distribution.
- Extract MCP with an explicit compatibility strategy. Done for the Anubis server
  bridge: it is now `packages/tackle_anubis`; a harness-side MCP client plugin
  remains future work.
- Build a web frontend when needed; do not introduce web-only dependencies now.

## 8. Validation and acceptance

The architecture is satisfied when:

- An independent Mix host can depend only on `:tackle_lib` and run a deterministic agent turn.
- The root harness and library compile together without duplicate application or module identities.
- A fake/custom provider can replace Codex through configuration without core changes.
- Two sessions can select different adapters without changing global configuration between turns.
- Harness tests drive input, streaming, retry, cancellation, failure, and session snapshots without terminal IO or Phoenix.
- CLI tests prove presentation and input translation use that same harness path.
- Library tool settlement and existing Phoenix integration behaviour remain covered after migration.
- Optional dependencies do not become mandatory dependencies of the minimal harness.

Run compile-with-warnings-as-errors, tests, and formatting checks separately for each affected Mix project; root checks do not recurse. Use the configured Nix toolchain and report unavailable dependencies/caches as blockers. Finish implementation stages with `git diff --check` and a focused diff review.

For the identity migration specifically, run the existing library suite at its new path, the existing Phoenix suite, and root checks. For new plugin/frontend projects, define their checks when those projects are actually introduced.

## 9. Open decisions before their implementation

- Configuration format, locations, precedence, and credential sourcing.
- Exact plugin declaration/loading contract and bundled plugin enablement defaults.
- Exact frontend API signatures, delivery ordering, and disconnect/session lifetime policy.
- Minimal reuse strategy for existing Phoenix Runner lifecycle machinery.
- Initial developer-tool set and its filesystem/process permission policy.
- Whether/when session persistence is needed; in-memory sessions are sufficient initially.
- Binary release composition and supported third-party plugin installation workflow.

These questions must not delay the mechanical identity migration, but must be settled before implementing the respective behaviour. No marketplace, distributed session system, mandatory database, or speculative plugin framework is implied by this design.
