defmodule Tackle.Elixir.ProjectNodeTest do
  alias Tackle.Elixir.Test.Executors

  use ExUnit.Case, async: true, parameterize: Executors.parameters()

  import Executors, only: [start_executor: 1]

  alias Tackle.Elixir.Diagnostic
  alias Tackle.Elixir.ProjectNode
  alias Tackle.Elixir.Test.Projects
  alias Tackle.Lib.Cancellation

  # Starting a broker and a project node takes about a second; compiles of
  # these small projects are faster.
  @moduletag timeout: 120_000

  setup :start_executor

  defp start_node(%{executor: executor}, opts \\ []) do
    start_supervised!({ProjectNode, Keyword.put(opts, :executor, executor)})
  end

  describe "compile/3" do
    test "compiles a project and reports errors and warnings as data", ctx do
      root = Projects.new(%{"lib/ok.ex" => "defmodule Ok do\n  def ok, do: :ok\nend\n"})
      node = start_node(ctx)

      assert {:ok, %{status: :ok, diagnostics: [], output: _, duration_ms: ms}} =
               ProjectNode.compile(node, root)

      assert is_integer(ms)

      Projects.write(root, "lib/broken.ex", """
      defmodule Broken do
        def unused(x), do: :ok
        def broken, do: missing_function()
      end
      """)

      assert {:ok, %{status: :error, diagnostics: diagnostics}} = ProjectNode.compile(node, root)
      broken = Path.join(root, "lib/broken.ex")

      assert %Diagnostic{severity: :error, file: ^broken, line: 3, message: message} =
               Enum.find(diagnostics, &(&1.severity == :error and &1.line == 3))

      assert message =~ "undefined function missing_function/0"

      assert %Diagnostic{file: ^broken, line: 2, message: unused} =
               Enum.find(diagnostics, &(&1.severity == :warning))

      assert unused =~ ~s(variable "x" is unused)

      Projects.write(root, "lib/broken.ex", """
      defmodule Broken do
        def unused(x), do: :ok
      end
      """)

      assert {:ok, %{status: :ok, diagnostics: [warning]}} = ProjectNode.compile(node, root)
      assert warning.severity == :warning

      # Warnings of files that did not change are reported again.
      assert {:ok, %{diagnostics: [^warning]}} = ProjectNode.compile(node, root)
    end

    test "one broker serves several projects", ctx do
      first = Projects.new(%{"lib/a.ex" => "defmodule A, do: def(a, do: :a)\n"})
      second = Projects.new(%{"lib/b.ex" => "defmodule B, do: def(b, do: missing())\n"})
      node = start_node(ctx)

      assert {:ok, %{status: :ok}} = ProjectNode.compile(node, first)
      assert {:ok, %{status: :error, diagnostics: [_ | _]}} = ProjectNode.compile(node, second)

      # Nothing changed in the first project since its compile.
      assert {:ok, %{status: :noop, diagnostics: []}} = ProjectNode.compile(node, first)
    end

    test "a directory that is not a Mix project fails to load", ctx do
      dir =
        Path.join(System.tmp_dir!(), "tackle-no-project-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      node = start_node(ctx)

      assert {:error, "cannot load the project: " <> _reason} = ProjectNode.compile(node, dir)

      # The broker survives and still serves other projects.
      root = Projects.new()
      assert {:ok, %{status: status}} = ProjectNode.compile(node, root)
      assert status in [:ok, :noop]
    end

    test "gives up on timeout and cancellation without stopping the node", ctx do
      root =
        Projects.new(%{"lib/slow.ex" => "defmodule Slow do\n  Process.sleep(2_000)\nend\n"})

      node = start_node(ctx)

      assert {:error, :timeout} = ProjectNode.compile(node, root, timeout_ms: 100)

      signal = Cancellation.new_signal()
      Cancellation.cancel(signal, "stop")

      assert {:error, :cancelled} =
               ProjectNode.compile(node, root, cancellation_signal: signal, timeout_ms: 60_000)

      assert {:ok, %{status: _status}} = ProjectNode.compile(node, root)
      assert Process.alive?(node)
    end

    test "fails when the broker stops", ctx do
      root = Projects.new()
      node = start_node(ctx)
      assert {:ok, _result} = ProjectNode.compile(node, root)

      monitor = Process.monitor(node)
      kill_broker(ctx, node)
      assert_receive {:DOWN, ^monitor, :process, ^node, _reason}, 10_000
      assert {:error, :node_down} = ProjectNode.compile(node, root)
    end
  end

  describe "start" do
    test "fails when elixir cannot be started", ctx do
      Process.flag(:trap_exit, true)

      # `sh` reports a missing command with status 127.
      assert {:error, {:broker_exited, 127}} =
               ProjectNode.start_link(executor: ctx.executor, elixir: "tackle-missing-elixir")
    end

    for mode <- [:bad_version, :garbage, :huge, :silent, :second_hello] do
      test "rejects a broker that sends #{mode}", ctx do
        Process.flag(:trap_exit, true)
        elixir = fake_elixir(unquote(mode))

        assert {:error, _reason} =
                 ProjectNode.start_link(
                   executor: ctx.executor,
                   elixir: elixir,
                   handshake_timeout: 2_000
                 )
      end
    end

    test "rejects an invalid result without stopping", ctx do
      node = start_node(ctx, elixir: fake_elixir(:bad_result))

      assert {:error, "the project node sent an invalid result"} =
               ProjectNode.compile(node, "/tmp")

      assert Process.alive?(node)
    end

    test "stops after the idle timeout", ctx do
      Process.flag(:trap_exit, true)
      {:ok, node} = ProjectNode.start_link(executor: ctx.executor, idle_timeout: 100)
      assert_receive {:EXIT, ^node, :normal}, 5_000
    end
  end

  # Kills the broker's OS process group from outside the client.
  defp kill_broker(%{executor_kind: :local}, node) do
    %{handle: %{os_pid: os_pid}} = :sys.get_state(node)
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
  end

  defp kill_broker(%{executor_kind: :jailed, client: client}, node) do
    %{handle: ref} = :sys.get_state(node)
    Tackle.Exec.Client.signal(client, ref, :kill)
  end

  defp fake_elixir(mode) do
    broker = Path.expand("../../support/fake_broker.exs", __DIR__)
    elixir = System.find_executable("elixir")

    path =
      Path.join(System.tmp_dir!(), "tackle-fake-elixir-#{System.unique_integer([:positive])}")

    File.write!(path, "#!/bin/sh\nexec '#{elixir}' '#{broker}' #{mode}\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
