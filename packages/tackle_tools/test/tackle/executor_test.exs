defmodule Tackle.ExecutorTest do
  alias Tackle.Tools.Test.Executors

  use ExUnit.Case, async: true, parameterize: Executors.parameters()

  import Executors, only: [start_executor: 1]

  alias Tackle.Executor
  alias Tackle.Lib.Cancellation
  alias Tackle.Tools.{Bash, Edit, Write}

  setup :start_executor

  setup do
    dir = Path.join(System.tmp_dir!(), "tackle-executor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "runs commands and reports their exit status", %{executor: executor, dir: dir} do
    assert {:ok, handle} = Executor.exec(executor, ["sh", "-c", "printf hi; exit 4"], cwd: dir)
    assert collect(executor, handle, "") == {4, "hi"}

    # Spawn failures may surface from exec/3 or as the first event.
    reason =
      case Executor.exec(executor, ["tackle-missing-command"], cwd: dir) do
        {:error, reason} -> reason
        {:ok, handle} -> handle |> then(&Executor.await(executor, &1, 5_000)) |> elem(1)
      end

    assert reason == "tackle-missing-command: command not found"
  end

  test "input writes to a running command's standard input", %{executor: executor, dir: dir} do
    {:ok, handle} = Executor.exec(executor, ["head", "-n", "2"], cwd: dir)

    assert :ok = Executor.input(executor, handle, "one\n")
    assert :ok = Executor.input(executor, handle, "two\nthree\n")
    assert collect(executor, handle, "") == {0, "one\ntwo\n"}
  end

  test "input keeps a command reading until it is cancelled", %{executor: executor, dir: dir} do
    {:ok, handle} = Executor.exec(executor, ["cat"], cwd: dir)

    for line <- ["a\n", "b\n"] do
      assert :ok = Executor.input(executor, handle, line)
      assert {:data, ^line} = Executor.await(executor, handle, 5_000)
    end

    assert :ok = Executor.cancel(executor, handle)
  end

  test "cancel kills the command's whole process group", %{executor: executor, dir: dir} do
    {:ok, handle} = Executor.exec(executor, ["sh", "-c", "sleep 30 & echo $!; wait"], cwd: dir)
    assert {:data, pid_line} = Executor.await(executor, handle, 5_000)
    child = pid_line |> String.trim() |> String.to_integer()

    assert :ok = Executor.cancel(executor, handle)
    assert wait_until_dead(child)
    assert Executor.await(executor, handle, 50) == :timeout
  end

  test "bash cancellation also stops background children", %{executor: executor, dir: dir} do
    signal = Cancellation.new_signal()
    on_exit(fn -> Cancellation.delete(signal) end)
    parent = self()

    context = %{
      cwd: dir,
      executor: executor,
      cancellation_signal: signal,
      event_callback: fn event -> send(parent, {:delta, event.data.delta}) end
    }

    task = Task.async(fn -> Bash.run(%{"command" => "sleep 30 & echo $!; wait"}, context) end)
    assert_receive {:delta, pid_line}, 5_000
    child = pid_line |> String.trim() |> String.to_integer()

    assert :ok = Cancellation.cancel(signal, :test)
    assert {:error, output} = Task.await(task, 5_000)
    assert String.ends_with?(output, "Command aborted")
    assert wait_until_dead(child)
  end

  test "read_file reads across chunk boundaries", %{executor: executor, dir: dir} do
    path = Path.join(dir, "big")
    data = :crypto.strong_rand_bytes(2_500_000)
    File.write!(path, data)

    assert {:ok, ^data} = Executor.read_file(executor, path)
    File.write!(path, "")
    assert {:ok, ""} = Executor.read_file(executor, path)
    assert {:error, :enoent} = Executor.read_file(executor, Path.join(dir, "missing"))
    assert {:error, :eisdir} = Executor.read_file(executor, dir)
  end

  test "edit handles files larger than one read chunk", %{executor: executor, dir: dir} do
    path = Path.join(dir, "big.txt")
    File.write!(path, String.duplicate("line\n", 300_000) <> "needle\n")
    context = %{cwd: dir, executor: executor}

    assert {:ok, _message} =
             Edit.run(
               %{
                 "path" => "big.txt",
                 "edits" => [%{"oldText" => "needle", "newText" => "found"}]
               },
               context
             )

    assert String.ends_with?(File.read!(path), "line\nfound\n")
  end

  test "write reports filesystem errors", %{executor: executor, dir: dir} do
    File.write!(Path.join(dir, "file"), "x")
    context = %{cwd: dir, executor: executor}

    assert {:error, "Could not write file/child.txt: not a directory"} =
             Write.run(%{"path" => "file/child.txt", "content" => "x"}, context)
  end

  defp collect(executor, handle, output) do
    case Executor.await(executor, handle, 5_000) do
      {:data, data} -> collect(executor, handle, output <> data)
      {:exit_status, status} -> {status, output}
      other -> {other, output}
    end
  end

  defp wait_until_dead(os_pid, attempts \\ 100)
  defp wait_until_dead(_os_pid, 0), do: false

  defp wait_until_dead(os_pid, attempts) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} ->
        [_, rest] = String.split(stat, ") ", parts: 2)

        if String.starts_with?(rest, "Z") do
          true
        else
          Process.sleep(20)
          wait_until_dead(os_pid, attempts - 1)
        end

      {:error, _reason} ->
        true
    end
  end
