# tackle_tools

The coding tools `read`, `bash`, `edit`, and `write` (`Tackle.Tools.Read`,
`Bash`, `Edit`, `Write`) as `Tackle.Lib.Tool` modules, and the executors they
run on (`Tackle.Executor`). It depends only on
[`tackle_lib`](../tackle_lib/README.md) and
[`tackle_exec`](../tackle_exec/README.md), so any host can give its agents
these tools: the harness (`packages/tackle`) uses them as its default tools.

The tools keep their logic in the host process and send filesystem and
process primitives to the executor in the tool context (`context.executor`),
relative to `context.cwd`:

- `Tackle.Executor.Local` (the default) runs them with the host process's own
  permissions, without a sandbox;
- `Tackle.Executor.Jailed` sends them to a jailed `Tackle.Exec.Server` through
  a `Tackle.Exec.Client`; the launcher must mount the workspace at the same
  path as on the host.

```elixir
{:ok, client} = Tackle.Exec.Client.start_link(launcher: launcher)
executor = Tackle.Executor.Jailed.new(client, workspace: workspace)
context = %{cwd: workspace, executor: executor}
```

`bash` output beyond its limits is kept in a private, randomly named file
under the executor's temporary directory, and cancelling or timing out a
command kills its whole process group.

## Development

```sh
mix deps.get
mix compile --warnings-as-errors && mix test
mix format --check-formatted
mix credo --strict   # also run by the repository's pre-commit hook
```

The tests run every tool against both executors; the jailed one starts the
real exec-server in a plain `erl`, without a jail. `tackle_lib`'s rebar3
dependencies need the dev shell's `rebar3` (`MIX_REBAR3`).
