# Tackle plugin system: implementation and proposed harness design

**Status:** The trusted catalog and startup-only loading of explicitly enabled,
externally precompiled Mix projects are implemented. The trusted enablement
file is `$TACKLE_HOME/plugins.json` (version 1; see [PLUGINS.md](PLUGINS.md)).
There is no universal `Tackle.Plugin` behaviour, automatic discovery, implicit
build, hot reload, or plugin-management command. Remaining compatibility and
executable-path verification are described below.

## What works today

Tackle accepts trusted modules **already available to the running BEAM**:

- Adapters are always explicit: trusted host code passes them to
  `Tackle.Config.load/1` (`:available_adapters` or a `:catalog`, one of which
  is required) and as the first argument of `Tackle.Providers` and
  `Tackle.Auth.Flows` functions. There is no application-environment
  adapter list, and nothing discovers projects or adds code paths. Whether the
  providers offer a model is checked once, after the merge below, for every
  adapter source. `Tackle.Lib.LLM` is the adapter contract; neither CLI
  arguments nor the user config file may name adapter modules.
- `Tackle.Providers.available_providers/2` turns those adapters into providers
  (`Tackle.Lib.LLM.Provider`), the configured instances that model references
  name (`provider/model`): each adapter's default providers, accounts recorded
  by `tackle auth login ADAPTER --as NAME`, and the `config.json` `"providers"`
  object, whose entries name an already-available adapter type id and carry
  opaque settings. Data declares providers; it still never names modules.
- `Tackle.Config.new/1` accepts `:tools` and `:hooks` module lists from trusted
  code. It checks tool callbacks (`name/0`, `description/0`,
  `parameters_schema/0`, `execute/2`), schemas, and names as
  `Tackle.Lib.Tool.Registry` does, and rejects duplicate tool names. Hooks
  must implement at least one `Tackle.Lib.Hook` callback, as in the catalog.
  The defaults come from `Tackle.Tools.default/0`.
- `$TACKLE_HOME/config.json` selects `model`, `thinking`, the decision model
  (`decision_model`), subagent profiles' models (`agents`), review defaults
  (`review`), and the switchable features (`session_titles`, `watchdog`,
  `narration`, `compile_gate`), carries the CLI's own `show_subagent_sidebar`
  and `jail` fields, and may declare `providers` of available adapters; it
  never names executable modules. A project's `.tackle/config.json` may set
  the same fields except `providers`, `show_subagent_sidebar`, and `jail`.
  Environment settings select model and thinking, not executable modules. Hosts can
  pass trusted `Config.load(overrides: ...)` for tools and hooks; there is no
  user-file schema for either. `Config.update/2` changes a built configuration's
  model, thinking, step limit, context, and adapter options with the checks of
  `Config.new/1`; a running session (`Tackle.reconfigure/2`) changes only model
  and thinking while idle.
- `Tackle.Coding.scope_spec/2` assembles CLI coding scopes. A trusted host can
  pass additional `:root_tools` modules. Root tools are not automatically
  available to every child: explicit profile tool names resolve against the
  root's tools plus the review output tools (`Tackle.Tools.review/0`).
  Profiles with no explicit tool list inherit the configured tools, not every
  root-only tool. Markdown profiles under `$TACKLE_HOME/agents` and
  `.tackle/agents` select from those tools, and naming any other tool fails
  the scope, so a host that restricts its tools to `read` cannot get `write`
  through a project profile; they cannot load plugin modules. Built-in
  profiles drop the tools the host did not configure. Invalid profile definitions cause scope
  construction to fail. `Tackle.Lib.Tool.Registry` materializes the selected
  modules for execution; it is not a global plugin registry.
- The CLI bundles the Codex, DeepSeek, Anthropic, OpenRouter, and Ollama
  adapters as fixed dependencies. Its experimental
  MCP client starts connections separately; the CLI adds the discovered tool
  modules to its catalog (source `:cli_mcp`) and grants them to the root by
  name through `catalog_root_tools` in `Tackle.Coding.scope_spec/2`; children
  opt in by name. MCP server failures are handled by that integration, not by
  a general plugin loader.