end

defmodule Tackle.Executor.JailedTest do
  use ExUnit.Case, async: true

  alias Tackle.Executor
  alias Tackle.Tools.{Bash, Read}
  alias Tackle.Tools.Test.Executors

  setup do
    %{executor: executor} = Executors.start_executor(%{executor_kind: :jailed})
    {Executor.Jailed, %{client: client}} = executor
    %{executor: executor, client: client}
  end

  test "reports a dead execution environment to the model", %{executor: executor, client: client} do
    parent = self()

    context = %{
      cwd: "/",
      executor: executor,
      event_callback: fn _event -> send(parent, :started) end
    }

    task = Task.async(fn -> Bash.run(%{"command" => "echo started; exec sleep 30"}, context) end)
    assert_receive :started, 5_000
    %{os_pid: os_pid} = :sys.get_state(client)
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])

    assert {:error, message} = Task.await(task, 5_000)

    assert message ==
             "started\n\n\nCommand failed: the execution environment is not available"

    assert {:error, "Could not read x: the execution environment is not available"} =
             Read.run(%{"path" => "x"}, context)
  end

  test "tmp_dir is configurable" do
    assert Executor.tmp_dir(Executor.Jailed.new(:client, workspace: "/w")) == "/tmp"

    assert Executor.tmp_dir(Executor.Jailed.new(:client, workspace: "/w", tmp_dir: "/scratch")) ==
             "/scratch"
  end

  test "the workspace is required and reported" do
    assert Executor.workspace(Executor.Jailed.new(:client, workspace: "/w/../work")) == "/work"
    assert Executor.workspace(Executor.local()) == nil
    assert_raise ArgumentError, fn -> Executor.Jailed.new(:client, []) end
  end

  test "input is unsupported by executors without the callback" do
    assert {:error, :unsupported} = Executor.input({Tackle.ExecutorTest.NoInput, nil}, :h, "x")
    assert Executor.format_reason(:unsupported) =~ "does not support"
  end

  test "format_reason covers POSIX, executor, and free-form reasons" do
    assert Executor.format_reason(:enoent) == "no such file or directory"
    assert Executor.format_reason(:too_large) =~ "too large"
    assert Executor.format_reason("bash: command not found") == "bash: command not found"
    assert Executor.format_reason({:weird, 1}) == "{:weird, 1}"
  end

  test "commands do not inherit the host environment", %{executor: executor} do
    # The launcher keeps only PATH, LANG, and LC_ALL, so host secrets such as
    # provider API keys never reach jailed commands.
    assert {:ok, "unset"} =
             Bash.run(%{"command" => "printf ${HOME:-unset}"}, %{executor: executor})
  end

  test "adds the configured environment to every command", %{client: client} do
    executor =
      Executor.Jailed.new(client,
        workspace: "/",
        env: [{"TACKLE_FORWARDED", "secret"}, {"TACKLE_SHADOWED", "base"}]
      )

    assert {:ok, "secret base"} =
             Bash.run(
               %{"command" => "printf '%s %s' \"$TACKLE_FORWARDED\" \"$TACKLE_SHADOWED\""},
               %{executor: executor}
             )

    # A command's own environment takes precedence.
    {:ok, handle} =
      Executor.exec(executor, ["sh", "-c", "printf %s \"$TACKLE_SHADOWED\""],
        cwd: "/",
        env: [{"TACKLE_SHADOWED", "command"}]
      )

    assert collect(executor, handle, "") == "command"
  end

  test "keeps the configured environment out of inspected executors" do
    executor = Executor.Jailed.new(:client, workspace: "/w", env: [{"GH_TOKEN", "secret"}])
    refute inspect(executor) =~ "secret"

    assert_raise ArgumentError, fn ->
      Executor.Jailed.new(:client, workspace: "/w", env: [{"GH_TOKEN", 1}])
    end
  end

  defp collect(executor, handle, output) do
    case Executor.await(executor, handle, 5_000) do
      {:data, data} -> collect(executor, handle, output <> data)
      {:exit_status, 0} -> output
    end
  end
end

defmodule Tackle.ExecutorTest.NoInput do
  @moduledoc false
end
