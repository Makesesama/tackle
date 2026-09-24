<p align="center">
  <img src="docs/assets/tackle-logo.svg" alt="Tackle logo" width="112" height="96">
</p>

# Tackle

**An Elixir framework for building agent harnesses.** Compose a tool-using
agent loop, scoped OTP runtime, provider adapters, tools, and your own host
lifecycle into the harness your application needs. Tackle's CLI is one harness
built from these pieces, not the framework's only way to run an agent.

Tackle keeps provider protocols and frontends outside the core. Bring your own
adapter and tools; keep decisions about persistence, authorization, and UI in
your application. The packages are separate Mix projects, so you can use the
reusable library on its own or add scoped orchestration and integrations.

## Build with Tackle

| If you need… | Start with… |
| --- | --- |
| A tool-using agent loop in your own process or application | [`tackle_lib`](packages/tackle_lib/README.md) (`Tackle.Lib.*`): provider-neutral messages, tools, hooks, and the `Tackle.Lib.LLM` adapter contract. |
| Supervised agent scopes, subagents, limits, or workflows | [`tackle_runtime`](packages/tackle_runtime/README.md) (`Tackle.Runtime.*`) on top of `tackle_lib`. Your host supplies the agent backend and lifecycle policy. |
| A ready-to-compose developer harness | [`tackle`](packages/tackle) (`Tackle.*`): configuration, coding tools, credentials, and a facade over the scoped runtime. See the [harness guide](packages/tackle/README.md). |
| A Phoenix host integration | [`tackle_phoenix`](packages/tackle_phoenix/README.md): supervised turns, PubSub, and LiveView support. |
| A terminal frontend | [`tackle_cli`](apps/tackle_cli/README.md): the CLI built on the harness, not an agent engine to embed. |

