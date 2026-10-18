# Project node: plan

Status: **plan, partly implemented.** Steps 1 to 3 (the spike, standard
input in the executor, and the broker with `compile` in
`packages/tackle_elixir`) are done; the rest is a proposal. It follows from
[`ELIXIR_INTEGRATION_RESEARCH.md`](ELIXIR_INTEGRATION_RESEARCH.md): running
`mix compile` in a shell and parsing its output is something any harness can
do. What a harness written in Elixir can do and others cannot easily do is
work with the project as a running BEAM system: compile it in-process and get
diagnostics as data, ask the compiler who calls a function, read the docs and
specs of the code that macros actually generated, and later look inside the
running application.

The **project node** is that capability: a long-lived BEAM node for the
user's Mix project, started with the project's own Elixir, inside the jail
when the session is jailed. A **broker** node beside it, in the same jail,
drives it over Erlang distribution, as the Elixir language servers drive
their project nodes; the harness talks to the broker over the exec-server's
framed term protocol and never joins the distribution itself.

## What it is for

In order of value, each later step building on the earlier ones:

1. **Compile as data.** `Mix.Task.run("compile", ["--return-errors", ...])`
   in the node returns `Mix.Task.Compiler.Diagnostic` structs: file,
   position, span, severity, message, and details. No output parsing, and a
   warm VM recompiles incrementally faster than a fresh `mix compile`. The
   end-of-turn gate (`Tackle.Elixir.CompileGate`) becomes a consumer of this
   instead of a shell command.
2. **The code that exists after compilation.** Docs, specs, callbacks, and
   source locations from the build (`Code.fetch_docs/1`,
   `Code.Typespec.fetch_specs/1`, `module_info(:compile)`), including
   functions that `use`, Ecto schemas, Phoenix routers, and Ash DSLs
   generate, and dependency code at the version in `mix.lock`. This is where
   the research expects lookups to pay off: answers grep cannot give.
3. **Who depends on what.** Callers of a function and compile-time
   dependencies between modules, from the compiler's own manifests or a
   compilation tracer. For the agent: what a change can break. For review
   (`Tackle.Review`): the real blast radius of a change and pull requests
   that add compile-time dependency cascades.
4. **Later: the running system.** A runtime mode with the application
   started, for evaluation, processes, supervision trees, ETS, and logs.
   Where a project already uses Tidewave, Tackle should use it through MCP
   instead of duplicating it.

How the agent sees each of these follows the research: the compile check runs
automatically at the end of a turn; lookups are one or two tools with
explicit instructions, adopted only after a small comparison shows they help;
review uses the node's data in its pipeline without asking agents to call
anything.

## Lessons from the Elixir language servers

Expert, Lexical, and Next LS all run the user's project in a node of its own
and drive it over Erlang distribution:

