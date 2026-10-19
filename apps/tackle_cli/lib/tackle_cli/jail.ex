defmodule Tackle.CLI.Jail do
  @moduledoc """
  Runs the agent's tool primitives in a jail when `TACKLE_EXEC_LAUNCHER` names
  a launcher.

  The CLI itself stays on the host, so it keeps access to credentials, the
  session store, and host facilities such as the clipboard. Commands and
  workspace file access go through a `Tackle.Exec.Client` connected to a jailed
  `Tackle.Exec.Server`.

  The launcher is started once per CLI process with the workspace as its
  working directory and the path of a log file for the exec-server's
  standard error as its only argument. It must start the exec-server inside a
  jail that mounts that directory at the same path, such as the
  `tackle-exec-jail` launcher built by the repository's Nix packages. The
  workspace is the current directory, or `TACKLE_EXEC_WORKSPACE` when set; it
  must contain the current directory.

  Jailed mode fails closed: when the launcher is configured but the jail does
  not answer, sessions do not start, and tools never fall back to running on
  the host.

  The jail starts with an empty environment. The user's `config.json` (never
  a project's `.tackle/config.json`) can name host environment variables to
  pass into it, such as a token for the `gh` CLI:

      {"jail": {"env": ["GH_TOKEN"]}}

  Each named variable that is set in the CLI's environment when the jail
  starts is added to the environment of every command run in the jail
  (`Tackle.Executor.Jailed`); the launcher never sees it. Anything in the jail
  can read these values.
  """

  alias Tackle.Config.File, as: ConfigFile
  alias Tackle.Exec.Client
  alias Tackle.Executor.Jailed

  @env "TACKLE_EXEC_LAUNCHER"
  @workspace_env "TACKLE_EXEC_WORKSPACE"
  @client Tackle.CLI.Jail.Client
  @supervisor Tackle.CLI.Jail.Supervisor
  # HOME is needed by the launcher to set up the jail's private home; nothing
  # else from the host environment reaches it. XDG_CACHE_HOME names the direnv
  # cache the launcher reads to reproduce the project's devshell inside the
  # jail; the launcher's environment is not the jail's, which starts cleared.
  @keep_env ~w(PATH HOME LANG LC_ALL TERM XDG_CACHE_HOME)
  @ready_timeout 30_000

  @doc """
  Starts the jail if `TACKLE_EXEC_LAUNCHER` is set, or checks that it is still
  running.

  Returns the executor to put in the tool context, or `nil` when jailed mode
  is off.

  Options: `:env` (default: the process environment), `:cwd` (default: the
  current directory), the agent's working directory, and `:verify_isolation`
  (default `true`), which requires that the jail cannot see `$TACKLE_HOME`.
  Tests that run the exec-server without a jail turn it off.
  """
  @spec ensure_started(keyword()) :: {:ok, Tackle.Executor.t() | nil} | {:error, term()}
  def ensure_started(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    case Map.get(env, @env) do
      launcher when is_binary(launcher) and launcher != "" ->
        start(launcher, Keyword.get_lazy(opts, :cwd, &File.cwd!/0), env, opts)

      _unset ->
        {:ok, nil}
    end
  end

  @doc "Formats a jail startup error for the terminal, or returns `nil` for other errors."
  @spec format_error(term()) :: String.t() | nil
  def format_error({:jail_failed, reason, log}),
    do: "the jail did not start (#{Tackle.Executor.format_reason(reason)}); see #{log}"

  def format_error({:unsafe_jail_workspace, cwd, path}),
    do:
      "refusing to start a jail in #{cwd}: it would expose #{path}. " <>
        "Start Tackle from a project directory."

  def format_error({:cwd_outside_jail_workspace, cwd, workspace}),
    do: "the working directory #{cwd} is outside the jail workspace #{workspace}"

  def format_error({:jail_log_unavailable, dir, reason}),
    do: "cannot create the jail log directory #{dir}: #{Tackle.Executor.format_reason(reason)}"

  def format_error(_reason), do: nil

  @doc "Returns the jailed executor once the jail was started, otherwise `nil`."
  @spec executor() :: Tackle.Executor.t() | nil
  def executor, do: Application.get_env(:tackle_cli, :jail_executor)

  defp start(launcher, cwd, env, opts) do
    # The launcher mounts the physical directory, so compare and route by
    # resolved paths only.
    cwd = cwd |> Path.expand() |> realpath()

    workspace =
      case Map.get(env, @workspace_env) do
        path when is_binary(path) and path != "" -> path |> Path.expand(cwd) |> realpath()
        _unset -> cwd
      end

    with :ok <- check_contains(workspace, cwd),
         {:ok, tackle_home} <- Tackle.Paths.home(env: env),
         :ok <- check_workspace(workspace, tackle_home, env),
         {:ok, forwarded_env} <- forwarded_env(tackle_home, env),
         {:ok, log} <- log_path(tackle_home),
         :ok <- start_client(launcher, log, workspace),
         :ok <- ready_or_stop(cwd, tackle_home, log, Keyword.get(opts, :verify_isolation, true)) do
      executor = Jailed.new(@client, workspace: workspace, env: forwarded_env)
      Application.put_env(:tackle_cli, :jail_executor, executor)
      {:ok, executor}
    end
  end

  # Never leave an exec-server running that failed the checks.
  defp ready_or_stop(cwd, tackle_home, log, verify_isolation) do
    with {:error, _reason} = error <- await_ready(cwd, tackle_home, log, verify_isolation) do
      _ = Supervisor.terminate_child(Tackle.CLI.Supervisor, @supervisor)
      error
    end
  end

  # The agent's tools run in its working directory, so the jail must mount it.
  defp check_contains(workspace, cwd) do
    if contains?(workspace, cwd),
      do: :ok,
      else: {:error, {:cwd_outside_jail_workspace, cwd, workspace}}
  end

  # The jail must not see the user's home, Tackle's state (credentials, MCP and
  # plugin configuration), or plugin code the host loads. Each is compared by
  # resolved path, so symlinks into the workspace are caught too.
  defp check_workspace(workspace, tackle_home, env) do
    real_tackle_home = realpath(tackle_home)

    protected =
      [real_tackle_home | tackle_home_entries(tackle_home)] ++
        user_home(env) ++ plugin_roots(env)

    cond do
      contains?(real_tackle_home, workspace) ->
        {:error, {:unsafe_jail_workspace, workspace, tackle_home}}

      path = Enum.find(protected, &contains?(workspace, &1)) ->
        {:error, {:unsafe_jail_workspace, workspace, path}}

      true ->
        :ok
    end
  end

  defp tackle_home_entries(tackle_home) do
    case File.ls(tackle_home) do
      {:ok, names} -> Enum.map(names, &realpath(Path.join(tackle_home, &1)))
      {:error, _reason} -> []
    end
  end

  defp user_home(env) do
    case Map.get(env, "HOME") do
      home when is_binary(home) and home != "" -> [home |> Path.expand() |> realpath()]
      _unset -> []
    end
  end

  defp plugin_roots(env) do
    case Tackle.Plugins.Loader.project_paths(env: env) do
      {:ok, paths} -> Enum.map(paths, &realpath/1)
      {:error, _reason} -> []
    end
  end

  defp contains?(dir, path),
    do: path == dir or String.starts_with?(path, String.trim_trailing(dir, "/") <> "/")

  # Resolves every symlink in an absolute path. Components that do not exist
  # are kept as they are.
  defp realpath(path), do: resolve(Path.split(path), "/", 0)

  defp resolve(_parts, _acc, 40), do: raise(ArgumentError, "too many symbolic links")
  defp resolve([], acc, _links), do: acc
  defp resolve(["/" | rest], _acc, links), do: resolve(rest, "/", links)

  defp resolve([part | rest], acc, links) do
    candidate = Path.join(acc, part)

    case File.read_link(candidate) do
      {:ok, target} -> resolve(Path.split(Path.expand(target, acc)) ++ rest, "/", links + 1)
      {:error, _reason} -> resolve(rest, candidate, links)
    end
  end

  # The variables the user's config.json passes into the jail, with their
  # values from the CLI's environment; unset ones are skipped, so a variable
  # that only a project's direnv sets reaches only that project's jail.
  defp forwarded_env(tackle_home, env) do
    with {:ok, names} <- ConfigFile.jail_env(Path.join(tackle_home, "config.json")) do
      {:ok,
       for name <- Enum.uniq(names), value = Map.get(env, name), is_binary(value) do
         {name, value}
       end}
    end
  end

  defp log_path(tackle_home) do
    dir = Path.join(tackle_home, "logs")

    case File.mkdir_p(dir) do
      :ok -> {:ok, Path.join(dir, "exec-server.log")}
      {:error, reason} -> {:error, {:jail_log_unavailable, dir, reason}}
    end
  end

  defp start_client(launcher, log, cwd) do
    if Process.whereis(@supervisor) do
      :ok
    else
      client =
        {Client, name: @client, launcher: {launcher, [log]}, cd: cwd, keep_env: @keep_env}

      # Restart the exec-server after a crash, but give up rather than
      # respawning a broken jail forever. The CLI keeps running; tools then
      # report that the execution environment is unavailable.
      spec = %{
        id: @supervisor,
        type: :supervisor,
        restart: :temporary,
        start:
          {Supervisor, :start_link,
           [
             [client],
             [strategy: :one_for_one, max_restarts: 3, max_seconds: 30, name: @supervisor]
           ]}
      }

      case Supervisor.start_child(Tackle.CLI.Supervisor, spec) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, {:jail_failed, reason, log}}
      end
    end
  end

  # The workspace must be visible and the Tackle home must not be, so a
  # launcher that does not actually isolate fails closed.
  defp await_ready(cwd, tackle_home, log, verify_isolation) do
    with :ok <- workspace_visible(cwd, log) do
      if verify_isolation, do: tackle_home_hidden(tackle_home, log), else: :ok
    end
  end

  defp workspace_visible(cwd, log) do
    case Client.stat(@client, cwd, @ready_timeout) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, _other} ->
        {:error, {:jail_failed, "the workspace is not a directory in the jail", log}}

      {:error, reason} ->
        {:error, {:jail_failed, reason, log}}
    end
  end

  defp tackle_home_hidden(tackle_home, log) do
    case Client.stat(@client, tackle_home, @ready_timeout) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, {:jail_failed, "the jail can see #{tackle_home}", log}}
      {:error, reason} -> {:error, {:jail_failed, reason, log}}
    end
  end
end
