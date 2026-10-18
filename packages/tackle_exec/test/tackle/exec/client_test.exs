defmodule Tackle.Exec.ClientTest do
  use ExUnit.Case, async: true

  import Tackle.Exec.TestSupport

  alias Tackle.Exec.Client

  setup do
    directory =
      Path.join(System.tmp_dir!(), "tackle-exec-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    client = start_supervised!({Client, launcher: server_launcher()})
    %{client: client, directory: directory}
  end

  describe "input/3" do
    test "writes to a running command's standard input", %{client: client, directory: dir} do
      {:ok, ref} = Client.exec(client, ["cat"], cwd: dir)

      assert :ok = Client.input(client, ref, "hello\n")
      assert_receive {:tackle_exec, ^ref, {:data, "hello\n"}}, 5_000
      Client.ack(client, ref, 6)

      assert :ok = Client.input(client, ref, "")
      assert :ok = Client.input(client, ref, "again\n")
      assert_receive {:tackle_exec, ^ref, {:data, "again\n"}}, 5_000
      Client.ack(client, ref, 6)

      Client.signal(client, ref, :kill)
      assert {:ok, 137, ""} = collect(client, ref)
    end

    test "a command can read input until it is done", %{client: client, directory: dir} do
      {:ok, ref} = Client.exec(client, ["head", "-n", "2"], cwd: dir)

      assert :ok = Client.input(client, ref, "one\ntwo\nthree\n")
      assert {:ok, 0, "one\ntwo\n"} = collect(client, ref)
    end

    test "rejects unknown and finished commands and oversized input", %{directory: dir} do
      client =
        start_supervised!({Client, launcher: server_launcher(), max_input: 8}, id: :small_input)

      assert {:error, :unknown_command} = Client.input(client, make_ref(), "x")

      {:ok, ref} = Client.exec(client, ["cat"], cwd: dir)
      assert {:error, :too_large} = Client.input(client, ref, "123456789")
      assert :ok = Client.input(client, ref, "12345678")
      Client.signal(client, ref, :kill)
      assert {:ok, 137, "12345678"} = collect(client, ref)

      assert {:error, :unknown_command} = Client.input(client, ref, "x")
    end

    test "a command that does not read its input stalls neither the server nor others", %{
      client: client,
      directory: dir
    } do
      {:ok, ref} = Client.exec(client, ["sleep", "30"], cwd: dir)
      chunk = :binary.copy("x", 1_024 * 1_024)

      for _ <- 1..4, do: assert(:ok = Client.input(client, ref, chunk))

      assert {:ok, 0, "still here\n"} = run(client, ["echo", "still here"], cwd: dir)
      assert {:ok, %{type: :directory}} = Client.stat(client, dir)

      # The kill interrupts a pending write, so the exit status is lost.
      Client.signal(client, ref, :kill)

      assert {:error, "command stopped reading its input; exit status unknown", ""} =
               collect(client, ref)
    end

    test "kills a command whose unread input overflows the buffer", %{
      client: client,
      directory: dir
    } do
      {:ok, ref} = Client.exec(client, ["sleep", "30"], cwd: dir)
      chunk = :binary.copy("x", 1_024 * 1_024)

      # The port driver holds one chunk itself; the writer's queue holds the
      # rest. The client refuses input with :busy while its own queue to the
      # jail is full, so retry until all of it is sent.
      for _ <- 1..20, do: send_input(client, ref, chunk)

      assert {:error, "input buffer overflow", ""} = collect(client, ref, 10_000)
    end
  end

  defp send_input(client, ref, data) do
    case Client.input(client, ref, data) do
      {:error, :busy} ->
        Process.sleep(10)
        send_input(client, ref, data)

      result ->
        result
    end
  end

  describe "exec/3" do
    test "streams merged output and the exit status", %{client: client, directory: dir} do
      assert {:ok, 0, "out\nerr\n"} =
               run(client, ["sh", "-c", "echo out; echo err >&2"], cwd: dir)

      assert {:ok, 3, ""} = run(client, ["sh", "-c", "exit 3"], cwd: dir)
    end

    test "uses the requested working directory and environment", %{
      client: client,
      directory: dir
    } do
      assert {:ok, 0, output} =
               run(client, ["sh", "-c", "pwd; echo $TACKLE_EXEC_TEST"],
                 cwd: dir,
                 env: [{"TACKLE_EXEC_TEST", "hello"}]
               )

      assert output == "#{dir}\nhello\n"
    end

    test "reports spawn failures as errors", %{client: client, directory: dir} do
      assert {:error, "tackle-exec-missing-command: command not found", ""} =
               run(client, ["tackle-exec-missing-command"], cwd: dir)

      assert {:error, :enoent, ""} = run(client, ["./missing"], cwd: dir)
    end

    test "commands that finish instantly are reported normally", %{
      client: client,
      directory: dir
    } do
      for _ <- 1..100 do
        assert {:ok, 0, "fast\n"} = run(client, ["echo", "fast"], cwd: dir)
      end
    end

    test "rejects invalid requests before sending them", %{client: client} do
      assert {:error, :invalid_request} = Client.exec(client, [], cwd: "/")
      assert {:error, :invalid_request} = Client.exec(client, ["true"], [])

      assert {:error, :invalid_request} =
               Client.exec(client, ["true"], cwd: "/", env: [{"A=B", "c"}])

      refute_received {:DOWN, _ref, :process, _pid, _reason}
    end

    test "delivers large output intact", %{client: client, directory: dir} do
      assert {:ok, 0, output} = run(client, ["head", "-c", "3000000", "/dev/zero"], cwd: dir)
      assert byte_size(output) == 3_000_000
    end

    test "holds output and the exit beyond the window until acknowledged", %{directory: dir} do
      client = start_supervised!({Client, launcher: server_launcher(), window: 4_096}, id: :small)
      {:ok, ref} = Client.exec(client, ["head", "-c", "20000", "/dev/zero"], cwd: dir)

      assert receive_unacked(ref, 0) == 4_096
      refute_received {:tackle_exec, ^ref, {:exit_status, _status}}

      Client.ack(client, ref, 4_096)
      assert {:ok, 0, rest} = collect(client, ref)
      assert byte_size(rest) == 20_000 - 4_096
    end

    test "kills a command whose unacknowledged output overflows the buffer", %{directory: dir} do
      client = start_supervised!({Client, launcher: server_launcher(), window: 4_096}, id: :small)
      {:ok, ref} = Client.exec(client, ["head", "-c", "40000000", "/dev/zero"], cwd: dir)

      assert_receive {:tackle_exec, ^ref, {:data, data}}, 5_000
      assert byte_size(data) == 4_096
      assert_receive {:tackle_exec, ^ref, {:error, "output buffer overflow"}}, 10_000
    end

    test "signals the whole process group", %{client: client, directory: dir} do
      {:ok, ref} =
        Client.exec(client, ["sh", "-c", "sleep 30 & echo $!; wait"], cwd: dir)

      assert_receive {:tackle_exec, ^ref, {:data, pid_line}}, 5_000
      Client.ack(client, ref, byte_size(pid_line))
      child = pid_line |> String.trim() |> String.to_integer()

      Client.signal(client, ref, :term)
      assert {:ok, 143, ""} = collect(client, ref)
      assert wait_until_dead(child)
    end

    test "kills with SIGKILL and ignores signals for finished commands", %{
      client: client,
      directory: dir
    } do
      {:ok, ref} =
        Client.exec(client, ["sh", "-c", "trap '' TERM; echo ready; sleep 30"], cwd: dir)

      assert_receive {:tackle_exec, ^ref, {:data, "ready\n"}}, 5_000
      Client.ack(client, ref, 6)

      Client.signal(client, ref, :kill)
      assert {:ok, 137, ""} = collect(client, ref)

      Client.signal(client, ref, :term)
      assert {:ok, 0, "still here\n"} = run(client, ["echo", "still here"], cwd: dir)
    end

    test "kills the command and drains its output when the caller exits", %{
      client: client,
      directory: dir
    } do
      test = self()

      caller =
        spawn(fn ->
          {:ok, ref} =
            Client.exec(client, ["sh", "-c", "echo $$; head -c 1000000 /dev/zero; sleep 30"],
              cwd: dir
            )

          assert_receive {:tackle_exec, ^ref, {:data, pid_line}}, 5_000
          send(test, {:pid, pid_line |> String.split("\n") |> hd() |> String.to_integer()})
        end)

      monitor = Process.monitor(caller)
      assert_receive {:pid, command}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^caller, _reason}, 5_000
      assert wait_until_dead(command)
      assert eventually(fn -> :sys.get_state(client).requests == %{} end)
    end

    @tag :capture_log
    test "ends the stream with :DOWN when the client is killed", %{directory: dir} do
      client =
        start_supervised!(
          Supervisor.child_spec({Client, launcher: server_launcher()}, restart: :temporary),
          id: :killed
        )

      {:ok, ref} = Client.exec(client, ["sh", "-c", "echo $$; exec sleep 30"], cwd: dir)
      assert_receive {:tackle_exec, ^ref, {:data, pid_line}}, 5_000
      command = pid_line |> String.trim() |> String.to_integer()
      # Without a PID namespace the command outlives the server; clean it up.
      on_exit(fn -> System.cmd("kill", ["-KILL", Integer.to_string(command)]) end)

      Process.exit(client, :kill)
      assert_receive {:DOWN, ^ref, :process, ^client, :killed}, 5_000
    end
  end

  describe "filesystem operations" do
    test "write, read, and stat round-trip", %{client: client, directory: dir} do
      path = Path.join(dir, "nested/file.txt")

      assert {:error, :enoent} = Client.write(client, path, "data")
      assert :ok = Client.write(client, path, "hello world", mkdir_p: true)
      assert File.read!(path) == "hello world"

      assert {:ok, %{data: "hello", size: 11, eof: false}} = Client.read(client, path, 0, 5)
      assert {:ok, %{data: "world", size: 11, eof: true}} = Client.read(client, path, 6, 100)
      assert {:ok, %{data: "", size: 11, eof: true}} = Client.read(client, path, 50, 10)

      assert {:ok, %{type: :regular, size: 11, mode: mode}} = Client.stat(client, path)
      assert is_integer(mode)
      assert {:ok, %{type: :directory}} = Client.stat(client, Path.dirname(path))
    end

    test "lists directory entries", %{client: client, directory: dir} do
      File.mkdir_p!(Path.join(dir, "sub"))
      File.write!(Path.join(dir, "file"), "x")

      assert {:ok, names} = Client.list(client, dir)
      assert Enum.sort(names) == ["file", "sub"]
      assert {:error, :enotdir} = Client.list(client, Path.join(dir, "file"))
      assert {:error, :enoent} = Client.list(client, Path.join(dir, "missing"))
    end

    test "returns POSIX errors as atoms", %{client: client, directory: dir} do
      assert {:error, :enoent} = Client.read(client, Path.join(dir, "missing"), 0, 1)
      assert {:error, :enoent} = Client.stat(client, Path.join(dir, "missing"))
      assert {:error, :eisdir} = Client.read(client, dir, 0, 1)
    end

    test "appends, creates private files exclusively, and deletes", %{
      client: client,
      directory: dir
    } do
      path = Path.join(dir, "spill/out.log")

      assert :ok = Client.write(client, path, "one", mode: :create, mkdir_p: true)
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      assert {:error, :eexist} = Client.write(client, path, "again", mode: :create)
      assert :ok = Client.write(client, path, "two", mode: :append)
      assert File.read!(path) == "onetwo"

      assert :ok = Client.delete(client, path)
      refute File.exists?(path)
      assert {:error, :enoent} = Client.delete(client, path)
    end

    test "rejects oversized and invalid requests", %{directory: dir} do
      client =
        start_supervised!(
          {Client, launcher: server_launcher(), max_frame: 10_000, max_write: 10_000},
          id: :tiny
        )

      path = Path.join(dir, "file")
      assert {:error, :too_large} = Client.write(client, path, :binary.copy("x", 10_001))
      assert :ok = Client.write(client, path, :binary.copy("x", 10_000))
      assert {:error, :too_large} = Client.read(client, path, 0, 10_000)
      assert {:error, :invalid_request} = Client.read(client, path, -1, 1)
      assert {:error, :invalid_request} = Client.stat(client, "")
    end

    test "a blocking read does not stall other requests, which are bounded", %{directory: dir} do
      client =
        start_supervised!({Client, launcher: server_launcher(), max_requests: 2}, id: :bounded)

      fifo = Path.join(dir, "fifo")
      {_, 0} = System.cmd("mkfifo", [fifo])

      assert {:error, :timeout} = Client.read(client, fifo, 0, 1, 200)
      assert {:ok, %{type: :directory}} = Client.stat(client, dir)

      assert {:error, :timeout} = Client.read(client, fifo, 0, 1, 200)
      assert {:error, :busy} = Client.stat(client, dir)
    end
  end

  describe "lifecycle" do
    test "limits the client heap including off-heap binaries", %{client: client} do
      assert {:max_heap_size, %{size: size, kill: true, include_shared_binaries: true}} =
               Process.info(client, :max_heap_size)

      assert size == div(256 * 1_024 * 1_024, :erlang.system_info(:wordsize))
    end

    test "the exec-server exits when the client stops", %{client: client} do
      %{os_pid: os_pid} = :sys.get_state(client)

      stop_supervised!(Client)
      assert wait_until_dead(os_pid)
    end

    test "fails pending commands when the exec-server dies", %{directory: dir} do
      Process.flag(:trap_exit, true)
      {:ok, client} = Client.start_link(launcher: server_launcher())
      {:ok, ref} = Client.exec(client, ["sh", "-c", "echo $$; exec sleep 30"], cwd: dir)
      assert_receive {:tackle_exec, ^ref, {:data, pid_line}}, 5_000
      command = pid_line |> String.trim() |> String.to_integer()
      # Without a PID namespace the command outlives the server; clean it up.
      on_exit(fn -> System.cmd("kill", ["-KILL", Integer.to_string(command)]) end)
      %{os_pid: os_pid} = :sys.get_state(client)

      System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])

      assert_receive {:tackle_exec, ^ref, {:error, :exec_server_down}}, 5_000
      assert_receive {:EXIT, ^client, {:shutdown, {:exec_server_exited, 137}}}, 5_000
      assert {:error, :exec_server_down} = Client.stat(client, dir)
      assert {:error, :exec_server_down} = Client.exec(client, ["true"], cwd: dir)
    end

    test "starts the launcher in the requested directory", %{directory: dir} do
      client = start_supervised!({Client, launcher: server_launcher(), cd: dir}, id: :cd)
      assert {:ok, 0, output} = run(client, ["sh", "-c", "pwd"], cwd: dir)
      assert output == dir <> "\n"

      server_cwd = File.read_link!("/proc/#{:sys.get_state(client).os_pid}/cwd")
      assert server_cwd == dir
    end

    test "validates options" do
      Process.flag(:trap_exit, true)

      for {opts, key} <- [
            {[], :launcher},
            {[launcher: {"sh", [:bad]}], :launcher},
            {[launcher: server_launcher(), window: 0], :window},
            {[launcher: server_launcher(), max_frame: 100], :max_frame},
            {[launcher: server_launcher(), keep_env: :all], :keep_env},
            {[launcher: server_launcher(), cd: "/nonexistent-tackle-dir"], :cd}
          ] do
        assert {:error, {:shutdown, {:invalid_option, ^key}}} = Client.start_link(opts)
      end
    end
  end

  defp receive_unacked(ref, total) do
    receive do
      {:tackle_exec, ^ref, {:data, data}} -> receive_unacked(ref, total + byte_size(data))
    after
      300 -> total
    end
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
