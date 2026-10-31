# Working on Tackle

You are an Elixir/OTP contributor building a minimal, extensible developer
agent harness. Optimize for a small, readable core, high code quality, and
user-provided plugins—not feature count. Read [README.md](README.md) for the
project direction; distinguish planned capabilities from working code.

## Commands

Run these from the repository root unless noted. Use `nix develop` for the
configured toolchain (Elixir 1.20 / Erlang/OTP 29).

```sh
# Harness package: dependencies, compilation, tests, formatting
(cd packages/tackle && mix deps.get)
(cd packages/tackle && mix compile --warnings-as-errors)
(cd packages/tackle && mix test)
(cd packages/tackle && mix format --check-formatted)

# Library: run checks in its own Mix project
(cd packages/tackle_lib && mix deps.get)
(cd packages/tackle_lib && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_lib && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# Focused library test
(cd packages/tackle_lib && mix test test/tackle_lib/loop_test.exs)

# Reusable OTP runtime: scopes, subagents, workflows
(cd packages/tackle_runtime && mix deps.get)
(cd packages/tackle_runtime && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_runtime && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# Coding tools and executors (MIX_REBAR3 from the dev shell)
(cd packages/tackle_tools && mix deps.get)
(cd packages/tackle_tools && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_tools && mix format --check-formatted)

# Code review (needs cargo for gix_ex, and MIX_REBAR3 from the dev shell)
(cd packages/tackle_review && mix deps.get)
(cd packages/tackle_review && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_review && mix format --check-formatted)

# Elixir project nodes (MIX_REBAR3 from the dev shell; the tests start real
# brokers and project nodes, so they need sh, elixir, and erl)
(cd packages/tackle_elixir && mix deps.get)
(cd packages/tackle_elixir && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_elixir && mix format --check-formatted)

# Anubis MCP bridge: only when affected
(cd packages/tackle_anubis && mix deps.get)
(cd packages/tackle_anubis && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_anubis && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# Phoenix integration: only when affected
(cd packages/tackle_phoenix && mix deps.get)
(cd packages/tackle_phoenix && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_phoenix && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# OpenAI Codex plugin
(cd packages/tackle_codex && mix deps.get)
(cd packages/tackle_codex && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_codex && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# MCP client plugin
(cd packages/tackle_mcp && mix deps.get)
(cd packages/tackle_mcp && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_mcp && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# Exec-server for jailed tool primitives (no dependencies)
(cd packages/tackle_exec && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_exec && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# JSON-RPC stdio SDK server for non-BEAM clients
(cd packages/tackle_sdk && mix deps.get)
(cd packages/tackle_sdk && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_sdk && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# Lua-scripted workflows (needs MIX_REBAR3 from the dev shell for first compile)
(cd packages/tackle_workflow && mix deps.get)
(cd packages/tackle_workflow && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_workflow && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# Native clipboard package (Rustler NIF over arboard; needs cargo)
(cd packages/clipboard_ex && mix deps.get)
(cd packages/clipboard_ex && mix compile --warnings-as-errors && mix test)
(cd packages/clipboard_ex && mix format --check-formatted)
(cd packages/clipboard_ex/native/clipboard_ex && cargo fmt --check && cargo clippy)

# Native read-only Git package (Rustler NIF over gitoxide; needs cargo and git)
(cd packages/gix_ex && mix deps.get)
(cd packages/gix_ex && mix compile --warnings-as-errors && mix test)
(cd packages/gix_ex && mix format --check-formatted)
(cd packages/gix_ex/native/gix_ex && cargo fmt --check && cargo clippy --all-targets && cargo test)

# YAML front matter parser (no dependencies)
(cd packages/yaml_frontmatter && mix compile --warnings-as-errors && mix test)
(cd packages/yaml_frontmatter && mix format --check-formatted)

# CLI app
(cd apps/tackle_cli && mix deps.get)
(cd apps/tackle_cli && mix compile --warnings-as-errors && mix test)
(cd apps/tackle_cli && mix format --check-formatted)
(cd apps/tackle_cli && mix escript.build)

# Web review app (PostgreSQL on localhost:5432 as postgres/postgres, or PG*
# variables, or scripts/db.sh; see its README; needs MIX_REBAR3)
(cd apps/tackle_hub && mix deps.get)
(cd apps/tackle_hub && mix compile --warnings-as-errors && mix test)
(cd apps/tackle_hub && mix format --check-formatted && mix credo --strict)
# After dependency changes: regenerate and build the Nix package; VM test (KVM)
(cd apps/tackle_hub && mix deps.nix) && nix fmt -- nix/tackle-hub-deps.nix
nix build .#tackle-hub
nix build .#checks.x86_64-linux.tackle-hub-vm

# Emacs client (Elisp; needs an Emacs in the dev shell or PATH)
(cd apps/etackle && emacs -Q --batch -L . -l test/etackle-test.el \
    -f ert-run-tests-batch-and-exit)

# Inspect changes before handing off
git status --short
git diff --check
git diff
```

