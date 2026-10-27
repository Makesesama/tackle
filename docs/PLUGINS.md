# Plugins and extensions

**Status: startup loading of explicitly enabled, precompiled Mix projects is implemented.**
The harness provides the loader (`Tackle.Plugins.Loader`); the CLI is the one
host that calls it, at startup, to load selected contributions from a trusted
user file. `apps/tackle_hub` loads no plugins. No project-local automatic
discovery, build, fetch, reload, or sandbox is provided. Sections marked
*proposed* and the delivery order describe plans, not supported features. For
the integration points implemented today, see
[PLUGIN_SYSTEM.md](PLUGIN_SYSTEM.md). See the
[architecture specification](architecture-spec.md) for package boundaries.

## What a plugin is

A plugin is ordinary Elixir code, such as a single `.ex` file or a normal Mix
project. There is no required plugin manifest, special package format, or
universal `Tackle.Plugin` behaviour. Capabilities use their existing contracts:
`Tackle.Lib.LLM` for adapters, `Tackle.Lib.Tool` for tools, and `Tackle.Lib.Hook`
for hooks. The harness should document the stable APIs those contracts need;
loading code does not make every internal Tackle module public API. First-party
and user-provided extensions use the same capability contracts.

Keep **source**, **build**, and **registration** distinct:

- Source is the trusted file or Mix project the user owns. A directory entry is
  not itself an enabled capability.
- The build contains compiled BEAM applications and their dependencies. Loading
  code must not implicitly fetch dependencies or build arbitrary projects.
- Registration explicitly chooses which adapter, tool, or hook modules to make
  available. Loading a project does not expose all its modules or grant its
  tools to every agent or subagent.

The initial registration approach is **explicit module names in trusted
configuration**, validated against each capability contract. It avoids hidden
global registration at import time. An optional entry function may be considered
later for extensions that cannot reasonably be declared this way; its API and
lifecycle are not yet designed. Stateful extensions use normal OTP applications
and supervision, not a second plugin lifecycle system.

A plugin project is a unit of code distribution, not a universal runtime object.
The harness assembles a **resolved catalog** of selected contributions, with
provenance (source, contribution kind, and module); `Tackle.Plugins.Catalog`
now validates trusted already-loaded modules and modules from explicitly enabled
precompiled projects. It is not a new `tackle_lib` registry. Start with
adapters, tools, and hooks; do not define all future extension points in terms
of those three lists. A new capability should specify its contract, validation,
host, scope, and lifetime when a real use case needs it. A future activation
callback could cover setup and cleanup that declarative module selection cannot
express, without imposing it on existing plugins.

## Default location, trust, and enablement

The suggested source location is `$TACKLE_HOME/plugins/` (normally
`~/.tackle/plugins/`), but **nothing in that directory is discovered or enabled
automatically**. Build a trusted Mix project and its dependencies externally,
using a compatible Elixir/OTP installation, with `MIX_ENV=prod mix compile`.
Put the following in `$TACKLE_HOME/plugins.json` (separate from the existing
`config.json` model/thinking settings):

```json
{
  "version": 1,
  "projects": [
    {
      "path": "/absolute/path/to/my_plugin",
      "app": "my_plugin",
      "adapters": ["MyPlugin.Adapter"],
      "tools": ["MyPlugin.SearchTool"],
      "hooks": ["MyPlugin.AuditHook"]
    }
  ]
}
```

`app` is the compiled project's OTP application name (not a Mix project module
name); selected module names must belong to that application's `.app` metadata.
An absent file enables no projects. Unknown keys, malformed entries, missing
builds/dependencies, or conflicting application/module names fail startup. A
dependency the host also runs, such as `tackle_lib`, is shared: the plugin
runs against the host's copy. Its build must have the host's version, and
every module it lists must exist in the host
(`{:plugin_dependency_module_missing, path, app, module}` otherwise). Modules
whose compiled code differs from the host's (compared by MD5, so it also works
in an escript), usually because the plugin was built with another Elixir or
OTP compiler, are allowed but discouraged: startup logs a warning per such
dependency. Build plugins with the Elixir, OTP, and dependency versions of the
Tackle you run. A build without the named application's `.app` file fails with
`{:plugin_project_app_not_found, path, app}`.
Project paths must be absolute. The loader reads `_build/prod/lib` directly;
it never runs Mix, evaluates `mix.exs`, or copies source or credentials. Its
`Tackle.Plugins.Loader.load/1` API, which returns the contributions as a
validated `Tackle.Plugins.Catalog`, also accepts `path:` for embedding/tests.
Do not store builds in Burrito's extraction cache. BEAM loading cannot be
rolled back: fix a failure and restart the host; do not call the loader again
in a running process.

Enablement is user-wide; session and subagent tool
allowlists remain independent. Installing a tool never automatically authorizes
it for all agents. The harness composes a scope from the validated catalog:
selected adapter/model, explicitly granted root tools, hooks in a defined order,
and per-profile tool selections resolved only against trusted available tools.
Being in the catalog does not grant a capability to every agent or subagent.
The existing catalog API and tool grants remain separate from loading. The CLI
grants the tools of enabled projects to its root agent; subagent profiles
still opt in by name.