Implement a `Tackle.Lib.LLM` adapter for your provider, supply
`Tackle.Lib.Tool` modules for your capabilities, and choose which runtime and
frontend belong in your host. The [library guide](packages/tackle_lib/README.md)
documents the extension contracts and host integration patterns; the
[scoped runtime guide](packages/tackle_runtime/README.md) covers orchestration.
The [harness guide](packages/tackle/README.md#basic-harness-api) shows how the
developer harness composes a scope and starts a turn.

## Design principles

- **Small, readable core:** keep the agent loop independent of provider
  protocols, terminal rendering, Phoenix, and SaaS policy.
- **Host-owned decisions:** applications choose their adapters, tools,
  persistence, authorization, and UI. Optional integrations stay in separate
  packages instead of becoming mandatory dependencies.
- **Explicit extension contracts:** use existing behaviours, hooks, and events
  instead of a universal plugin framework.

The first-party [Codex adapter](packages/tackle_codex/README.md) uses the same
contracts as third-party adapters. The optional
[MCP client](packages/tackle_mcp/README.md) exposes discovered tools through the
ordinary tool contract; the [Anubis server bridge](packages/tackle_anubis/README.md)
is separate from the core. The CLI currently bundles a fixed set of adapters.
**General extension-project discovery and loading are not implemented**, and a
user-provided plugin workflow in the Burrito binary has not been verified.

## Package boundaries

| Layer | Responsibility |
| --- | --- |
| `packages/tackle_lib` | Framework-free, provider- and frontend-independent agent loop (`Tackle.Lib`). |
| `packages/tackle_runtime` | Reusable scoped OTP orchestration (`Tackle.Runtime`). |
| `packages/tackle` | Developer-harness composition, configuration, and built-in tools (`Tackle`). |
| Plugin packages | Provider adapters and optional integrations, using explicit contracts. |
| `apps/tackle_cli` | Terminal interaction and fixed Burrito distribution; no duplicate agent loop. |

Keep the core focused on the agent loop and the contracts needed to extend it.
For planned plugin loading and distribution work, see
[`docs/plugins.md`](docs/plugins.md); that document is architectural direction,
not a description of shipped functionality.

## Current state

The framework packages and CLI are usable today, with the following boundaries
and unfinished integrations:

- [`packages/tackle`](packages/tackle/README.md) provides frontend-independent adapter/model
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
- [`packages/tackle_codex`](packages/tackle_codex/README.md) contains the
  first-party OpenAI Codex adapter, including ChatGPT OAuth protocol helpers,
  token refresh, Responses SSE transport, and provider-neutral translation.
- [`packages/tackle_deepseek`](packages/tackle_deepseek/README.md) contains the
  optional DeepSeek provider adapter bundled by the current app distributions.
- [`packages/tackle_mcp`](packages/tackle_mcp/README.md) contains the optional
  Anubis-based MCP client plugin. Trusted host startup can connect STDIO or
  Streamable HTTP servers, discover their tools, and add the returned proxy
  modules to a session's normal `:tools` list. The plugin currently bridges
  tools only and is not bundled by the CLI.
- [`apps/tackle_cli`](apps/tackle_cli/README.md) contains the default
  Optimus/ex_ratatui CLI entrypoint. Its Burrito release produces a fixed
  distribution that bundles the first-party Codex and DeepSeek plugins; runtime
  plugin discovery remains deferred. The frontend relies on the harness package
  for credentials, sessions, and turn execution. Its footer reports current
  context pressure plus aggregate input/output, preceding-prompt cache reuse,
  and cost when the selected adapter exposes them.
- General extension project loading remains planned work; Burrito packaging is
  now configured in the CLI frontend.

The harness package owns OTP application `:tackle` and namespace `Tackle`. The
reusable library owns OTP application `:tackle_lib` and namespace `Tackle.Lib`;
the reusable runtime owns OTP application `:tackle_runtime` and namespace
`Tackle.Runtime`; the CLI frontend owns OTP application `:tackle_cli` and
namespace `Tackle.CLI`. These identities are intentionally separate. This is a breaking
library migration: downstream users must change package paths, module
references, and library configuration from `:tackle`/`Tackle.*` to
`:tackle_lib`/`Tackle.Lib.*`. The Phoenix integration keeps its
`:tackle_phoenix` and `Tackle.Phoenix.*` identities.

## Git installation

The reusable packages are available as Git dependencies from this
monorepo. For example, add `tackle_phoenix` to your `mix.exs` with
`git: "https://github.com/Makesesama/tackle.git"`, a published `ref:
"REF"`, and `subdir: "packages/tackle_phoenix"`, then run `mix
deps.get`. Its sibling packages resolve from the same checkout. See
the
[`tackle_lib`](packages/tackle_lib/README.md#status-and-installation)
and [`tackle_phoenix`](packages/tackle_phoenix/README.md#installation)
installation guides for complete examples.

An example to include `tackle_lib`, `tackle_runtime` and `tackle_phoenix`
into you application:
```elixir
defp deps do
  [
    {:tackle_phoenix,
     git: "https://github.com/Makesesama/tackle.git",
     ref: "COMMIT_SHA",
     subdir: "packages/tackle_phoenix"}
  ]
end
```


## CLI during development

Fetch the CLI app's dependencies once, then run it from its project directory:

```sh
cd apps/tackle_cli
mix deps.get
mix tackle --help
mix tackle
```

The CLI keeps its terminal and provider dependencies outside the harness
package. The harness's Mix task can still delegate to `apps/tackle_cli` when
invoked from `packages/tackle`.

### Sandboxed dogfooding on Linux

The development shell also provides `jailed-tackle`, a Bubblewrap launcher built
with [`jailed-agents`](https://github.com/andersonjoseph/jailed-agents):

```sh
nix develop
jailed-tackle
```

Run it from the repository root. In `jailed-tackle`, **Ctrl+V** in the
composer asks a narrowly scoped host handler to read a PNG from the host
clipboard and stages it in the jail. This does not expose the compositor socket
or clipboard utilities to jailed tools, but **any code in the jail can invoke
this host clipboard-read capability**. The host needs `wl-paste` (Wayland) or
`xclip` (X11) installed and available on the launcher's `PATH`. This bridge
accepts only PNG up to 5 MiB; other clipboard formats are not pasted in the
jail. Some terminals send Ctrl+V as a bracketed text paste instead of a key;
for those terminals, use the manual fallback below.

To stage an image without the key, copy a PNG on the host. The jail prints a
per-launch session ID and a host command such as
`tackle-clipboard-paste tackle-paste-XXXXXXXX`. From another **host** terminal,
run `nix run .#tackle-clipboard-paste -- tackle-paste-XXXXXXXX`, substituting
that ID. The image appears in the composer without Ctrl+V. You can bind this
host command to a hotkey. Images are staged in a private per-launch host
directory mounted read-only in the jail and removed when it exits; Tackle keeps
a temporary copy until the CLI exits. Agent tools can read pasted images, and
reading one can persist its contents in session history. Do not paste secrets
you do not want the agent to see. This is not a boundary against other processes
running as your host user.

The jail gives Tackle read-write access to the
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
user namespaces. It mounts the current directory and `~/.tackle` read-write,
plus the same per-launch host image staging directory read-only; it does not
mount a compositor socket. Burrito extracts into `~/.tackle/burrito/.burrito`. It does not enable
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

## Harness guide

The [harness package guide](packages/tackle/README.md) covers scoped execution,
configured subagents, durable sessions and conversation trees, configuration,
prompts, and credentials. For terminal usage and jailed releases, see
[CLI during development](#cli-during-development) and the
[CLI guide](apps/tackle_cli/README.md).

## Initial milestones

1. Build the smallest useful developer harness and CLI around the existing
   library, with explicit extension boundaries.
2. Implement the OpenAI Codex adapter through those boundaries and demonstrate
   that a user-provided adapter can be substituted without editing the core.
3. Package the fixed first-party distribution with Burrito; then design and
   verify the user-provided plugin workflow separately.
4. Add optional capabilities as separate plugins; the first MCP tools client is
   implemented in `packages/tackle_mcp`, while CLI configuration and general
   extension loading remain later integration work.

Avoid a plugin marketplace or speculative plugin infrastructure; extend the
existing contracts when a host needs new capabilities.

## Development

The harness and app projects require Elixir `~> 1.20`; the lower-level
packages declare `~> 1.18`. The Nix development shell selects Elixir 1.20 and Erlang/OTP 29.
Enter it with `nix develop`, or use the repository's direnv setup.

```sh
# Harness package
(cd packages/tackle && mix deps.get)
(cd packages/tackle && mix compile --warnings-as-errors)
(cd packages/tackle && mix test)
(cd packages/tackle && mix format --check-formatted)

# Agent library (a separate Mix project)
(cd packages/tackle_lib && mix deps.get && mix test)

# Existing Phoenix integration, when working on it
(cd packages/tackle_phoenix && mix deps.get && mix test)

# First-party OpenAI Codex plugin
(cd packages/tackle_codex && mix deps.get)
(cd packages/tackle_codex && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_codex && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# MCP client plugin
(cd packages/tackle_mcp && mix deps.get)
(cd packages/tackle_mcp && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_mcp && mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}')

# CLI app
(cd apps/tackle_cli && mix deps.get)
(cd apps/tackle_cli && mix compile --warnings-as-errors && mix test)
(cd apps/tackle_cli && mix format --check-formatted)
(cd apps/tackle_cli && mix escript.build)
```

These are separate Mix projects, not an umbrella: root checks do not validate
all packages. Dependency fetching needs network access and writable Mix/Hex
caches. No dynamic plugin installation command is available yet. Burrito build
commands and native-library requirements are documented in
[`apps/tackle_cli/README.md`](apps/tackle_cli/README.md).

See [AGENTS.md](AGENTS.md) for contributor and coding-agent guidance.