Remove `--check-formatted` to apply formatting, and prefer explicit changed-file
paths to avoid unrelated churn. Checks in one app or package do not recurse into
the other projects. Fetch dependencies only when needed; report unavailable tools,
network access, or caches as blockers, not as passing checks. Do not invent CLI,
Burrito, or lint commands for tooling that has not been wired up.

## Repository map and stack

- `packages/tackle/`: Elixir `~> 1.20` developer harness and composition layer;
  it is a library package rather than a runnable app.
- `packages/tackle_lib/`: existing framework-free library, Elixir `~> 1.18`,
  OTP application `:tackle_lib`, and namespace `Tackle.Lib.*`. Its `lib/` holds
  the engine and extension contracts; `test/` holds ExUnit tests. Read its
  `README.md` and relevant source before changing its API.
- `packages/tackle_runtime/`: reusable OTP orchestration above `tackle_lib`,
  including scopes, stable refs, admission limits, per-agent tool supervision,
  subagents, and workflows. Hosts provide an agent backend for their lifecycle
  and persistence policy.
- `packages/tackle_tools/`: the coding tools `read`, `bash`, `edit`, and
  `write` (`Tackle.Tools.*`) and their executors (`Tackle.Executor.Local`,
  `Tackle.Executor.Jailed`), on `tackle_lib` and `tackle_exec` only, so hosts
  other than the harness can use them. The harness's default tools.
- `packages/tackle_review/`: code review (`Tackle.Review.*`, `:tackle_review`)
  on `tackle_runtime`, `gix_ex`, and `yaml_frontmatter`. It stores nothing and
  does not depend on the harness; hosts pass in rules, settings, and known
  findings, and their runtime backend implements the spec callbacks
  (`configure/2`, `describe/1`, `llm/1`). The harness depends on it and adds
  local settings, rules, and history in `Tackle.LocalReview`.
- `packages/tackle_elixir/`: Elixir project nodes (`Tackle.Elixir.*`,
  `:tackle_elixir`) on `tackle_lib`, `tackle_tools`, and `tackle_exec` only.
  `Tackle.Elixir.ProjectNode` starts a broker through a session's executor
  (inside the jail when jailed), which drives one BEAM node per Mix project
  over Erlang distribution that never leaves the executor; the host talks to
  the broker in checked frames. See `docs/PROJECT_NODE_PLAN.md`. Its
  `Tackle.Elixir.CompileGate` hook compiles the projects a turn changed
  before the turn ends; the harness depends on the package and turns the gate
  on in `Tackle.Config.load/1`.
- `packages/tackle_phoenix/`: existing Phoenix LiveView (`~> 1.1.33`) and
  PubSub (`~> 2.1`) integration, with its own Mix project and tests. It owns no
  agent process: `Tackle.Phoenix.Bridge` relays any `Tackle.Runtime` agent's
  events over PubSub, and `Tackle.Phoenix.EventReducer` renders them.
- `packages/tackle_anubis/`: optional Anubis MCP bridge (`:tackle_anubis`,
  `Tackle.Anubis.*`) extracted out of `tackle_lib`, with its own Mix project and
  tests. It depends on `:tackle_lib` and `:anubis_mcp`; nothing in the harness or
  CLI depends on it.
- `packages/tackle_codex/` and `packages/tackle_deepseek/`: provider adapter
  packages. Codex is the maintained first-party adapter; both depend on
  `:tackle_lib`, not the harness package.
- `packages/tackle_mcp/`: optional Anubis-based MCP client plugin that exposes
  discovered MCP tools through the provider-neutral tool contract.
- `packages/tackle_exec/`: dependency-free exec-server (`Tackle.Exec.*`,
  `:tackle_exec`). A host-side client drives a jailed server over a port with
  length-prefixed Erlang terms and treats everything from the jail as hostile.
  The harness's `Tackle.Executor.Jailed` routes the built-in tools through it,
  and the CLI uses it when `TACKLE_EXEC_LAUNCHER` is set (`nix/packages/exec-jail.nix`,
  `docs/EXEC_SERVER_PLAN.md`).