- `Tackle.Plugins.Catalog.new/1` (in `packages/tackle`) now validates explicit
  `%{module: ..., source: ...}` entries for adapters, tools, and hooks, keeps
  their declaration order and provenance, and rejects duplicate adapter IDs,
  default provider IDs shared by two adapters (naming both), tool names, and
  repeated hook modules. Catalog-selected hooks must implement
  at least one Hook callback, as `Config.new/1` requires.
  `Catalog.resolve_tools/2` only resolves names already in that catalog—it
  does not grant them. No external project discovery/loading is involved.
  `Config.load(catalog: catalog)` selects its adapter and hook modules, leaving
  tool grants to the caller; it rejects simultaneously specifying
  `available_adapters` or hook overrides. `Coding.scope_spec(catalog: catalog,
  catalog_root_tools: ["name"])` explicitly grants named catalog tools to
  the root while retaining its existing trusted profile-name selection. A
  catalog tool conflicting with a built-in coding tool is rejected. These are
  trusted host-code entry points, **not** user-file syntax.
- The CLI assembles one catalog of its bundled adapters, built-in tools,
  delegation tools, connected MCP tools, and the contributions of enabled
  plugin projects for new coding scopes. MCP and plugin tools are granted
  explicitly to the root; subagent profiles still opt in by name.

Source entry points: `packages/tackle/lib/tackle/{plugins,config,coding,tools}.ex`,
`packages/tackle/lib/tackle/config/file.ex`,
`apps/tackle_cli/lib/tackle_cli/{distribution,run}.ex`. The public behaviour
contracts are in `packages/tackle_lib/lib/tackle_lib/{llm,tool,hook}.ex`.

## Implemented: enabled-project loading and remaining host work

`Tackle.Plugins.Loader.load/1` preflights explicitly configured `_build/prod/lib`
applications and selected modules without invoking Mix or evaluating `mix.exs`.
It checks module ownership, duplicate application/module identities, and missing
application dependencies before adding code paths; then starts selected OTP
applications and returns the selected contributions as a validated
`Tackle.Plugins.Catalog`. The CLI loads it once when it starts
(`Tackle.CLI.Distribution.load_plugins/0`) and fails when enabled projects are
invalid or conflict with its bundled contributions. Its one catalog builder
(`Tackle.CLI.Distribution.catalog/1`) merges them into the catalog every
command uses: sessions, `tackle auth`, the model lists, and `tackle sdk`'s
tools. It grants the selected tools to the root.
More comprehensive compatibility checks and real executable-path tests remain.

`packages/tackle` owns catalog validation and project loading.
Neither `tackle_lib` nor `tackle_runtime` should discover plugins. CLI coding
scopes use a trusted catalog. An embedding application can
continue to provide modules and use `Tackle.Config.new/1` without opting into
the catalog or loader.

```text
trusted host/distribution modules + explicitly enabled user projects
                  │
                  ▼
         validate builds and load code
                  │
                  ▼
       resolve and validate catalog
   (adapter, tool, hook + project provenance)
                  │
                  ├─ available models / provider account flows
                  └─ selected scope configuration
                      (root grants, hook order, child tool allowlists)
```

This is an *ordering of responsibilities*, not a new public API. Keep source
location, build output, code loading, contribution selection, and per-agent
authorization separate. Discovery of a directory must not execute it;
loading a project must not grant all of its tools to every agent. Do not put
module names into `config.json` without a deliberate trusted enablement design.

### Catalog validation and remaining work

Catalog assembly for already-loaded modules is implemented and tested. Each
selected entry carries its source and module. Adapter IDs and models, tool
callback availability and names, and hook callback presence are checked.
Declaration order is preserved; tools are only granted when selected for the
root or a child. The CLI is the only host that builds a catalog, in one
place (`Tackle.CLI.Distribution.catalog/1`). Future work should add a
host-wide validation boundary for default tools and explicit grants, and
refine errors that identify both sides of a conflict. In particular, the
catalog does not independently know all tools provided by a host until that
host includes them in validation; `Coding.scope_spec/2` also checks catalog
names against its built-in coding tools. Direct trusted `Config.new/1` remains
available to embedding hosts with its existing validation rules.

