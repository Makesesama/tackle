# Exec-server plan: jailed execution with an unjailed core

**Status: phases 1 to 3 implemented; phase 4 is a plan.** `packages/tackle_exec`,
the `Tackle.Executor` seam, the CLI integration, and the Nix launchers are
implemented. The Nix launchers evaluate, but they have not yet been run under
Bubblewrap on a host.

## Goal

Today the production jail (`tackle-cli-jail`) runs the whole Tackle BEAM inside
Bubblewrap. The core therefore cannot use host facilities such as the Wayland
clipboard, and the jail must mount `~/.tackle` (credentials and sessions)
read-write.

This plan inverts that: the core (TUI, provider adapters, credentials, session
store, tool logic) runs on the host, and every operation that touches the
workspace or spawns a process runs inside one long-lived jail through an
**exec-server** connected to the host over an Erlang port. The jail is the
security boundary.

## Trust model

| Host (trusted) | Jail (untrusted) |
|---|---|
| TUI, clipboard, notifications | Process execution (`bash`, later MCP servers) |
| Provider adapters, `~/.tackle` (credentials, sessions) | Filesystem reads and writes |
| Agent loop, tool logic, output limits | The exec-server itself |

The exec-server must be treated as compromised as soon as the first command
runs. Commands share its uid inside the jail and can, for example, open its
stdout pipe through `/proc/<pid>/fd` and inject frames. **Host security must
not depend on the exec-server's integrity**: the jail limits what can be
reached, and the host validates every byte that comes back.

## Primitive operations, not whole tool calls

The jail executes filesystem and process primitives; tool logic stays on the
host.

- Paths resolve inside the jail's mount namespace, so a symlink to a host file
  outside the mounts resolves to nothing. Host-side path checks are not needed.
- The exec-server stays small and auditable: no harness, provider, or
  third-party code in the jail.
- `Read`, `Edit`, `Write`, and `Bash` keep truncation, image detection, edit
  matching, and the `FileSystem.mutate/2` lock on the host. Plugin tools can use
  the same executor API.

## Transport

- The host opens the jail launcher once per CLI process:
  `Port.open({:spawn_executable, launcher}, [:binary, :stream, :exit_status])`.
  The launcher is a Nix-generated Bubblewrap wrapper (`--die-with-parent`,
  `--clearenv`, PID namespace). Jail policy stays in Nix; the CLI only knows a
  launcher path.
- **The host does not use `{:packet, 4}` for reading.** Port packet framing has
  no maximum size, so a forged length header could force a huge allocation.
  The host reads `:stream` data and frames it itself: a 4-byte big-endian length
  with a hard maximum (2 MiB by default, which also bounds read chunks). A
  larger length is a protocol violation. Decoding can take about 16 times the
  frame size, so this limit stays well below the client's heap limit.
- **The host never blocks on the port.** `Port.command/2` suspends the caller
  while a port is busy, and a suspended process neither drains its mailbox nor
  enforces its heap limit. The client sends with `:nosuspend`, queues what the
  jail does not read (bounded by the 16 MiB write limit), and fails further
  requests with `:busy`.
- The launcher starts with a cleared environment except an allowlist (`PATH`,
  `LANG`, `LC_ALL` by default).
- The jail side may use `{:packet, 4}` on `{:fd, 0, 1}` because the host-to-jail
  direction is trusted. It still decodes with `[:safe]`.
- Standard output is reserved for frames: the exec-server redirects its group
  leader and the default logger handler to standard error. The port inherits
  the host VM's standard error, so the launcher must redirect it away from the
  host terminal.
- A reaper process kills the launcher with `SIGKILL` if the client is killed
  without running `terminate/2`. A normal stop kills the launcher before
  closing the port, so the OS process ID cannot have been reused.

### Host-side decoding

1. Reject compressed external term format (`<<131, 80, ...>>`) to avoid
   decompression bombs.
2. Decode with `:erlang.binary_to_term(frame, [:safe, :used])` and require the
   whole frame to be consumed.
3. Match it against the closed message set below, checking every field of
   messages and results, so funs, PIDs, ports, and references are never
   accepted. Request IDs are host-issued integers; a reply for an unknown or
   finished ID, or of the wrong kind, is a violation.
5. Never `apply`, `send` to, or create atoms from message contents.

Any violation stops the client, kills the jail, and fails in-flight requests
with `:exec_server_down`.

## Protocol version 2

Version 2 added `:input`; version 1 had no way to write to a command's
standard input.

