# Tackle

Tackle is an Elixir agent harness for developers, built around a small core and
an extensible, plugin-first architecture.

It starts with an in-house agent library already used in a SaaS application.
The goal is to retain that library at [`packages/tackle`](packages/tackle) and
build a developer-facing harness around it—not turn the SaaS application into
a CLI.

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
| `packages/tackle` | Retained, reusable, provider- and frontend-independent agent library. |
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

MCP is a **future plugin**, not a built-in core feature. Other optional
integrations should follow the same separation. Phoenix and SaaS-specific
concerns are not requirements for the standalone harness.

Plugin discovery, loading, and distribution are not yet specified. In
particular, how user-provided plugins work with a Burrito binary needs to be
resolved and tested before promising a binary plugin workflow.

## Current state

This repository is a starting point, not a finished CLI:

- The root Mix project is still a scaffold; it does not yet wire in the library.
- [`packages/tackle`](packages/tackle/README.md) contains the existing agent
  library and its API documentation.
- [`packages/tackle_phoenix`](packages/tackle_phoenix/README.md) contains the
  existing Phoenix integration; it is not the intended CLI foundation.
- The library currently includes an optional Anubis MCP integration. That is
  inherited functionality, not the target plugin boundary; extracting it needs
  a deliberate migration rather than silent removal.
- The CLI, first-party Codex adapter, general plugin loading, and Burrito
  packaging are planned work.

The root project and the library currently share the `:tackle` application name
and some module names. Resolve that identity conflict before composing them;
keep the library at `packages/tackle`.

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
# Root scaffold
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted

# Agent library (a separate Mix project)
(cd packages/tackle && mix deps.get && mix test)

# Existing Phoenix integration, when working on it
(cd packages/tackle_phoenix && mix deps.get && mix test)
```

These are separate Mix projects, not an umbrella: root checks do not validate
all packages. Dependency fetching needs network access and writable Mix/Hex
caches. No CLI installation or Burrito build command is available yet.

See [AGENTS.md](AGENTS.md) for contributor and coding-agent guidance.
