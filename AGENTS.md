# Working on Tackle

You are an Elixir/OTP contributor building a minimal, extensible developer
agent harness. Optimize for a small, readable core, high code quality, and
user-provided plugins—not feature count. Read [README.md](README.md) for the
project direction; distinguish planned capabilities from working code.

## Commands

Run these from the repository root unless noted. Use `nix develop` for the
configured toolchain (Elixir 1.20 / Erlang/OTP 29).

```sh
# Root project: dependencies, compilation, tests, formatting
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted

# Library: run checks in its own Mix project
(cd packages/tackle_lib && mix deps.get)
(cd packages/tackle_lib && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_lib && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# Focused library test
(cd packages/tackle_lib && mix test test/tackle_lib/loop_test.exs)

# Anubis MCP bridge: only when affected
(cd packages/tackle_anubis && mix deps.get)
(cd packages/tackle_anubis && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_anubis && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# Phoenix integration: only when affected
(cd packages/tackle_phoenix && mix deps.get)
(cd packages/tackle_phoenix && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_phoenix && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# OpenAI Codex plugin
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

# Web frontend (Phoenix; assets need the dev shell's tailwindcss/esbuild)
(cd frontends/tackle_web && mix deps.get)
(cd frontends/tackle_web && mix compile --warnings-as-errors && mix test)
(cd frontends/tackle_web && mix format --check-formatted)
(cd frontends/tackle_web && mix assets.build)

# Inspect changes before handing off
git status --short
git diff --check
git diff
```

Remove `--check-formatted` to apply formatting, and prefer explicit changed-file
paths to avoid unrelated churn. Root formatting and tests do not recurse into
the packages. Fetch dependencies only when needed; report unavailable tools,
network access, or caches as blockers, not as passing checks. Do not invent CLI,
Burrito, or lint commands for tooling that has not been wired up.

## Repository map and stack

- `lib/`, `test/`, `mix.exs`: root Elixir `~> 1.20` Mix application; currently
  a scaffold, not a working developer CLI.
- `packages/tackle_lib/`: existing framework-free library, Elixir `~> 1.18`,
  OTP application `:tackle_lib`, and namespace `Tackle.Lib.*`. Its `lib/` holds
  the engine and extension contracts; `test/` holds ExUnit tests. Read its
  `README.md` and relevant source before changing its API.
- `packages/tackle_phoenix/`: existing Phoenix LiveView (`~> 1.1.33`) and
  PubSub (`~> 2.1`) integration, with its own Mix project and tests.
- `packages/tackle_anubis/`: optional Anubis MCP bridge (`:tackle_anubis`,
  `Tackle.Anubis.*`) extracted out of `tackle_lib`, with its own Mix project and
  tests. It depends on `:tackle_lib` and `:anubis_mcp`; nothing in the harness or
  CLI depends on it.
- `plugins/tackle_codex/`: first-party OpenAI Codex adapter, ChatGPT OAuth
  protocol helpers, and Responses SSE transport. It is a separate Mix project
  that depends on `:tackle_lib`, not the root harness.
- `frontends/tackle_cli/`: default Optimus/ex_ratatui terminal entrypoint. It is
  a separate Mix project that depends on the root harness and bundles Codex as a
  distribution dependency; runtime adapter loading remains a root harness
  concern.
- `frontends/tackle_web/`: Phoenix frontend with two surfaces on one
  `Tackle.Web.*` namespace. `/chat` is the ordinary Tackle agent as a chat
  conversation, driven through `Tackle.Phoenix.Runner` and backed by an
  in-memory conversation store; `/` and `/pulls/...` are the diff and pull
  request review surfaces with the review assistant. It depends on the root
  harness, both provider plugins, and `packages/tackle_phoenix`; the review
  surfaces are documented by their module docs, and the mix project is separate
  from the harness.
- `flake.nix`, `nix/`: development environment, dependency, and build setup.
- `deps/`, `_build/`, `.nix-mix/`, `.nix-hex/`: dependencies, build output,
  and local caches; not hand-maintained source.

These are separate projects, not an umbrella. The root harness uses
`:tackle`/`Tackle`, while the reusable library uses `:tackle_lib`/`Tackle.Lib`;
keep those identities distinct when composing them.

## Architecture rules

- **Keep `packages/tackle_lib`.** Build around the library instead of replacing,
  relocating, or copying its agent loop into the CLI. The identity migration to
  `Tackle.Lib.*`/`:tackle_lib` is intentional and breaking.
- Keep the engine independent of terminal rendering, provider protocols,
  Phoenix, and SaaS concerns such as tenancy or billing.
- Prefer existing behaviours, tools, hooks, and events as extension seams.
  Add the smallest explicit contract needed by a real use case; do not build
  speculative registries or parallel plugin frameworks.
- Provider adapters are user-provided plugins. OpenAI Codex is the only
  first-party adapter maintained here; it uses the same contracts as external
  ones.
- MCP belongs in a later harness plugin. The inherited Anubis MCP server bridge
  now lives in `packages/tackle_anubis` (`Tackle.Anubis.*`) with `:anubis_mcp` as
  a required dependency of that package; `packages/tackle_lib` must stay free of
  MCP code and dependencies and keeps only the provider-neutral
  `Tackle.Lib.Integrations.Registry` seam.
- Keep optional dependencies with the plugins that need them. The minimal
  harness must not require Phoenix or MCP.
- Start with a simple CLI; add Burrito packaging afterward. Validate how
  user-provided plugins work in the binary before documenting it as supported.
- Small means less machinery, not compressed code or missing tests. Do not
  invent a numeric LOC target or trade clear error handling for brevity.

## Code style

Use idiomatic Elixir: `Tackle.Lib.ModuleName` for library contracts and
`Tackle.ModuleName` for the root harness, `snake_case` functions and files,
pattern matching, explicit result tuples for expected failures, and small
modules with clear responsibilities. Document public contracts and add useful
specs. Use behaviours and `@impl true` for extension implementations; keep
provider-specific translation inside adapters.

Always use Elixir's standard-library `JSON` module for JSON encoding and
decoding. Never use Jason or another third-party JSON library, and do not add
one as a dependency.

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
  provider-neutral. Its public modules are `Tackle.Lib.*`; the root harness
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
