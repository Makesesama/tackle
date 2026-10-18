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
| Supervised agent scopes, subagents, or limits | [`tackle_runtime`](packages/tackle_runtime/README.md) (`Tackle.Runtime.*`) on top of `tackle_lib`. Your host supplies the agent backend and lifecycle policy. |
| Scripted multi-agent flows ("scout, then plan, then review") | [`tackle_workflow`](packages/tackle_workflow/README.md) (`Tackle.Workflow.*`): sandboxed Lua workflows driving the runtime's delegated runs, plus an opt-in `run_workflow` tool for an agent. |
| Code review of a change, in your own host | [`tackle_review`](packages/tackle_review/README.md) (`Tackle.Review.*`): ranked, line-anchored findings from detector and verifier agents on the runtime. It stores nothing; your host passes in rules, settings, and known findings. |
| A ready-to-compose developer harness | [`tackle`](packages/tackle) (`Tackle.*`): configuration, coding tools, credentials, and a facade over the scoped runtime. See the [harness guide](packages/tackle/README.md). |
| A Phoenix host integration | [`tackle_phoenix`](packages/tackle_phoenix/README.md): supervised turns, PubSub, and LiveView support. |
| A terminal frontend | [`tackle_cli`](apps/tackle_cli/README.md): the CLI built on the harness, not an agent engine to embed. |
| An Emacs frontend | [`etackle`](apps/etackle/README.md): the first client for the Tackle SDK, driving `tackle sdk` over its stdio JSON-RPC protocol. |
| A pull request review bot (in progress) | [`tackle_hub`](apps/tackle_hub/README.md): a Phoenix/Ash app that will review forge pull requests with `tackle_review`; receives GitHub webhooks and runs jailed reviews, storing runs and findings (phases 1–4 of [the plan](docs/TACKLE_HUB_PLAN.md)); forge posting is next. |

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
is separate from the core. The CLI still bundles its default adapters. The harness now loads **explicitly
enabled, separately precompiled Mix projects** at host startup through
`$TACKLE_HOME/plugins.json`. See [`docs/PLUGINS.md`](docs/PLUGINS.md) for the
trusted enablement schema and limitations; there is no auto-discovery, implicit
build, or sandbox.

## Package boundaries

| Layer | Responsibility |
| --- | --- |
| `packages/tackle_lib` | Framework-free, provider- and frontend-independent agent loop (`Tackle.Lib`). |
| `packages/tackle_runtime` | Reusable scoped OTP orchestration (`Tackle.Runtime`). |
| `packages/tackle_tools` | Coding tools (`read`, `bash`, `edit`, `write`) and their local and jailed executors. |
| `packages/tackle_review` | Code review on the runtime (`Tackle.Review`), without storage or harness code. |
| `packages/tackle` | Developer-harness composition, configuration, and built-in tools (`Tackle`). |
| Plugin packages | Provider adapters and optional integrations, using explicit contracts. |
| `apps/tackle_cli` | Terminal interaction and fixed Burrito distribution; no duplicate agent loop. |

Keep the core focused on the agent loop and the contracts needed to extend it.
For current plugin integration points and remaining design work,
see [`docs/PLUGIN_SYSTEM.md`](docs/PLUGIN_SYSTEM.md). For the broader plugin
model and supported enablement schema, see [`docs/PLUGINS.md`](docs/PLUGINS.md).

## Current state

The framework packages and CLI are usable today, with the following boundaries
and unfinished integrations:

- [`packages/tackle`](packages/tackle/README.md) provides frontend-independent provider/model
  configuration (one adapter can back several providers, such as two Codex
  accounts or a local and a cloud Ollama server), composes the reusable scoped runtime, a supervised credential store,
  and built-in `read`, `bash`, `edit`, and `write` developer tools
  under `Tackle.Tools.*`. It composes a coding system prompt with global and
  project `AGENTS.md` guidance, and discovers Agent Skills from `.agents/skills`
  directories so the model can load them on demand. Configuration loads from
  `~/.tackle/config.json`, environment, and explicit overrides without loading
  modules from data.
- [`packages/tackle_lib`](packages/tackle_lib/README.md) contains the existing
  agent library and its API documentation (`Tackle.Lib.*`).
- [`packages/tackle_runtime`](packages/tackle_runtime/README.md) contains the
  reusable scoped OTP runtime: supervision, limits, subagents, and fan-out
  (`Tackle.Runtime.*`).