```elixir
# jail -> host, first frame
{:hello, 2}

# host -> jail
{:exec, id, %{argv: [binary], cwd: binary, env: [{binary, binary}], window: pos_integer}}
{:signal, id, :term | :kill}
{:grant, id, pos_integer}
{:input, id, binary}
{:read, id, %{path: binary, offset: non_neg_integer, length: pos_integer}}
{:write, id, %{path: binary, data: binary, mkdir_p: boolean, mode: :replace | :append | :create}}
{:delete, id, %{path: binary}}
{:stat, id, %{path: binary}}
{:list, id, %{path: binary}}

# jail -> host
{:out, id, binary}
{:exit, id, non_neg_integer}
{:ok, id, result}
{:error, id, binary}
```

- Results are `%{data: binary, size: non_neg_integer, eof: boolean}` for
  `:read`, `nil` for `:write`, and `%{type: atom, size: non_neg_integer,
  mode: non_neg_integer}` for `:stat`. Integers are bounded, exit statuses
  are 0..255, error strings are at most 4096 bytes, and read data may not
  exceed the requested length.
- Errors are always binaries on the wire, so a reply never needs an atom that
  is missing on the host. The client maps known POSIX codes back to atoms.
- `:write` with `mode: :replace` rewrites the file in place, like the
  `Write` and `Edit` tools always have, so permissions, hard links, and
  symlinks behave as before. `:append` extends a file, and `:create` makes a
  new owner-only (0600) file and fails with `eexist` if the path exists; the
  `Bash` tool uses both for its full-output spill file.
- `:delete` removes a file, not a directory.
- `:input` writes to a running command's standard input and has no reply.
  The exec-server writes through a process per command, so a command that
  stops reading blocks only that process, and kills a command whose unwritten
  input exceeds 16 MiB (`"input buffer overflow"`). Erlang ports cannot
  half-close a child's standard input, so it is never closed: input suits
  long-lived programs that speak a protocol, such as the project node's
  broker (`docs/PROJECT_NODE_PLAN.md`) or MCP stdio servers, not commands
  that read until end of file. A command that exits while input is being
  written to it loses its exit status (the write fails with EPIPE and the
  port closes) and is reported as `"command stopped reading its input; exit
  status unknown"`.
- **Flow control:** the host cannot throttle a port, so `:out` is credit based.
  Each command starts with a window (256 KiB by default). The caller
  acknowledges consumed bytes, the client grants them back, and output beyond
  the granted credit is a violation. The client also sets `max_heap_size` with
  `kill: true` and `include_shared_binaries: true`, which counts large off-heap
  binaries in its mailbox.
- The exec-server cannot slow a command down: BEAM ports always read their
  child's output. Output the host has not acknowledged is buffered in the jail
  up to 16 MiB; beyond that the command is killed and reported as
  `output buffer overflow`. The `Bash` tool acknowledges output as it captures
  it, so this only triggers when the host falls far behind.
- `exec` returns the caller's monitor of the client as the stream reference,
  so a stream also ends with `:DOWN` if the client dies abruptly.
- **Cancellation:** the runtime already starts each port child in its own
  session and process group, so `:signal` kills the whole group without
  `setsid`. A caller's commands are killed when the caller exits. This also
  fixes the current behaviour where `Port.close/1` does not reliably terminate
  child processes.
- **Full-output spill:** `Bash.Capture` currently spills oversized output to a
  host file and gives the model its path. In jailed mode the spill must be
  written inside the jail through the executor so `read` can find it.

## Components

- Dependency-free package `packages/tackle_exec` (implemented):
  - `Tackle.Exec.Framer`: bounded length-prefixed framing.
  - `Tackle.Exec.Protocol`: encoding, safe decoding, validation.
  - `Tackle.Exec.FileOps` and `Tackle.Exec.Command`: the filesystem and
    process primitives, shared by the server and the local executor so both
    behave identically.
  - `Tackle.Exec.Server`: jail-side loop. Packaging it as a minimal release
    mounted from the read-only `/nix` store is part of phase 3.
  - `Tackle.Exec.Client`: host GenServer that owns the port, routes replies by
    ID, and fails pending requests when the exec-server dies. Restarting with
    backoff is left to the host's supervisor.