Project-local `.tackle/plugins/` and per-repository approval are deferred:
opening an arbitrary repository must not execute its code. Loaded extensions
run with the full privileges of the Tackle process. Discovery is not
sandboxing; never scan arbitrary working directories for executable code.

## Mix-project workflow

Tackle supports separately **precompiled** projects. The user builds a trusted
project and its dependencies with an installed, compatible Elixir/Mix toolchain
(for example, `MIX_ENV=prod mix deps.get && MIX_ENV=prod mix compile`). They
configure the *project path*, not a specific `ebin` path. At startup, the
loader locates compiled applications, checks they match what is enabled, adds
approved code paths, starts required OTP applications, validates the selected
capability modules, and composes the resulting contributions for new scopes.
This loading path is implemented; compatibility with arbitrary external
projects, native libraries and mismatched Elixir/OTP versions is **not**
guaranteed. Missing builds, dependency conflicts and invalid modules fail
startup, not silently trigger a build.

A later explicit preparation step could invoke the user's Mix toolchain as a
**separate process**, compiling into a Tackle-owned cache. Build caching,
version checks, error reporting, and any project entry-script convention need
concrete design before implementation. Do not assume Mix can run inside the
Burrito release, and do not fetch or compile third-party code unexpectedly at
startup. A managed toolchain and binary-only installation are deferred.

The harness in `packages/tackle` owns validation, loading, and composition;
nothing discovers projects. `tackle_lib` retains the provider-neutral engine
and capability contracts; applications embedding that library need not use
this loader. A future web or socket-facing frontend on the harness should
consume the same resolved harness configuration rather than implement a
separate plugin registry.

## Composition and conflict policy (proposed)

Build and validate the catalog before publishing it for new scopes. Reject
invalid selected modules, duplicate adapter IDs and tool names, unavailable
required contributions, and conflicting BEAM application/module identities;
include project and contribution names in errors. Do not quietly replace
built-in capabilities, already-loaded modules, or applications. Hook ordering
must be explicit and deterministic, not derived from discovery or filesystem
order. Resolve profile tool names against the trusted catalog, never by
converting an untrusted string into a module name. Treat adapter selection,
root grants, and child grants as distinct decisions.

Validation can reject many conflicts before code is loaded, but loading paths
and starting OTP applications are not an atomic transaction. Once code has been
loaded, the BEAM cannot promise a clean rollback to an earlier set of modules.
An invalid enabled project should fail startup with an actionable error, rather
than silently disappearing from the user's configured capabilities. The exact
failure, compatibility, and dependency policy remains to be designed and tested.

## Lifetimes and ownership (proposed)

The first loader is startup-oriented: an enablement or build change requires a
restart. An ordinary plugin OTP application may own long-lived state under its
own supervision; each agent scope continues to own its tool work and
cancellation through `tackle_runtime`. Selected modules are snapshotted into
new scope configurations. A running scope should not have its tools or hooks
silently swapped because catalog configuration changed. Hot reload, dynamic
unregistration, and a general dependency-injection/service graph are deferred.
If a future extension point registers resources dynamically, its contract must
assign an owner, a cleanup operation, and tests proving disposal, including
startup failure and cancellation paths. Scope membership and authority should
not be inferred merely from a plugin's code location.

## What the Burrito experiment establishes

The standalone [experiment](../experiments/burrito_file_loader/README.md) loaded
an external `.ex` file and a separately compiled Mix project from a Burrito
executable. The Mix fixture includes a local path dependency and an OTP
application. Neither plugin was packaged into the executable; the Mix project
was compiled externally. This supports the precompiled workflow's **feasibility**,
not its implementation in Tackle's CLI or support for arbitrary projects.

A BEAM can load only one version of a given application/module at a time.
Before promising general Mix-project support we must define compatibility
checks for already-loaded applications, Elixir/OTP versions, dependency
conflicts, and the target platform. Native libraries may also require the
release's target ABI (Linux Burrito uses musl). Do not silently replace code in
an existing release or promise arbitrary dependency combinations.

## Frontend extensions and socket clients (later)

A plugin project may eventually contain distinct agent-side and presentation
capabilities for different hosts. Agent-side code runs in the trusted Tackle
BEAM; a CLI, web app, or independent socket client should receive only
explicitly exposed, versioned, serializable contracts. Never send BEAM modules,
PIDs, raw hooks, credentials, or runtime handles as frontend plugin APIs. For
example, a future question capability could keep a pending request in the
session host and expose a correlated question/answer contract rendered by either
TUI or web. Headless behavior, cancellation, reconnects, and uncertain outcomes
must be specified before implementing that contract. This is a possible
vertical slice, **not** a currently supported facet or socket plugin API.

## Delivery order and open decisions

1. Extend the already-loaded-module catalog and host integration (implemented).
2. Load explicitly enabled, separately precompiled projects (initial startup
   path implemented; executable-path validation and compatibility remain limited).
3. Add a setup/lifetime contract only for a concrete capability that cannot be
   expressed through selected modules.
4. Prototype one cross-host interaction before generalizing frontend plugins
   or a socket SDK.

Compatibility checks, conflict diagnostics and enablement UX require further
work. Invalid enabled projects fail startup rather than being skipped. Hot reload,
unloading, marketplace, plugin-specific package management, and project-local
auto-execution are out of scope. Future plans above are not supported commands
or public APIs until implemented and tested.
