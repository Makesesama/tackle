defmodule Tackle.CLI.JailTest do
  # The jail is a named, application-wide resource.
  use ExUnit.Case, async: false

  alias Tackle.CLI.Jail
  alias Tackle.Executor

  setup do
    root = Path.join(System.tmp_dir!(), "tackle-cli-jail-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "project")
    home = Path.join(root, "home")
    File.mkdir_p!(workspace)
    File.mkdir_p!(home)

    on_exit(fn ->
      _ = Supervisor.terminate_child(Tackle.CLI.Supervisor, Tackle.CLI.Jail.Supervisor)
      Application.delete_env(:tackle_cli, :jail_executor)
      File.rm_rf!(root)
    end)

    env = %{"HOME" => home, "TACKLE_HOME" => Path.join(home, ".tackle")}
    %{root: root, workspace: workspace, home: home, env: env}
  end

  test "is off without a launcher", %{workspace: workspace, env: env} do
    assert {:ok, nil} = Jail.ensure_started(env: env, cwd: workspace)
    assert Jail.executor() == nil
  end

  test "starts the exec-server in the workspace and routes through it", %{
    root: root,
    workspace: workspace,
    env: env
  } do
    env = Map.put(env, "TACKLE_EXEC_LAUNCHER", launcher(root))

    assert {:ok, executor} =
             Jail.ensure_started(env: env, cwd: workspace, verify_isolation: false)

    assert Jail.executor() == executor

    assert {:ok, ^executor} =
             Jail.ensure_started(env: env, cwd: workspace, verify_isolation: false)

    assert {:ok, %{type: :directory}} = Executor.stat(executor, workspace)
    assert Executor.workspace(executor) == workspace
    os_pid = :sys.get_state(Tackle.CLI.Jail.Client).os_pid
    assert File.read_link!("/proc/#{os_pid}/cwd") == workspace

    # The launcher received the log path as its argument.
    assert File.exists?(Path.join(env["TACKLE_HOME"], "logs/exec-server.log"))
  end

  test "passes the launcher the environment it needs and nothing else", %{
    root: root,
    workspace: workspace,
    env: env
  } do
    dump = Path.join(root, "launcher-env")

    with_env(%{"XDG_CACHE_HOME" => Path.join(root, "cache"), "TACKLE_TEST_SECRET" => "x"})

    env = Map.put(env, "TACKLE_EXEC_LAUNCHER", launcher(root, dump_env: dump))

    assert {:ok, _executor} =
             Jail.ensure_started(env: env, cwd: workspace, verify_isolation: false)

    # The launcher locates the project's direnv cache with XDG_CACHE_HOME; the
    # rest of the host environment stays out.
    vars = launcher_env(dump)
    assert Map.fetch!(vars, "XDG_CACHE_HOME") == Path.join(root, "cache")
    refute Map.has_key?(vars, "TACKLE_TEST_SECRET")
    refute Map.has_key?(vars, "TACKLE_HOME")
  end

  test "passes the variables named in config.json to commands, not to the launcher", %{
    root: root,
    workspace: workspace,
    env: env
  } do
    dump = Path.join(root, "launcher-env")
    # Set for the CLI process too, so the launcher could have inherited it.
    with_env(%{"GH_TOKEN" => "gh-secret"})
    File.mkdir_p!(env["TACKLE_HOME"])

    File.write!(
      Path.join(env["TACKLE_HOME"], "config.json"),
      ~s({"jail": {"env": ["GH_TOKEN", "TACKLE_UNSET"]}})
    )

    env =
      Map.merge(env, %{
        "TACKLE_EXEC_LAUNCHER" => launcher(root, dump_env: dump),
        "GH_TOKEN" => "gh-secret",
        "TACKLE_TEST_SECRET" => "x"
      })

    assert {:ok, executor} =
             Jail.ensure_started(env: env, cwd: workspace, verify_isolation: false)

    refute inspect(executor) =~ "gh-secret"
    refute Map.has_key?(launcher_env(dump), "GH_TOKEN")

    script =
      ~s(printf '%s|%s|%s' "$GH_TOKEN" "${TACKLE_UNSET-unset}" "${TACKLE_TEST_SECRET-unset}")

    {:ok, handle} = Executor.exec(executor, ["sh", "-c", script], cwd: workspace)
    assert collect(executor, handle, "") == "gh-secret|unset|unset"
  end

  test "does not start with an invalid jail setting", %{
    root: root,
    workspace: workspace,
    env: env
  } do
    File.mkdir_p!(env["TACKLE_HOME"])
    path = Path.join(env["TACKLE_HOME"], "config.json")
    File.write!(path, ~s({"jail": {"env": ["GH-TOKEN"]}}))
    env = Map.put(env, "TACKLE_EXEC_LAUNCHER", launcher(root))

    assert {:error, {:invalid_config_field, ^path, "jail"}} =
             Jail.ensure_started(env: env, cwd: workspace, verify_isolation: false)

    refute Process.whereis(Tackle.CLI.Jail.Supervisor)
  end

  test "mounts TACKLE_EXEC_WORKSPACE when it contains the working directory", %{
    root: root,
    workspace: workspace,
    env: env
  } do
    cwd = Path.join(workspace, "apps/cli")
    File.mkdir_p!(cwd)

    env =
      Map.merge(env, %{
        "TACKLE_EXEC_LAUNCHER" => launcher(root),
        "TACKLE_EXEC_WORKSPACE" => workspace
      })

    assert {:ok, executor} = Jail.ensure_started(env: env, cwd: cwd, verify_isolation: false)
    assert Executor.workspace(executor) == workspace
    os_pid = :sys.get_state(Tackle.CLI.Jail.Client).os_pid
    assert File.read_link!("/proc/#{os_pid}/cwd") == workspace
  end

  test "rejects a working directory outside TACKLE_EXEC_WORKSPACE", %{
    root: root,
    workspace: workspace,
    env: env
  } do
    other = Path.join(root, "other")
    File.mkdir_p!(other)

    env =
      Map.merge(env, %{
        "TACKLE_EXEC_LAUNCHER" => launcher(root),
        "TACKLE_EXEC_WORKSPACE" => workspace
      })

    assert {:error, {:cwd_outside_jail_workspace, ^other, ^workspace} = error} =
             Jail.ensure_started(env: env, cwd: other)

    assert Jail.format_error(error) =~ "outside the jail workspace"
  end

  test "fails closed when the jail does not start", %{root: root, workspace: workspace, env: env} do
    broken = Path.join(root, "broken-launcher")
    File.write!(broken, "#!/bin/sh\necho 'bwrap: no permission' >&2\nexit 1\n")
    File.chmod!(broken, 0o755)
    env = Map.put(env, "TACKLE_EXEC_LAUNCHER", broken)

    assert {:error, {:jail_failed, _reason, log} = error} =
             Jail.ensure_started(env: env, cwd: workspace)

    assert log == Path.join(env["TACKLE_HOME"], "logs/exec-server.log")
    assert Jail.format_error(error) =~ "the jail did not start"
    assert Jail.executor() == nil
  end

  test "fails closed when the launcher does not hide the Tackle home", %{
    root: root,
    workspace: workspace,
    env: env
  } do
    # The test launcher runs without a jail, so it can see everything.
    env = Map.put(env, "TACKLE_EXEC_LAUNCHER", launcher(root))

    assert {:error, {:jail_failed, reason, _log} = error} =
             Jail.ensure_started(env: env, cwd: workspace)

    assert reason == "the jail can see #{env["TACKLE_HOME"]}"
    assert Jail.format_error(error) =~ "the jail can see"
    assert Jail.executor() == nil
    refute Process.whereis(Tackle.CLI.Jail.Supervisor)
  end

  test "resolves a relative TACKLE_EXEC_WORKSPACE against the working directory", %{
    root: root,
    workspace: workspace,
    env: env
  } do
    cwd = Path.join(workspace, "apps/cli")
    File.mkdir_p!(cwd)

    env =
      Map.merge(env, %{
        "TACKLE_EXEC_LAUNCHER" => launcher(root),
        "TACKLE_EXEC_WORKSPACE" => "../.."
      })

    assert {:ok, executor} = Jail.ensure_started(env: env, cwd: cwd, verify_isolation: false)
    assert Executor.workspace(executor) == workspace
  end

  describe "refuses workspaces that would expose private files by resolved path" do
    setup %{root: root, env: env} do
      %{env: Map.put(env, "TACKLE_EXEC_LAUNCHER", launcher(root))}
    end

    test "a Tackle home that is a symlink into the workspace", %{root: root, workspace: workspace} do
      real = Path.join(workspace, "dotfiles/tackle")
      File.mkdir_p!(real)
      link = Path.join(root, "linked-tackle")
      File.ln_s!(real, link)

      env = %{
        "HOME" => Path.join(root, "home"),
        "TACKLE_EXEC_LAUNCHER" => launcher(root),
        "TACKLE_HOME" => link
      }

      assert {:error, {:unsafe_jail_workspace, ^workspace, ^real}} =
               Jail.ensure_started(env: env, cwd: workspace)
    end

    test "a file in the Tackle home that is a symlink into the workspace", %{
      workspace: workspace,
      env: env
    } do
      File.mkdir_p!(env["TACKLE_HOME"])
      target = Path.join(workspace, "dotfiles/mcp.json")
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, "{}")
      File.ln_s!(target, Path.join(env["TACKLE_HOME"], "mcp.json"))

      assert {:error, {:unsafe_jail_workspace, ^workspace, ^target}} =
               Jail.ensure_started(env: env, cwd: workspace)
    end

    test "a workspace inside the Tackle home", %{env: env} do
      inside = Path.join(env["TACKLE_HOME"], "plugins/demo")
      File.mkdir_p!(inside)

      assert {:error, {:unsafe_jail_workspace, ^inside, _path}} =
               Jail.ensure_started(env: env, cwd: inside)
    end

    test "a home reached through a symlink", %{root: root, home: home, env: env} do
      link = Path.join(root, "home-link")
      File.ln_s!(home, link)

      assert {:error, {:unsafe_jail_workspace, ^home, ^home}} =
               Jail.ensure_started(
                 env: %{env | "HOME" => link, "TACKLE_HOME" => Path.join(root, "state/.tackle")},
                 cwd: home
               )
    end

    test "a plugin project inside the workspace", %{workspace: workspace, env: env} do
      plugin = Path.join(workspace, "my-plugin")
      File.mkdir_p!(plugin)
      File.mkdir_p!(env["TACKLE_HOME"])

      File.write!(
        Path.join(env["TACKLE_HOME"], "plugins.json"),
        JSON.encode!(%{
          "version" => 1,
          "projects" => [
            %{"path" => plugin, "app" => "demo", "adapters" => [], "tools" => [], "hooks" => []}
          ]
        })
      )

      assert {:error, {:unsafe_jail_workspace, ^workspace, ^plugin}} =
               Jail.ensure_started(env: env, cwd: workspace)
    end
  end

  test "refuses workspaces that would expose the Tackle or user home", %{
    root: root,
    home: home,
    env: env
  } do
    env = Map.put(env, "TACKLE_EXEC_LAUNCHER", launcher(root))

    for cwd <- [home, root, "/"] do
      assert {:error, {:unsafe_jail_workspace, ^cwd, _path} = error} =
               Jail.ensure_started(env: env, cwd: cwd)

      assert Jail.format_error(error) =~ "refusing to start a jail in #{cwd}"
    end

    refute Process.whereis(Tackle.CLI.Jail.Supervisor)
  end

  test "formats only its own errors" do
    assert Jail.format_error(:something_else) == nil
  end

  # Runs the real exec-server without Bubblewrap, honouring the launcher
  # contract: the first argument is the log for standard error. With
  # `:dump_env`, the launcher records the environment the CLI passed it.
  defp launcher(root, opts \\ []) do
    erl = System.find_executable("erl") || raise "erl was not found on PATH"
    elixir_ebin = Path.join(:code.lib_dir(:elixir), "ebin")
    exec_ebin = Path.join(:code.lib_dir(:tackle_exec), "ebin")
    path = Path.join(root, "launcher")

    dump =
      case Keyword.get(opts, :dump_env) do
        nil -> ""
        file -> "env > #{file}\n"
      end

    File.write!(path, """
    #!/bin/sh
    exec 2>>"$1"
    #{dump}exec "#{erl}" -noshell -noinput -pa "#{elixir_ebin}" -pa "#{exec_ebin}" \\
      -s Elixir.Tackle.Exec.Server main
    """)

    File.chmod!(path, 0o755)
    path
  end

  # Sets host environment variables for one test and restores them after it.
  defp with_env(vars) do
    previous = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    Enum.each(vars, fn {name, value} -> System.put_env(name, value) end)
  end

  defp collect(executor, handle, output) do
    case Executor.await(executor, handle, 5_000) do
      {:data, data} -> collect(executor, handle, output <> data)
      {:exit_status, 0} -> output
    end
  end

  defp launcher_env(dump) do
    dump
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [name, value] = String.split(line, "=", parts: 2)
      {name, value}
    end)
  end
end