- In `packages/tackle` (implemented):
  - `Tackle.Executor` behaviour: `exec/3`, `await/3`, `cancel/2`, `read/4`,
    `write/4`, `delete/2`, and `tmp_dir/1`. An executor is a `{module, config}`
    tuple. A command that cannot start may be reported by `exec/3` or as the
    first `{:error, reason}` event.
  - `Tackle.Executor.Local` (the default) and `Tackle.Executor.Jailed`, which
    takes a `Tackle.Exec.Client` started and supervised by the host.
  - `Read`, `Write`, `Edit`, and `Bash` take `context.executor`. `Read` streams
    64 KiB byte ranges and rejects oversized images from their reported size
    before transferring them. `Bash` creates and appends its spill file through
    the executor, under the executor's `tmp_dir/1`.
  - Cancelling or timing out `bash` kills the command's whole process group
    with either executor, so background children no longer survive.
- One jail per CLI process, shared by subagents (they share the workspace).

## Jail policy

| Resource | Access |
|---|---|
| Workspace | read-write |
| `.git/config`, `.git/config.worktree`, `.git/hooks`, `.git/worktrees` | **read-only** |
| Linked worktree: the main checkout's `.git` | **read-only**, except `objects`, `refs`, `logs/refs`, `rr-cache`, `reftable` |
| Linked worktree: its own Git directory | read-write, except `commondir`, `gitdir`, `config.worktree` |
| `/nix` store | read-only |
| Nix daemon socket | enabled, as today |
| Network | enabled by default, as today |
| Environment | cleared (`--clearenv`); the CLI also passes the launcher only `PATH`, `HOME`, `LANG`, `LC_ALL`, `TERM`, `XDG_CACHE_HOME` |
| Namespaces | all unshared except the network; new session; dies with the CLI |
| `~/.config/ketch/config.json` | read-only when present |
| nix-direnv profile rc files of the project | read-only when cached |
| `~/.tackle`, Wayland, D-Bus, ssh-agent | not mounted |

The launcher creates `.git/hooks`, `.git/worktrees`, and an empty
`.git/config.worktree` on the host before binding them read-only, so the agent
cannot create them inside the jail. Worktrees are created on the host, for
example by Herdr. Read-only `.git/config` blocks
`core.hooksPath`, `core.fsmonitor`, and similar settings that would execute on
the host.

