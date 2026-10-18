# tackle_elixir

Elixir project nodes for Tackle agents (`Tackle.Elixir.*`, `:tackle_elixir`):
compile and inspect a user's Mix project in a BEAM node of its own, where the
agent's commands run, and a compile gate built on it. It depends on `tackle_lib`, `tackle_tools`, and
`tackle_exec` only, so any host that runs agents with those packages can use
it. The design and the measurements behind it are in
[`docs/PROJECT_NODE_PLAN.md`](../../docs/PROJECT_NODE_PLAN.md).

## How it works

```text
 host: Tackle.Elixir.ProjectNode (no distribution)
   │  framed terms over the broker's standard input and output,
   │  through a Tackle.Executor (checked like exec-server frames)
   ▼
 broker ──── Erlang distribution, inside the executor ────► project node per Mix project
```

- `Tackle.Elixir.ProjectNode` writes the broker and its helper
  (`priv/project_node/`) to a fresh directory in the executor's temporary
  directory and starts the broker with the `elixir` on the executor's
  `PATH`: the project's own Elixir, inside the jail when the session is
  jailed.
- The broker starts one project node per Mix project as a bare node in the
  project directory, compiles the helper there from source, and loads the
  project with `mix loadpaths --no-compile` without starting it (no Phoenix
  endpoint, no Repo connections). A node starts even when the project does
  not compile.
- Distribution stays among the broker and the nodes it started: the broker
  listens on loopback without EPMD, the project nodes do not listen at all
  (`-dist_listen false`), and the cookie comes from the host through the
  environment (`ERL_ZFLAGS`), never a command line or a cookie file. The
  host's VM never joins: a connected node can run any code on the other, so
  distribution across the jail boundary would be a way out of it.
- The host treats the broker as hostile: frames are limited to 4 MiB,
  decoded with `Tackle.Exec.Protocol.decode/1`, and accepted only in the
  shapes `Tackle.Elixir.ProjectNode.Protocol` lists, with every field
  checked. A violation stops the client and the broker.
- The broker's standard error and logs go to `broker.log` in its directory,
  never into the frames. A clean shutdown removes the directory.

## Use

```elixir
{:ok, result} = Tackle.Elixir.ProjectNodes.compile(executor, "/work/my_app")

result.status       #=> :ok | :error | :noop
result.diagnostics  #=> [%Tackle.Elixir.Diagnostic{severity: :error, file: "/work/my_app/lib/a.ex",
                    #      line: 3, column: 17, message: "undefined function ...", compiler: "Elixir"}]
```

`Tackle.Elixir.ProjectNodes` keeps one client per executor, started on first
use; sessions that share an executor share its broker. A compile returns
the diagnostics of the whole project, including warnings of files it did not
recompile. `compile/3` accepts `:timeout_ms` and `:cancellation_signal`;
giving up does not stop a compile that is already running, whose result is
discarded.

A client stops after 30 minutes without requests (`:idle_timeout`), and when
its broker fails; the next request starts a new one. Project nodes halt when
their broker goes away.

On this repository, a warm compile with nothing to do takes about 70 ms
(`mix compile` in a shell: about 460 ms), and inside the development jail a
broker starts in about a second.

## Compile gate

`Tackle.Elixir.CompileGate` is a `Tackle.Lib.Hook` built on the project
node. It gates the end of the agent's turn, the one check that published
experiments found to help agents
([`ELIXIR_INTEGRATION_RESEARCH.md`](../../docs/ELIXIR_INTEGRATION_RESEARCH.md)):

1. Before the first `edit` or `write` in a turn that changes an Elixir
   source of a Mix project (`.ex` files and templates, `mix.exs`,
   `config/*.exs`; not tests or `deps/`), it compiles the project to record
   the diagnostics that already exist.
2. When the model gives its final answer, it compiles each changed project
   again. Errors and warnings that were not there before are sent back as one
   user message (`before_turn_end/2` returns `{:continue, [message]}`), and
   the turn continues so the model can repair them.
3. The turn completes once nothing new is reported, or after `max_rounds`
   continuations.

The message lists the diagnostics as the compiler prints them, errors first,
with paths relative to the project, and does not tell the model to fix every
one. A diagnostic keeps its identity when edits move it to another line.
The gate stays quiet otherwise: a project whose node cannot start or load
it, or whose compile times out, is skipped, and without a baseline only
errors are reported. Changes made through `bash` are not watched.

The hook reads `Tackle.Elixir.CompileGate.Settings` from the context key
`:compile_gate`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Whether the gate runs |
| `max_rounds` | `2` | Continuations per turn; `0` checks and logs without continuing |
| `timeout_seconds` | `120` | Longest wait for one compile; a slower one is skipped |
| `warnings` | `true` | Report new warnings, not only errors |
| `log_path` | `nil` | Append every baseline and check to this file as a JSON line |

```elixir
{:ok, settings} = Tackle.Elixir.CompileGate.Settings.new(max_rounds: 2)

Tackle.Lib.new(
  llm: llm,
  tools: tools,
  hooks: [Tackle.Elixir.CompileGate],
  context: %{cwd: cwd, executor: executor, compile_gate: settings}
)
```

The harness does this for every session `Tackle.Config.load/1` builds, with
the log at `$TACKLE_HOME/logs/compile_gate.jsonl`, and reads the settings
from the `compile_gate` object of `config.json` (`false` turns it off).

Each log line records one decision:

```json
{"at":"2026-10-18T19:22:11Z","session_id":"...","event":"check","project":"/work/app",
 "outcome":"blocked","round":0,"errors":1,"warnings":0,"duration_ms":71}
```

`event` is `baseline` or `check`. A check's `outcome` is `passed`, `blocked`
(the turn continued), `not_blocked` (new diagnostics, but `max_rounds` was
reached or is `0`), `timeout`, or `unavailable`. A blocked check followed by
a passed one in the same session is a repair that worked; whether the gate
blocked work that was fine has to be judged by reading the reported turns.

## Requirements and limits

- `sh` and `elixir` on the executor's `PATH`. Without them the client fails
  to start (`{:error, {:broker_exited, 127}}`).
- The broker and helper use only Elixir APIs available since 1.15; only
  the current toolchain (Elixir 1.20, OTP 29) is tested so far.
- Compiles use the project's own `_build` and the inherited `MIX_ENV`
  (default `dev`).
- Inside a jail that shares the host's network namespace, the broker's
  loopback port is reachable from the host; joining needs the random cookie.

## Checks

```sh
(cd packages/tackle_elixir && mix deps.get)
(cd packages/tackle_elixir && mix compile --warnings-as-errors && mix test)
(cd packages/tackle_elixir && mix format --check-formatted)
```

The tests need `sh`, `elixir`, and `erl` on `PATH`: they start real brokers
and project nodes for throwaway projects, through the local executor and
through the exec-server (without a jail).