- `packages/tackle_sdk/`: experimental JSON-RPC 2.0 over stdio server
  (`Tackle.SDK.*`, `:tackle_sdk`) that lets non-BEAM clients drive the
  `Tackle.Lib` agent loop. The wire contract is `packages/tackle_sdk/PROTOCOL.md`;
  tools are server-side only in protocol version 1.
- `packages/tackle_workflow/`: the workflow engine, and the only one
  (`Tackle.Workflow.*`, `:tackle_workflow`) on top of `tackle_runtime`. A
  workflow is a sandboxed Lua script (`tackle.spawn/2`, `tackle.await/1`,
  `tackle.parallel/3`) whose delegated runs use the same primitives as
  `subagent`. The harness only depends on it in tests; the CLI bundles it and
  grants its `run_workflow` tool to the root agent.
- `packages/clipboard_ex/`: native clipboard package (`Clipboard.*`,
  `:clipboard_ex`): a Rustler NIF over Rust's `arboard` with tmux/OSC 52
  terminal fallbacks. The CLI uses it for copying and for image/text pasting.
- `packages/gix_ex/`: experimental read-only Git package (`GixEx.*`,
  `:gix_ex`): a Rustler NIF over Rust's gitoxide that resolves revisions, walks
  history, reads directories at a revision, and returns diffs as data, without
  a `git` executable. `tackle_review` loads changes and rules with it.
- `packages/yaml_frontmatter/`: dependency-free parser for the YAML front
  matter of Markdown files (`YamlFrontmatter`, `:yaml_frontmatter`). The
  harness reads skills, agent definitions, and review rules with it.
- `apps/tackle_cli/`: default Optimus/ex_ratatui terminal entrypoint. It is a
  separate Mix project that depends on the harness and bundles Codex as a
  distribution dependency; runtime adapter loading remains a harness concern.
  It also bundles `tackle_workflow`; `Tackle.CLI.Distribution` lists the
  bundled delegation tools and the catalog tools granted to the root agent.
- `apps/tackle_hub/`: Phoenix/Ash web app (`:tackle_hub`; domain
  `Tackle.Hub.*` in `lib/tackle_hub/`, web layer `Tackle.HubWeb.*` in
  `lib/tackle_hub_web/`)
  that will review forge pull requests with `tackle_review`; built in phases
  from `docs/TACKLE_HUB_PLAN.md`, now through phase 9 (jailed review jobs,
  stored runs/findings, retry-safe sanitized GitHub posting to `:posted`,
  GitHub sign-in with AshAdmin behind admin policies, browser-only setup of
  the GitHub App via `/setup`, installation owners with access grants and
  user-owned providers, the user pages: repositories, reviews, and model
  settings, and feedback: dismissals from resolved threads and reactions).
  It depends on the packages, not the harness, and keeps Ash,
  Oban, Cloak, and PostgreSQL to itself. Its tests need a PostgreSQL server (see its README). Packaged as
  `.#tackle-hub` (`nix/packages/tackle-hub.nix`) and run by the NixOS
  module `nixosModules.tackle-hub` (`nix/modules/tackle-hub.nix`).
- `apps/etackle/`: Emacs client for the Tackle SDK wire protocol
  (`packages/tackle_sdk/PROTOCOL.md`), speaking ndjson JSON-RPC over stdio to
  `tackle sdk`. Plain Emacs Lisp (Emacs 28.1+), not a Mix project; see its
  `README.md` for usage and its ERT tests for the RPC contract.
- `flake.nix`, `nix/`: development environment, dependency, and build setup.
- `deps/`, `_build/`, `.nix-mix/`, `.nix-hex/`: dependencies, build output,
  and local caches; not hand-maintained source.

These are separate projects, not an umbrella. The harness package uses
`:tackle`/`Tackle`, while the reusable library uses `:tackle_lib`/`Tackle.Lib`;
keep those identities distinct when composing them.

## Architecture rules

- **Keep `packages/tackle_lib`.** Build around the library instead of replacing,
  relocating, or copying its agent loop into the CLI. The identity migration to
  `Tackle.Lib.*`/`:tackle_lib` is intentional and breaking.
- Keep the engine independent of terminal rendering, provider protocols,
  Phoenix, and SaaS concerns such as tenancy or billing. Reusable scoped OTP
  orchestration belongs in `packages/tackle_runtime`, not `tackle_lib`.
- Prefer existing behaviours, tools, hooks, and events as extension seams.
  Add the smallest explicit contract needed by a real use case; do not build
  speculative registries or parallel plugin frameworks.
- Provider adapters are user-provided plugins. OpenAI Codex is the only
  first-party adapter maintained here; it uses the same contracts as external
  ones.
