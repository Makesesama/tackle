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

MCP is a **future plugin for the harness**, not a required root dependency.
The reusable library retains its inherited optional Anubis MCP bridge during
this identity migration; other optional integrations should follow the same
separation. Phoenix and SaaS-specific concerns are not requirements for the
standalone harness.

Plugin discovery, loading, and distribution are not yet specified. In
particular, how user-provided plugins work with a Burrito binary needs to be
resolved and tested before promising a binary plugin workflow.

## Current state

This repository is a starting point, not a finished CLI:

- The root Mix project provides frontend-independent adapter/model
  configuration, supervised in-memory sessions, a supervised credential store,
  and built-in `read`, `bash`, `elixir_eval`, `edit`, and `write` developer tools
  under `Tackle.Tools.*`. It composes a coding system prompt with global and
  project `AGENTS.md` guidance. Configuration loads from `~/.tackle/config.json`,
  environment, and explicit overrides without loading modules from data.
- [`packages/tackle_lib`](packages/tackle_lib/README.md) contains the existing
  agent library and its API documentation (`Tackle.Lib.*`).
- [`packages/tackle_phoenix`](packages/tackle_phoenix/README.md) contains the
  existing Phoenix integration; it is not the intended CLI foundation.
- The library currently includes an optional Anubis MCP integration. That is
  inherited functionality and remains in `Tackle.Lib.Integrations.Anubis`; a
  future extraction needs a deliberate compatibility migration rather than
  silent removal.
- [`plugins/tackle_codex`](plugins/tackle_codex/README.md) contains the
  first-party OpenAI Codex adapter, including ChatGPT OAuth protocol helpers,
  token refresh, Responses SSE transport, and provider-neutral translation.
- [`frontends/tackle_cli`](frontends/tackle_cli/README.md) contains the default
  Optimus/ex_ratatui CLI entrypoint. It ships with the first-party Codex plugin
  as a distribution dependency, configures it as an available harness adapter,
  and relies on the root harness for credentials, sessions, and turn execution.
  Its footer reports current context pressure plus aggregate input/output,
  prompt-cache hit rate, and cost when the selected adapter exposes them.
- Extension project loading and Burrito packaging are still planned work.

The root harness owns OTP application `:tackle` and namespace `Tackle`. The
reusable library owns OTP application `:tackle_lib` and namespace `Tackle.Lib`;
the CLI frontend owns OTP application `:tackle_cli` and namespace
`Tackle.CLI`. These identities are intentionally separate. This is a breaking
library migration: downstream users must change package paths, module
references, and library configuration from `:tackle`/`Tackle.*` to
`:tackle_lib`/`Tackle.Lib.*`. The Phoenix integration keeps its
`:tackle_phoenix` and `Tackle.Phoenix.*` identities.

## Basic harness API

The harness accepts already-loaded adapter and capability modules. General
extension-project discovery remains out of scope; configuration data and
frontend arguments only select models declared by modules supplied by the
distribution. If no model is configured, the harness picks the first model
reference exposed by the configured adapters.

```elixir
config :tackle, adapters: [MyCodexAdapter]

{:ok, session} =
  Tackle.start_configured_session(
    overrides: [model: "openai-codex/gpt-5.5", thinking: "high"]
  )

{:ok, snapshot} = Tackle.subscribe(session)
{:ok, turn_id} = Tackle.submit(session, "Inspect this project")
```

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

Each session permits one active turn. `Tackle.continue/1` retries the settled
conversation without adding another user message, `Tackle.cancel/1` requests
cooperative cancellation, and `Tackle.close/1` cleans up the session.
`Tackle.reconfigure/2` can change the selected model and thinking level while a
session is idle without discarding its conversation. Subscribe before starting
a turn; active-turn attachment is deferred until event replay or projection
semantics are defined. Sessions use `Tackle.Tools.default/0` unless
an embedding host explicitly supplies `:tools`; a host can set `context: %{cwd:
path}` to change the filesystem tools' working directory. `elixir_eval` runs
stateless code inside the live Tackle BEAM with a five-second default timeout;
VM side effects persist, but variable bindings do not carry between calls.
These tools inherit the Tackle process's filesystem and operating-system
permissions and are not a sandbox. `Tackle.Lib` provides the `:telemetry`
runtime dependency used by tool execution.

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
3. Package with Burrito and verify the user-provided plugin workflow.
4. Add optional capabilities, including MCP, as separate plugins later.

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

# CLI frontend
(cd frontends/tackle_cli && mix deps.get)
(cd frontends/tackle_cli && mix compile --warnings-as-errors && mix test)
(cd frontends/tackle_cli && mix format --check-formatted)
(cd frontends/tackle_cli && mix escript.build)
```

These are separate Mix projects, not an umbrella: root checks do not validate
all packages. Dependency fetching needs network access and writable Mix/Hex
caches. No CLI installation or Burrito build command is available yet.

See [AGENTS.md](AGENTS.md) for contributor and coding-agent guidance.