The catalog feeds selected module lists into existing `Config.load/1` and
`Coding.scope_spec/2` paths, rather than adding another agent loop. Keep model
choice separate from adapter availability. CLI root-only grants and profile name
resolution remain distinct; adding a tool to the catalog alone does not grant
it. A running scope keeps its selected configuration; it does not follow mutable
catalog changes. The complete prospective composition must be validated before
new scopes consume externally loaded code.

### Enabled-project loading

A startup phase reads an **explicit** enabled-project selection from
harness-owned `$TACKLE_HOME/plugins.json`, documented in [PLUGINS.md](PLUGINS.md).
The default suggested source location is
`$TACKLE_HOME/plugins/`, with one normal Mix project per directory. A candidate
is inert until enabled. Project-local `.tackle/plugins/` auto-execution is not
part of the first version. Store project references and selected modules, not
copies of source, compiled output, or credentials.

Initially users compile their own trusted projects and dependencies with a
compatible installed toolchain. At startup the harness reads compiled `.app`
metadata, checks selected modules belong to the enabled application, detects
application/module collisions, and requires host-provided dependencies to have
the same version and only modules the host has before adding code paths; the
plugin then runs against the host's copy. Modules whose code differs from the
running ones (the MD5 of the built beam, `:beam_lib.md5/1`, against the loaded
module's `module_info(:md5)`), as with a dependency built by another compiler
version, are allowed with a logged warning, because matching every
dependency's compiler is hard for users; building with the host's toolchain is
still the supported way. Comparing code rather than file bytes also works
where the running beams are no readable files, as in an escript's archive, and
ignores stripped debug information. It then
starts selected OTP applications and validates contribution callbacks. There
is no general Elixir/OTP/ABI compatibility proof; incompatible or native builds
may still fail when loaded. No implicit dependency fetch, Mix build inside a
Burrito executable, arbitrary code replacement, or silent fallback to bundled
configuration. Cross-project initialization order and partial failure handling
need further testing.

BEAM loading is not transactional: once a module or application is loaded,
there is no general promise of rollback or isolated competing versions. The
proposed policy is to **fail startup** for an invalid enabled project; do not
pretend that an unsuccessful load leaves a clean runtime for a different
configuration. Changes to plugin code or enablement require a process restart.
Ordinary OTP applications own long-lived plugin services under supervision;
`Tackle.Runtime` continues to supervise scope and tool execution. A universal
plugin fiber, dynamic service container, hot reload, and unloading are not v1
requirements.

### Host and security boundaries

Loaded Elixir code has the host process's privileges. Module allowlists and
profile tool lists govern what the agent is offered; they do **not** sandbox a
malicious plugin, Bash, or a plugin's OTP application. Keep project-local
execution deferred and never treat discovery as authorization. A future socket
SDK must expose deliberate versioned JSON-compatible snapshots/events and
commands, not raw BEAM modules, PIDs, credentials, or plugin processes. Its
frontend contracts and reconnect/cancellation semantics are separate work,
not implied by adding the initial loader.

## Verification order

1. Keep catalog tests with fake already-loaded adapters/tools/hooks: success,
   duplicate IDs and tool names, missing/invalid modules, hook order, and
   built-in versus catalog conflicts. Check that child allowlists cannot
   resolve names outside the trusted set and root-only tools stay root-only.
2. Expand integration tests through actual `Config.load/1`,
   `Coding.scope_spec/2`, and CLI host paths—not only catalog unit tests.
   Preserve embedding hosts that pass module lists directly.
3. Loader tests with a separately built Mix fixture and dependency/OTP app:
   missing builds, incompatible or conflicting identities, startup failure,
   no implicit compilation, and repeat startup in a fresh BEAM. Exercise the
   **built** CLI/Burrito entry path; the standalone
   [Burrito experiment](../experiments/burrito_file_loader/README.md) proved
   feasibility for one compatible fixture, not production loader behavior.
4. If a future contract registers resources dynamically, make ownership and
   cleanup explicit and test failure, cancellation and disposal. Do not add a
   generic lifecycle solely to support the initial module catalog.

Decisions still required for later work: compatibility/dependency policy,
conflict diagnostics, and the extent of any frontend plugin contract. See [PLUGINS.md](PLUGINS.md) for the broader plugin
model and deferred capabilities.
