# Tackle.Exec

`Tackle.Exec` connects a trusted host to an **exec-server** that runs inside a
jail. The host keeps the agent loop, credentials, and tool logic. The jail
runs the primitives that touch the workspace or spawn processes: commands,
file reads, file writes, and stat calls.

This package is phase 1 of the [exec-server plan](../../docs/EXEC_SERVER_PLAN.md):
the protocol, the jail-side server, and the host-side client. It has no
dependencies. Built-in tools do not use it yet, and there is no jail launcher
or CLI option yet.

## Trust model

The host trusts nothing it receives from the jail. Jailed commands run under
the same uid as the exec-server and may forge frames on its standard output,
so `Tackle.Exec.Client` treats the server as hostile:

- It frames the port stream itself and rejects frames above `:max_frame`
  (2 MiB by default) before buffering them. Port `{:packet, 4}` framing has no
  size limit. A term can need about 16 times its encoded size once decoded, so
  the limit is kept well below the client's heap limit.
- It decodes with `:erlang.binary_to_term(frame, [:safe, :used])`, rejects
  compressed terms and trailing bytes, and accepts only the closed message and
  result shapes in `Tackle.Exec.Protocol`, with bounded integers and error
  strings. Funs, PIDs, ports, and references are never accepted, and a read
  never returns more data than requested.
- Command output is credit based. Output beyond the granted window is a
  violation.
- It never blocks on the port. A jail that stops reading its input cannot
  suspend the client; unsent requests queue up to `:max_write` bytes, after
  which requests fail with `:busy`. Pending requests are limited by
  `:max_requests`.
- The client process has a heap limit that includes off-heap binaries in its
  mailbox (`:max_heap_bytes`, 256 MiB by default). This requires OTP 27 or
  later.
- The launcher gets a cleared environment that keeps only `:keep_env`
  (`PATH`, `LANG`, and `LC_ALL` by default), so host secrets do not reach it.
- Any violation stops the client, fails pending requests with
  `:exec_server_down`, and kills the launcher.

When the client stops, it kills the launcher with `SIGKILL` before closing the
port. A reaper process does the same if the client is killed without running
`terminate/2`.

## Launcher requirements

A launcher is any `{executable, args}` that ends up running
`Tackle.Exec.Server.main/0` with standard input and output connected to the
client, for example:

```sh
erl -noshell -noinput -pa <elixir ebin> -pa <tackle_exec ebin> \
  -s Elixir.Tackle.Exec.Server main
```

A production launcher must also:

- redirect standard error away from the host terminal, so jailed code cannot
  write escape sequences to it;
- tear down the whole jail when its own process is killed, for example with
  Bubblewrap's `--die-with-parent` and a PID namespace. Without a PID
  namespace, commands can outlive the exec-server.

## Usage

```elixir
{:ok, client} = Tackle.Exec.Client.start_link(launcher: {launcher, args})

{:ok, ref} = Tackle.Exec.Client.exec(client, ["bash", "-c", "mix test"], cwd: "/work")

receive do
  {:tackle_exec, ^ref, {:data, data}} ->
    # Consume the data, then acknowledge it to receive more.
    Tackle.Exec.Client.ack(client, ref, byte_size(data))

  {:tackle_exec, ^ref, {:exit_status, status}} ->
    Process.demonitor(ref, [:flush])
    status

  {:tackle_exec, ^ref, {:error, reason}} ->
    Process.demonitor(ref, [:flush])
    reason

  {:DOWN, ^ref, :process, _client, reason} ->
    # The client exited abruptly.
    reason
end

{:ok, %{data: data, size: size, eof: eof}} = Tackle.Exec.Client.read(client, "/work/a.txt", 0, 65_536)
:ok = Tackle.Exec.Client.write(client, "/work/new/b.txt", "hello", mkdir_p: true)
{:ok, %{type: :regular, size: 5, mode: mode}} = Tackle.Exec.Client.stat(client, "/work/new/b.txt")
```

The returned reference is also a monitor of the client, so the stream always
ends: with `:exit_status`, with `:error`, or with `:DOWN` if the client dies.
`Tackle.Exec.Client.signal/3` sends `SIGTERM` or `SIGKILL` to a command's
process group. If the calling process exits, its commands are killed. The
exec-server cannot slow a command down, so a command with more than 16 MiB of
unacknowledged output is killed and ends with
`{:error, "output buffer overflow"}`. Errors with a known POSIX code are
returned as atoms such as `:enoent`; other errors are strings.

## Development

```sh
mix deps.get
mix compile --warnings-as-errors
mix test
mix format --check-formatted 'mix.exs' 'lib/**/*.{ex,exs}' 'test/**/*.{ex,exs}'
```

The tests run the real exec-server in a plain `erl` without a jail, and a fake
server that sends hostile frames. They need `erl`, `sh`, and `kill` on `PATH`
and Linux `/proc`.
