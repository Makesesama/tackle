defmodule Tackle.CLI.StandaloneTest do
  use ExUnit.Case, async: false

  alias Tackle.CLI.Standalone

  test "does not run the CLI outside a Burrito binary" do
    Process.flag(:trap_exit, true)
    previous = System.get_env("__BURRITO")
    System.delete_env("__BURRITO")

    on_exit(fn ->
      if previous, do: System.put_env("__BURRITO", previous), else: System.delete_env("__BURRITO")
    end)

    assert {:ok, pid} = Standalone.start_link(:ignored)
    assert_receive {:EXIT, ^pid, :normal}, 100
  end

  @moduletag timeout: 15_000

  setup_all do
    dir = Path.join(System.tmp_dir!(), "tackle-boot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # Reproduce Burrito's boot ordering in a separate VM: start applications,
    # then invoke Elixir's CLI with the same plain arguments. The probe app's
    # stop callback also verifies that we exit gracefully, rather than halt.
    [{module, beam}] =
      Code.compile_string("""
      defmodule Tackle.CLI.StandaloneBootProbe do
        use Application

        def start do
          :ok = :application.load({:application, :standalone_boot_probe, [
            vsn: ~c"1",
            modules: [__MODULE__],
            applications: [:kernel, :stdlib, :elixir],
            mod: {__MODULE__, []}
          ]})
          {:ok, _} = Application.ensure_all_started(:standalone_boot_probe)
          {:ok, _} = Application.ensure_all_started(:tackle_cli)
          true = Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :tackle_cli end)
          children = Supervisor.which_children(Tackle.CLI.Supervisor)
          {id, pid, _, _} = List.keyfind(children, Tackle.CLI.MCP.Connections, 0)
          Process.exit(pid, :kill)
          await_restart(id, pid)
        end

        defp await_restart(id, old_pid) do
          case List.keyfind(Supervisor.which_children(Tackle.CLI.Supervisor), id, 0) do
            {^id, pid, _, _} when is_pid(pid) and pid != old_pid -> :ok
            _ ->
              Process.sleep(10)
              await_restart(id, old_pid)
          end
        end

        def start(_type, _args), do: Agent.start_link(fn -> nil end)
        def stop(_state), do: File.write!(System.fetch_env!("BOOT_STOP_FILE"), "stopped")
      end
      """)

    File.write!(Path.join(dir, "#{module}.beam"), beam)

    release_dir = Path.join(dir, "releases/0.1.0")
    File.mkdir_p!(release_dir)
    path = Path.join(release_dir, "start")
    clean_boot = Path.join([to_string(:code.root_dir()), "bin", "start_clean.boot"])
    {:script, id, instructions} = :erlang.binary_to_term(File.read!(clean_boot))
    {startup, [started]} = Enum.split(instructions, -1)
    script = {:script, id, startup ++ [{:apply, {module, :start, []}}, started]}
    File.write!(path <> ".script", :io_lib.format(~c"~tp.~n", [script]))
    Tackle.CLI.Release.standalone_boot(%Mix.Release{path: dir, version: "0.1.0"})
    {:ok, dir: dir, boot_path: path}
  end

  for {argv, expected, status} <- [
        {["--version"], "Tackle developer harness 0.1.0", 0},
        {["--help"], "Tackle developer harness", 0},
        {["models"], "codex/", 0},
        {["--not-a-tackle-option"], "unrecognized arguments", 1}
      ] do
    @argv argv
    @expected expected
    @status status
    test "standalone boot handles #{Enum.join(argv, " ")} and stops applications", %{
      dir: dir,
      boot_path: boot_path
    } do
      home = Path.join(dir, "home-#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      stop_file = Path.join(home, "stopped")
      erl = Path.join([to_string(:code.root_dir()), "bin", "erl"])
      paths = Enum.flat_map([to_charlist(dir) | :code.get_path()], &["-pa", to_string(&1)])

      {output, status} =
        System.cmd(
          erl,
          ["+S", "2", "-noshell"] ++
            paths ++
            [
              "-boot",
              boot_path,
              "-s",
              "elixir",
              "start_cli",
              "-extra"
            ] ++ @argv,
          stderr_to_stdout: true,
          env: [
            {"__BURRITO", "1"},
            {"HOME", home},
            {"TACKLE_HOME", Path.join(home, "tackle")},
            {"BOOT_STOP_FILE", stop_file},
            {"ERL_CRASH_DUMP", Path.join(home, "erl_crash.dump")},
            {"ERL_AFLAGS", nil},
            {"ERL_FLAGS", nil},
            {"ERL_ZFLAGS", nil}
          ]
        )

      assert status == @status, output
      assert output =~ @expected
      refute output =~ "Elixir 1."
      refute output =~ "Standalone options can't be combined"
      refute output =~ "No file named"
      assert File.read!(stop_file) == "stopped"
    end
  end
end