`nix/packages/jail-direnv.nix` adds the devshell inheritance used by
`tackle-cli-jail` (`inheritDirenv = true`). The launcher runs on the host with
the workspace as its working directory, so it finds the cached
`nix print-dev-env` profile nix-direnv keeps for that directory, binds each rc
file read-only, and forwards a `<dir>`/`<rc>` map. The jail sources the
workspace's rc in a `wrap-entry` wrapper before the exec-server starts, and a
`BASH_ENV` hook re-sources the rc matching a command's `$PWD`, which is how a
nested devshell is picked up. Nothing is sourced when no rc is cached, and
`TACKLE_JAIL_PATH`, the jail's `PATH`, is kept after each rc. The rc is host
shell code (the devshell's `shellHook`), already run on the host after
`direnv allow`, and it only names store paths, so the option requires
`enableNix`.

The per-launch image staging directory and `clipboard-paste-jail` bridge are
removed: the host reads the clipboard directly and saves images through the
executor into the jail's `/tmp`, where the `read` tool can open them. A pasted
image file path is copied there the same way.

## Decisions

- `elixir_eval` has been removed completely, together with the `TACKLE_DEV`
  switch that enabled it. It ran code inside the host BEAM and is incompatible
  with an unjailed core.
- Network stays enabled by default, as today.
- `.git/config`, `.git/config.worktree`, `.git/hooks`, and `.git/worktrees`
  are read-only in the jail.

## Residual risks

These risks exist today as well; this architecture does not change them.

- Workspace contents can still execute on the host later: `mix.exs`,
  dependency code, `.envrc`, and similar files run when the user builds or
  enters the project on the host. Submodule configuration under
  `.git/modules` is not covered by the read-only binds.
- The Nix daemon socket allows host builds.
- Command output is untrusted text; terminal escape sequences must be
  sanitized before the TUI renders them.

These are specific to the split:

- MCP servers and plugins configured for Tackle run on the host, unjailed,
  until phase 4.
- The development launcher `jailed-tackle` builds and runs the CLI from the
  checkout on the host. The jail can write the checkout, including `_build`,
  `deps`, and `.nix-mix`, so agent-written code runs unjailed at the next
  start. `tackle-cli-jail` runs an immutable store binary instead.
- A planted symlink is resolved by the jail, but the host still reads files
  outside the executor's workspace directly; jailed code cannot write there.
  Project file reads are capped at 1 MiB and directory walks at 256
  directories, so a hostile jail cannot exhaust host memory through them.
- Host Git in a jailed workspace: `.git` is bound onto itself; `config`,
  `config.worktree`, `hooks`, and `worktrees/` are read-only; a `.git` file is
  read-only; and a planted `.git/commondir` blocks the launch. In a linked
  worktree, after the launcher has checked that its `.git` file and Git
  directory point at each other, the main checkout's `.git` is read-only
  except the object store, refs, and branch reflogs, and the worktree's own
  Git directory is writable except its pointers and `config.worktree`
  (`nix/packages/jail-git.sh`). Those writable directories are bound through
  file descriptors checked to be the directories the launcher inspected,
  because a running jail of the main checkout can rename them. Deleting or
  renaming refs, writing configuration, and `git gc` therefore fail in a
  linked worktree's jail. Git follows a `commondir` file planted in a
  writable Git directory; the next launch refuses it, but host Git outside
  Tackle follows it until it is removed. Planted rebase or cherry-pick state
  runs its `exec` lines when the user continues it on the host. Writable
  objects and refs allow object alternates and symbolic refs that host Git
  follows. Repositories created in the jail, submodules under the workspace's
  own Git directory (`.git/modules`, or `modules` in a worktree's), and
  nested `.git` directories remain writable. A linked worktree's jail can
  move any branch, and with the reftable backend the main checkout's `HEAD`;
  it can read the whole main `.git`, including its configuration.
- The shared network namespace exposes localhost services and abstract Unix
  sockets (for example X11) to the jail.
- With the Nix daemon enabled, a user in `trusted-users` effectively hands the
  jail root access.
- The jail can read, truncate, or grow the shared exec-server log, and read
  Ketch's configuration, including any API keys.
- The launcher's own setup (before standard error is redirected) can print
  Bubblewrap or jail.nix errors to the terminal.

## Tests

- Protocol: oversized frames, compressed terms, funs and PIDs, unknown IDs,
  credit overruns, unexpected exits.
- A shared contract suite run against `Local` and `Jailed`; `Jailed` tests run
  the exec-server as a plain port without Bubblewrap.
- Nix smoke test against the real jail: `~/.tackle` hidden, symlink escape
  fails, `.git/config` and `.git/hooks` read-only, cancellation kills
  descendants, the jail dies with the host.

## Phases

1. **Done:** `packages/tackle_exec`: protocol, server, and client, tested
   without Bubblewrap, including a hostile fake server.
2. **Done:** `Tackle.Executor` with `Local` and `Jailed`, and `Bash`, `Read`,
   `Write`, and `Edit` moved onto it. The tool tests run against both
   executors.
3. **Done:** Nix exec-jail launcher and CLI integration; the clipboard bridge
   is removed and the CLI runs on the host:
   - `nix/packages/exec-jail.nix` builds the launcher around
     `nix/packages/exec-server.nix` (Erlang, Elixir's standard library, and
     `tackle_exec` only). `tackle-cli-jail` and `jailed-tackle` set
     `TACKLE_EXEC_LAUNCHER` and run the CLI on the host.
   - `tackle-cli-jail` builds its launcher with `inheritDirenv = true`, so the
     jail reproduces the project's cached nix-direnv devshell
     (`nix/packages/jail-direnv.nix`); see the jail policy above.
   - Instead of a `--jail` flag, the CLI enables jailed mode from
     `TACKLE_EXEC_LAUNCHER` (`Tackle.CLI.Jail`). It starts the client lazily
     on the first session, under the CLI supervisor, fails closed when the
     jail does not answer or can see `$TACKLE_HOME`, and refuses, by resolved
     path, workspaces that contain the home directory, `$TACKLE_HOME` or any
     of its entries, or an enabled plugin project, and workspaces inside
     `$TACKLE_HOME`. `TACKLE_EXEC_WORKSPACE` selects a mount root that
     contains the working directory, which the development launcher uses for
     the repository root.
   - The executor travels in the loader overrides, so the root agent and
     every subagent profile get it. `Tackle.Config` rejects a malformed
     executor instead of falling back to the local one. `tackle sdk` uses it
     too.
   - `AGENTS.md`, `.agents/skills`, and project agent definitions inside the
     executor's workspace (`c:Tackle.Executor.workspace/1`) are read through
     the executor (`Tackle.ProjectFiles`). The protocol gained a `:list`
     operation for this; listed names must be single path components.
4. Later: route MCP stdio servers through `exec`, and an optional network-off
   profile.