- [`packages/tackle_tools`](packages/tackle_tools/README.md) contains the
  coding tools and their local and jailed executors (`Tackle.Tools.Read`,
  `Bash`, `Edit`, `Write`, `Tackle.Executor.*`), usable by any host.
- [`packages/tackle_review`](packages/tackle_review/README.md) contains code
  review (`Tackle.Review.*`) on the runtime. The harness uses it through
  `Tackle.LocalReview`, which adds the local settings, rules, and history.
- [`packages/tackle_exec`](packages/tackle_exec/README.md) contains the
  exec-server protocol, jail-side server, and host client for running tool
  primitives in a jail (`Tackle.Exec.*`). The built-in tools reach it through
  `Tackle.Executor.Jailed`, and the CLI uses it when `TACKLE_EXEC_LAUNCHER` is
  set (see [jailed execution](#jailed-execution-on-linux)).
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
- [`packages/tackle_openrouter`](packages/tackle_openrouter/README.md) contains
  the OpenRouter provider adapter, which reaches many vendors' models through
  one API key (`openrouter/<vendor>/<model>`). The current app distributions
  bundle it.
- [`packages/tackle_ollama`](packages/tackle_ollama/README.md) contains the
  optional Ollama adapter: Ollama Cloud (`ollama-cloud/<model>`, using
  `OLLAMA_API_KEY`), a keyless local server (`ollama/<model>`), and any
  self-hosted server declared as a provider in `config.json`.
  Bundled by the CLI; other hosts can enable it as a separately compiled plugin.
- [`packages/tackle_mcp`](packages/tackle_mcp/README.md) contains the optional
  Anubis-based MCP client plugin. Trusted host startup can connect STDIO or
  Streamable HTTP servers, discover their tools, and add the returned proxy
  modules to a session's normal `:tools` list. The plugin currently bridges
  tools only and is not bundled by the CLI.
- [`apps/tackle_cli`](apps/tackle_cli/README.md) contains the default
  Optimus/ex_ratatui CLI entrypoint. Its Burrito release produces a fixed
  distribution that bundles the first-party Codex, DeepSeek, Anthropic,
  OpenRouter, and Ollama plugins; the
  harness loads explicitly enabled precompiled projects at startup, without
  automatically discovering projects. The frontend relies on the harness package
  for credentials, sessions, and turn execution. Its footer reports current
  context pressure plus aggregate input/output, preceding-prompt cache reuse,
  and cost when the selected adapter exposes them.
- Explicit external Mix-project startup loading is implemented in the harness;
  compatibility with arbitrary builds is not guaranteed and executable-path
  validation remains pending.

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

### Jailed execution on Linux

Tackle can run the agent's commands and workspace file access in a Bubblewrap
jail while the CLI itself stays on the host. The CLI keeps your credentials
(`~/.tackle`), sessions, and host facilities such as the Wayland or X11
clipboard; the jail sees the project directory, the Nix store, and the
project's nix-direnv profile, and nothing else from your home. The design is
described in [`docs/EXEC_SERVER_PLAN.md`](docs/EXEC_SERVER_PLAN.md).

The CLI enables this when `TACKLE_EXEC_LAUNCHER` names a launcher. The Nix
packages below set it for you. The launcher starts one jailed exec-server per
CLI process with the project directory as the workspace (or
`TACKLE_EXEC_WORKSPACE`, which must contain the current directory). Jailed mode
fails closed: if the jail does not start, or if it can see `$TACKLE_HOME`,
Tackle reports an error and never runs tools on the host instead. Comparing
resolved paths, it refuses a workspace that contains your home directory,
`$TACKLE_HOME` or anything it links to, or an enabled plugin project, and a
workspace inside `$TACKLE_HOME`. The exec-server's standard error goes to
`$TACKLE_HOME/logs/exec-server.log`.

The jail (`nix/packages/exec-jail.nix`):

- mounts the workspace read-write at the same path. `.git` is mounted onto
  itself so it cannot be replaced; `.git/config`, `.git/config.worktree`,
  `.git/hooks`, and the linked worktrees' metadata in `.git/worktrees` are
  read-only; and a planted `.git/commondir` blocks the launch;
- makes Git work in a linked worktree (`git worktree add`, or a Herdr
  worktree workspace). Its `.git` file and the pointers in its Git directory
  are read-only. The main checkout's `.git` is mounted readable and
  read-only apart from `objects`, `refs`, branch reflogs, and the rerere
  cache, so commits, merges, rebases, stashes, fetches, and pushes work but
  the main checkout's `HEAD`, index, and configuration cannot be changed; the
  main checkout's files are not mounted. Anything that deletes or renames a
  ref (`branch -d`/`-m`, `tag -d`, a pruning fetch, `stash drop`), writes
  configuration (`push -u`, `branch -u`), or runs `git gc` needs the main
  `.git` itself and fails in the jail; `git stash` prints such an error but
  works. With rerere enabled, merges fail until `.git/rr-cache` exists. The
  launcher refuses a worktree whose `.git` file and Git directory do not
  point at each other; `git worktree repair` on the host fixes a moved one.
  Create worktrees on the host: `git worktree add` fails in the jail;
- gives the jail a private `/tmp` and home, and a cleared environment;
- does not mount the host's Git configuration: Git in the jail reads the
  `gitConfig` built into the launcher (`/etc/tackle/gitconfig`, read-only) as
  its global configuration, so set the commit identity there (see
  [Home Manager](#home-manager-module)) or the agent cannot commit;
- unshares every namespace except the network, starts a new session, and dies
  with the CLI;
- provides common command-line tools, Ketch, and Python 3 with `requests`,
  PyYAML, Beautiful Soup, and `pip`, with
  `~/.config/ketch/config.json` mounted read-only when present. Any API keys
  in that file are readable from the jail;
- reproduces the project's devshell when a cached nix-direnv one exists, so the
  agent finds the project toolchain (`mix`, `cargo`, `treefmt`) on `PATH`
  instead of searching the store for it.

The agent's scripts run against that Python: `nix/packages/jail-python.nix` is
the list both launchers install. The interpreter lives in the store, so
`pip install` needs a virtualenv in the workspace, which persists, or `--user`,
which lasts for the CLI process; `nix shell nixpkgs#python3Packages.<pkg>` also
works while the store and daemon are mounted.

Starting Tackle from a direnv-activated shell gives the jail the same devshell
you have in that shell. The launcher runs on the host with the workspace as its
working directory, so it looks up the cached `nix print-dev-env` profile that
nix-direnv keeps for it, in `$XDG_CACHE_HOME/direnv/layouts` or the project's
`.direnv`, and binds those profile rc files read-only. The jail then sources
them: the workspace's devshell before the exec-server starts, and the devshell
of a nested project whenever a command runs in it (`cd subdir && mix test`).
Nothing happens when no devshell is cached, and the launcher's own tools and
locale stay on `PATH` and in the environment. A cached profile describes the
host environment, so this only works while the store is mounted (`enableNix`,
on in `tackle-cli-jail`), and sourcing it runs the devshell's `shellHook`
inside the jail, which is code `direnv allow` already runs for you on the host.
Build a launcher with `inheritDirenv = false` to turn it off
(`nix/packages/jail-direnv.nix`).

Tackle reads project guidance (`AGENTS.md`), skills, and project agent
definitions inside the workspace through the jail, so a symlink that jailed code
plants to a host file such as `~/.tackle/auth.json` resolves to nothing.
Pasted images are staged in the jail's `/tmp` so the agent's `read` tool can
open them.

Not covered:

- Workspace contents still run on the host when you build or open the project
  there (`mix.exs`, dependencies, `.envrc`).
- The jail sources the cached devshell, so a devshell whose store paths were
  garbage collected leaves dangling `PATH` entries until `direnv reload` on the
  host. A devshell cached for a project directory reached through a different
  textual path (a symlinked project root, for example) is not found.
- Host Git in a jailed workspace is narrowed, not safe: repositories that jailed
  code creates, submodules under `.git/modules`, and nested `.git` directories
  are writable, and a workspace without `.git` at launch gets no protection.
  Jailed code can plant a `commondir` in a writable `.git` directory, which the
  next launch refuses but host Git follows, and rebase or cherry-pick state
  whose `exec` lines a host `git rebase --continue` runs: abort a rebase you
  did not start. Writable objects and refs let it add object alternates and
  symbolic refs that host Git follows. In a linked worktree it can move any
  branch, as Git in any worktree can, and with the reftable backend also the
  main checkout's `HEAD`.
  Inspect them before running Git on the host, or run Git in the jail.
- The jail shares the host network namespace, so it can reach services on
  localhost and abstract Unix sockets, such as an X11 display that trusts
  local connections.
- The jail can read and grow the shared exec-server log.
- MCP servers and plugins configured for Tackle run on the host.

The agent can modify or delete anything in the project, so keep valuable work
committed or backed up. The launchers are Linux-only.

### Production jailed package on Linux

`tackle-cli-jail` provides `bin/tackle`: the production Burrito package on the
host, with tools in the jail. Run it from any project folder:

```sh
# From the Tackle repository root:
nix build .#tackle-cli-jail --out-link result-jailed
./result-jailed/bin/tackle --version
./result-jailed/bin/tackle
```

It requires a multi-user Nix installation with the daemon socket at
`/nix/var/nix/daemon-socket/socket`, `/etc/nix/nix.conf`, and working
Bubblewrap user namespaces. The CLI binary lives in the read-only Nix store, so
jailed code cannot change what runs on the host.

**Nix access weakens isolation:** the whole host `/nix` tree is readable inside
the jail, including store paths containing source or configuration, and the
daemon socket is accessible, so the agent can request host builds and other
daemon operations allowed for your user. **If you are in Nix's
`trusted-users`, this is equivalent to root access.** Network access is
enabled.

Inside the jail, `nix build` and `nix develop --command ...` use the host daemon
with flakes enabled. The full read-only store mount makes new build outputs and
their symlink targets visible immediately. Automatic sourcing of direnv
environments is **not implemented**; use `nix develop` explicitly. Host user
Nix configuration, private-fetch credentials, and devshell environment
variables are not forwarded. Daemon-side build sandboxing follows the host's
Nix configuration.

A credential-free host smoke test runs a probe under the same jail policy
(hidden home and credentials, cleared environment, read-only Git settings,
Ketch, an offline Nix build), drives the real exec-server through the protocol
client, and checks the packaged CLI's informational commands:

```sh
nix build .#tackle-cli-jail.tests.smoke --out-link result-jail-test
./result-jail-test/bin/test-jailed-tackle-cli
```

Run this on the host, not inside a jail or a Nix build sandbox. Also open the
jailed TUI, run a command, and exit with Ctrl+C to check startup end to end.
The jail wrapper is a Nix package, not a portable single-file executable; keep
`tackle-cli` for the unjailed, copyable Burrito artifact.

Git in the jail has no identity unless the package is built with one, so the
agent cannot commit. `gitConfig` takes `lib.generators.toGitINI` attributes
and becomes Git's global configuration in the jail; repository configuration
still wins. The file is in the store and readable by every local user.

```nix
tackle.packages.${system}.tackle-cli-jail.override {
  gitConfig.user = {
    name = "Ada Lovelace";
    email = "ada@example.com";
  };
}
```

### Home Manager module

The flake exports a Home Manager module as `homeModules.default` (also
`homeManagerModules.default`). It installs `tackle-cli-jail` on Linux and
`tackle-cli` elsewhere, writes `~/.tackle/config.json`, and builds the jail
with a Git commit identity:

```nix
# flake.nix
inputs.tackle.url = "github:Makesesama/tackle";

# Home Manager configuration
{ inputs, config, ... }:
{
  imports = [ inputs.tackle.homeModules.default ];

  programs.tackle = {
    enable = true;
    settings = {
      model = "openai-codex/gpt-5.5";
      thinking = "medium";
    };
    git = {
      name = "Ada Lovelace";
      email = "ada@example.com";
      # Or reuse your host identity:
      # name = config.programs.git.settings.user.name;
    };
  };
}
```

`settings` holds the fields of
[`config.json`](packages/tackle/README.md#configuration-and-credentials).
When it is not empty, activation replaces `~/.tackle/config.json` with a
regular copy (mode 0600), not a link into the store: the CLI saves preferences
such as the subagent sidebar toggle by renaming a new file over it and refuses
a symbolic link. Those saved preferences last until the next activation. With
empty `settings` the module leaves the file alone. It does not follow a custom
`TACKLE_HOME`, and it never writes `auth.json`; log in with the CLI as usual.
`git.name` and `git.email` need the jail, so on other platforms the module
rejects them. A custom `package` must accept `override { gitConfig = ...; }`,
as `tackle-cli-jail` does. On NixOS, use it through Home Manager's NixOS
module.

### Jailed dogfooding from the checkout

The development shell also provides `jailed-tackle`. Run it from the repository
root:

```sh
nix develop
jailed-tackle
```

It runs `mix tackle` from the checkout on the host, with a jail that mounts the
repository root and provides the Elixir and Rust toolchains. The host Nix
daemon is not available in this jail. Clipboard paste works directly.

**The checkout is the trust boundary here.** Everything in it, including
`_build`, `deps`, and `.nix-mix`, is writable from the jail, and the next
`jailed-tackle` start compiles and runs it on the host. Review changes before
restarting, or use `tackle-cli-jail` when that matters.

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