| | Start | Code in the project node | Build directory |
| --- | --- | --- | --- |
| [Expert](https://github.com/elixir-lang/expert/blob/main/pages/architecture.md) | project's `elixir`, EPMD-less distribution | engine built for the project's Elixir/OTP and namespaced (`XPEngine`) | `.expert/build` |
| [Lexical](https://github.com/lexical-lsp/lexical/blob/main/apps/remote_control/lib/lexical/remote_control/project_node.ex) | `elixir --name ... --cookie ... --no-halt -e "Node.connect(manager)"` | prebuilt `remote_control` code paths added with `-pa`, then an `:rpc` bootstrap | not checked |
| [Next LS](https://github.com/elixir-tools/next-ls/blob/main/lib/next_ls/runtime.ex) | `elixir --no-halt --sname ... --cookie ... -S mix loadpaths --no-compile` | its private compiler module sent as source: `:rpc.call(node, Code, :compile_file, [path])` | `MIX_BUILD_ROOT=.elixir-tools/_build` |

Expert's architecture document states the reasons most clearly:

- The engine runs in a **separate OS process started with the project's
  `elixir` and `erl`**, because the project may use other Elixir and OTP
  versions than Expert's release.
- Expert **compiles the engine for the project's versions** in a separate
  build VM, so build-time code does not pollute the engine.
- It **namespaces** its modules (`Engine` becomes `XPEngine`) because the
  engine has dependencies that could collide with the project's, and filters
  its own modules out of results.
- It **keeps the engine's dependencies minimal** by design.
- It compiles into its **own build path** (`.expert/build`) and uses private
  `MIX_HOME`, `MIX_ARCHIVES`, and `REBAR_CACHE_DIR`.
- The manager and engine talk over **distributed Erlang**, without EPMD.

We take all of it, with one change in where the manager runs. Distribution
is a trust relation, not a channel: a connected node can spawn processes on
the other and call any function there (`:erpc.call(node, :os, :cmd, [...])`),
and the cookie only guards against connecting by accident (Erlang's own
documentation: "security against accidental misuse"). The language servers
run everything as one user with no boundary, so that does not matter to them.
Tackle can run the agent's commands in a jail; a project node in the jail
that is connected to the harness outside it would be a way out. So the
broker, the node that plays Expert's manager, runs **inside** the jail, and
the boundary is crossed only by framed terms that the harness checks.

## Design

### Three parts

```text
 harness (host, no distribution)
   │  framed terms over the executor (checked like exec-server frames)
   ▼
 broker node ───────── Erlang distribution (inside the jail) ─────────┐
   │                                                                  │
   ▼                                                                  ▼
 project node: dev (compile, docs, xref)          later: test node, the running app
```

- **Host side**, in `packages/tackle_elixir`: `Tackle.Elixir.ProjectNode`, a
  GenServer per session and project that starts the broker through the
  session's executor, owns its command, sends requests, matches replies, and
  enforces limits and timeouts. It treats everything the broker says as
  hostile, like `Tackle.Exec.Client` does with the exec-server.
- **Broker**, a small VM in the jail (local when not jailed) started with the
  project's `elixir`. It starts a distributed node of its own, starts and
  connects the project nodes, and turns host requests into `:erpc` calls on
  them. It holds no secrets: everything it can do, jailed code can do anyway.
- **Project nodes**, started like Next LS's: `elixir --sname ... --cookie ...
  -S mix loadpaths --no-compile`, with our helper modules sent as source and
  compiled there (`Code.compile_file/1`), so they match the project's Elixir
  and OTP without a build step. The helpers have **no dependencies** and a
  prefix of their own (`TackleProjectNode.*`), so there is nothing to
  namespace, and are filtered out of results. They must stay compatible with
  the oldest Elixir we support (see open questions). Plain `Mix` and `Code`
  calls need no helper at all.

Distribution brings what made the language servers choose it: several nodes
per project (a `test` node, umbrella applications, the running application
when the agent starts it in the jail) without a protocol of our own for each,
monitoring, and plain function calls instead of request handlers.

### Starting the nodes

- The broker's source and the helpers' source are written to the executor's
  temporary directory (`Tackle.Executor.write/4`, `tmp_dir/1`), so they are
  visible inside the jail and not in the workspace.
- The broker is started through the session's executor with the project's
  `elixir` and starts distribution itself (`Node.start/2`) with a random
  cookie from `:crypto.strong_rand_bytes/1`.
- The broker starts each project node in the project root as a bare node,
  compiles the helper there, and loads the project with
  `Mix.CLI.main(["loadpaths", "--no-compile"])` over `:erpc` (see "Spike
  results" for why not on the command line): the project and its
  dependencies are loaded without compiling or starting the application (no
  Phoenix endpoint, no Repo connections), so a node starts even when the
  project does not compile; it compiles on request and returns the errors as
  data.
- `elixir` and `mix` are the project's, found on the jail's `PATH` (the
  project's devshell) or the host's. When there are none, the node is
  unavailable and its consumers fall back or stay quiet.
- **Distribution inside the jail must not reach outside it.** The jail
  shares the host's network namespace today, so a node listening on loopback
  TCP is reachable from host processes, and the host's EPMD from the jail.
  The nodes therefore run without EPMD (as Expert does), listen on loopback
  only, use a strong random cookie and `-connect_all false`, and never
  connect to a node they did not start. Distribution over Unix domain
  sockets in the jail's private `/tmp` would remove the network exposure
  altogether; OTP ships only an example carrier for it
  (`erl_uds_dist`), so this is a spike question.

### The channel between harness and broker

The broker reads requests from its standard input and writes replies to its
standard output as 4-byte length-prefixed Erlang terms, decoded on the host
with the rules of `Tackle.Exec.Protocol`: no compressed terms,
`binary_to_term(..., [:safe, :used])`, a size cap before buffering, and a
closed set of reply shapes with bounded fields.

The executor has no way to write to a command's standard input today
(`docs/EXEC_SERVER_PLAN.md`: stdin is not part of version 1). The plan adds
it:

- **Exec protocol:** a `{:input, id, binary}` request, bounded in size. No
  half-close is needed: the node runs until it is told to stop or killed.
- **Executor contract:** an optional `Tackle.Executor` callback, such as
  `input(config, handle, binary)`, implemented by `Tackle.Executor.Local`
  (writing to the port) and `Tackle.Executor.Jailed` (the new request).

Two more constraints come from the exec-server:

- **Standard error is merged into standard output** in the jail, so any
  stray output corrupts the stream. The broker sends its group leader and
  `:logger` to a log file in its temporary directory before writing the
  first frame (project nodes have their own output, which the broker reads),
  and the host restarts a broker whose stream stops being valid frames.
- **A command dies with the process that started it.** The host side is
  therefore a long-lived process, not a tool or hook call.

Rejected alternatives: distribution between the harness and the jail (see
above; it would also mean enabling distribution in the CLI's VM, reachable by
any local process that learns the cookie); a Unix socket in the workspace,
which the jail can replace with a link to another host socket. Making the
exec-server itself the broker would save the standard-input change, but it
would give the exec-server, which runs primitives only, a second role, and
it runs Tackle's OTP rather than the project's.

### Lifecycle

- One broker per session and one `dev` project node per project root,
  started lazily on first use and shared by the root agent and its subagents
  in the same session.
- It lives as a session service beside the session, as the watchdog and
  narrator do (`Tackle.Runtime.RootBackend.services/2`), and stops with the
  session or after an idle period.
- A crashed or invalid broker or node is restarted on the next request, with
  backoff; repeated failures mark it unavailable for the session. The broker
  monitors its nodes (`Node.monitor/2`) and stops them when it stops.
- Every request has a timeout and honours the turn's cancellation signal
  (hooks receive it in their context).

### Build directory

Two options, to be settled by the first spike:

- **The project's `_build`**: the same artifacts and diagnostics as the
  user's own `mix compile`, and no second full build. Concurrent compiles
  (the user's server, the agent's `mix test`) rely on Mix's build lock.
- **A private build path**, as Expert does: no interference, but a second
  full build per project and diagnostics that can differ from the user's.

The first is the default to try; the gate and the agent's commands both
compile the user's `_build` today.

### Requests (first version)

| Request | Answer |
| --- | --- |
| `compile` | Status and structured diagnostics, warnings of unchanged files included |
| `docs(module, function, arity)` | Docs, specs, source file and line, for project and dependency code |
| `callers(module, function, arity)` | Call sites from the compiler's data (needs a spike) |
| `stop` | Clean shutdown |

Evaluation of arbitrary code is deliberately not in the first version.

## Security

- The node runs project code: `mix.exs`, macros, dependency code. That is
  what the agent's own `mix` commands do; the node runs where they run, in
  the jail when the session is jailed.
- The harness's VM never runs distribution. Distribution exists only among
  the broker and the nodes it started, all in the same jail.
- Inside the jail: no EPMD, loopback only (or Unix sockets), a strong random
  cookie, `-connect_all false`, no connections to nodes the broker did not
  start. Connecting to a node the user runs **outside** the jail (their own
  `iex -S mix phx.server`) would give the jail that node, so runtime mode
  only attaches to nodes started in the jail; a host-side application is
  reached through Tidewave's tools or not at all.
- Everything from the broker is untrusted: frames are bounded and decoded
  safely, reply shapes are validated, strings (diagnostic messages, docs)
  are only shown to the model or logged, never turned into atoms or code.
- The broker's and helpers' source is written to the jail's temporary
  directory, not the workspace.

## Spike results

A throwaway broker (not in the repository) answered the first spike's
questions on 2026-10-18 with Elixir 1.20.4 / OTP 29, locally and inside the
development jail (`tackle-dev-exec-jail`):

- **EPMD-less distribution works with stock flags.** The broker starts
  distribution at runtime (`Node.start/2`, cookie from
  `:crypto.strong_rand_bytes/1`) in a VM started with `-start_epmd false
  -kernel erl_epmd_node_listen_port PORT -kernel inet_dist_use_interface
  {127,0,0,1}`. Project nodes get the same port and `-dist_listen false`, so
  they never listen and are hidden; they connect out to the broker, and the
  broker calls them over that connection. The cookie reaches the project
  node through its environment, not its command line.
- **Boot through the broker, not `mix loadpaths` on the command line.** With
  `-S mix loadpaths --no-compile`, `Mix.Project.get/0` is set while path
  dependencies are still loading, and a compile started then loads them a
  second time and crashes the node. Starting a bare node in the project
  directory, compiling the helper with `Code.compile_file/1`, and then
  calling `Mix.CLI.main(["loadpaths", "--no-compile"])` over `:erpc` returns
  exactly when the project is loaded.
- **Compile results as data:** `Mix.Task.clear/0` and
  `Mix.Task.run("compile", ["--return-errors", "--all-warnings"])` return
  `{status, [%Mix.Task.Compiler.Diagnostic{}]}` with file, position,
  severity, message, and compiler. Mix's own output goes to the caller's
  group leader, so the broker has to capture it.
- **Timings** (no-op compile, warm node vs. `mix compile` in a shell):

  | Project | Node | Shell |
  | --- | --- | --- |
  | `packages/tackle_runtime` | 86–91 ms | ~460 ms |
  | `apps/tackle_hub` (Phoenix, Ash) | ~350 ms | ~1,270 ms |

  A compile after a breaking edit took 109–133 ms, and the revert 166–345 ms.
  Broker start to project connected: ~190 ms; helper and project loaded:
  ~170 ms more.
- **Generated code is visible:** the Ash resource's `__schema__/1,2` and
  `__changeset__/0`, the router's `__routes__/0` and `__match_route__/3`,
  GenServer callbacks from `use`, with docs and source files.
- **Callers:** `Mix.Tasks.Xref.calls/1` returned 972 call sites with file and
  line in 7 ms and found both callers of `Tackle.Runtime.Limits.new/1`. It is
  deprecated in favour of compilation tracers, so the node should install a
  tracer of its own and use `calls/1` only as a stopgap.
- **Inside the jail** the same broker ran unchanged with the jail's
  `elixir`, and the host could open a TCP connection to the broker's
  distribution port: the shared network namespace exposes it, as expected.
  Joining needs the 24-byte random cookie. OTP 29 has no built-in Unix
  socket distribution (`-proto_dist local` is "not supported"); removing the
  exposure needs a small carrier compiled into each node at boot, which is
  later hardening.

## Order of work

1. **Spike** (done; see "Spike results"): broker and project node locally
   and in the jail, compile as data, docs, callers, timings, exposure. Not
   yet covered: frames between the harness and the broker (they need step
   2), and the oldest Elixir/OTP the boot works with.
2. **Stdin in the executor** (done): protocol version 2 adds `:input`,
   `Tackle.Exec.Client.input/3`, and the optional `Tackle.Executor` callback
   `input/3`, implemented by both executors.
3. **Node and host client with `compile`** (done): `Tackle.Elixir.ProjectNode`
   and `Tackle.Elixir.ProjectNodes`, the broker and helper in
   `packages/tackle_elixir/priv/project_node/`. Differences from the design
   above: the host passes the distribution cookie in `ERL_ZFLAGS`, so neither
   the broker nor the project nodes read or write a cookie file; the broker
   runs under `sh -c '... 2>>broker.log'`, because the VM can write to
   standard error before the broker's code runs; and one broker serves every
   session that shares an executor. Then the compile gate on top of it, in
   place of the shell-based one.
4. **`docs`**, a lookup tool with instructions, and the comparison from the
   research document (no lookup, available, prompted) on macro-heavy tasks.
5. **`callers` and compile-time dependencies**, and their use in
   `Tackle.Review` and the hub.
6. **Runtime mode** and Tidewave integration.

## Open questions

- The oldest Elixir version the node source supports (1.15 has
  `--all-warnings`; 1.14 is still common), and how to test it (a Nix devshell
  with an older Elixir in CI).
- How the node finds `mix` when the project's devshell is not cached in the
  jail, and whether the jail should offer a default Elixir.
- Whether one node per session is enough for umbrella projects, or one per
  application.
- `MIX_ENV`: `dev` for compilation; tests may need a second node in `test`.
- How `callers` is computed: xref manifests (whose APIs changed across Elixir
  versions) or a tracer the node installs for its own compiles.