- MCP belongs in a later harness plugin. The inherited Anubis MCP server bridge
  now lives in `packages/tackle_anubis` (`Tackle.Anubis.*`) with `:anubis_mcp` as
  a required dependency of that package; `packages/tackle_lib` must stay free of
  MCP code and dependencies. Bridges build on the provider-neutral
  `Tackle.Lib.Tool` and `Tackle.Lib.Tool.Registry` contracts.
- Keep optional dependencies with the plugins that need them. The minimal
  harness must not require Phoenix or MCP.
- Start with a simple CLI; add Burrito packaging afterward. Validate how
  user-provided plugins work in the binary before documenting it as supported.
- Small means less machinery, not compressed code or missing tests. Do not
  invent a numeric LOC target or trade clear error handling for brevity.

## Code style

Use idiomatic Elixir: `Tackle.Lib.ModuleName` for library contracts and
`Tackle.ModuleName` for the harness package, `snake_case` functions and files,
pattern matching, explicit result tuples for expected failures, and small
modules with clear responsibilities. Document public contracts and add useful
specs. Use behaviours and `@impl true` for extension implementations; keep
provider-specific translation inside adapters.

Always use Elixir's standard-library `JSON` module for JSON encoding and
decoding. Never use Jason or another third-party JSON library, and do not add
one as a dependency. The one exception is transitive: `apps/tackle_hub`'s
frameworks (Ash, Oban, Postgrex, Cloak) pull in Jason, which is accepted;
our code there still uses `JSON`, and Jason is never listed in a `mix.exs`.

Example of a deterministic test adapter using the existing `Tackle.Lib.LLM`
contract (not a production provider implementation):

```elixir
defmodule ExampleAdapter do
  @behaviour Tackle.Lib.LLM

  @impl true
  def generate(_schema, _opts) do
    {:ok,
     %{
       data: %{"content" => "Hello", "tool_calls" => []},
       usage: nil,
       model: "test-model"
     }}
  end
end
```

Prefer explicit configuration and data flow to hidden global state. Do not add
a process merely to wrap a function; use OTP processes when lifecycle,
concurrency, or supervision requires them. Follow the surrounding conventions
rather than performing stylistic rewrites.

## Testing

- Add focused ExUnit coverage for changed behaviour and regressions.
- Use fake adapters and tools by default: tests should not need provider
  credentials, live model calls, or paid services.
- Cover extension contracts, error paths, and relevant cancellation/streaming
  behaviour—not just successful output.
- Test CLI interaction separately from the engine. Verify third-party adapters
  can use the same seam as the Codex adapter as that functionality is built.
- Run focused tests while iterating, then checks for each affected Mix project.
  Library API changes may also affect `packages/tackle_phoenix`; it consumes
  `Tackle.Lib.*` while retaining its own `Tackle.Phoenix.*` namespace and
  `:tackle_phoenix` application identity.
- Report exact commands, results, and skipped checks. Do not suppress warnings
  or weaken assertions just to make checks pass.

## Git workflow

Inspect the working tree first and preserve existing user changes. Keep diffs
focused on the request; avoid unrelated formatting, dependency updates, and
refactors. Review `git diff` and run `git diff --check` before handing off.
Summarize changed files, validation, and unresolved risks. 

## Boundaries

### Always

- Preserve the library at `packages/tackle_lib` and keep core contracts
  provider-neutral. Its public modules are `Tackle.Lib.*`; the harness package
  remains `Tackle.*` under `:tackle`.
- Prefer plugins for optional features and keep the CLI a thin frontend.
- Update relevant documentation when public behaviour changes; label plans as plans.
  Document the breaking `packages/tackle` → `packages/tackle_lib` and
  `Tackle.*` → `Tackle.Lib.*` migration, including `:tackle_lib` configuration.
- Preserve user edits and report test/environment failures honestly.

### Ask first

- Breaking public APIs, renaming OTP applications/modules, or moving/removing
  existing functionality. The approved library identity migration and the
  `Tackle.Lib.Integrations.Anubis` → `Tackle.Anubis` extraction are the
  exceptions already in progress; do not generalize that approval to later
  changes.
- Adding dependencies, new first-party provider adapters, or core features that
  could live in plugins.
- Committing to a plugin loading/distribution mechanism, changing release or
  CI configuration, or broad refactoring beyond the requested scope.

### Never

- Delete or replace `packages/tackle_lib`, duplicate its engine in the frontend,
  or hard-code Codex-specific behaviour into the provider-neutral core.
- Commit credentials, tokens, private prompts, or sensitive conversation logs.
- Hand-edit dependencies, generated build output, caches, or generated Nix store files.
- Remove failing tests to conceal a regression, discard user work, or use
  destructive Git commands without explicit authorization.
