defmodule Tackle.Exec.FileOpsTest do
  use ExUnit.Case, async: true

  alias Tackle.Exec.{Command, FileOps}

  setup do
    dir = Path.join(System.tmp_dir!(), "tackle-file-ops-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "reads byte ranges and reports size and end of file", %{dir: dir} do
    path = Path.join(dir, "file")
    File.write!(path, "hello world")

    assert {:ok, %{data: "hello", size: 11, eof: false}} = FileOps.read(path, 0, 5)
    assert {:ok, %{data: "world", size: 11, eof: true}} = FileOps.read(path, 6, 10)
    assert {:ok, %{data: "", size: 11, eof: true}} = FileOps.read(path, 20, 1)
    assert {:error, :eisdir} = FileOps.read(dir, 0, 1)
    assert {:error, :enoent} = FileOps.read(Path.join(dir, "missing"), 0, 1)
  end

  test "replaces in place, keeping the inode", %{dir: dir} do
    path = Path.join(dir, "file")
    File.write!(path, "old content")
    inode = File.stat!(path).inode

    assert :ok = FileOps.write(path, "new")
    assert File.read!(path) == "new"
    assert File.stat!(path).inode == inode
  end

  test "creates parents only when asked", %{dir: dir} do
    path = Path.join(dir, "a/b/file")

    assert {:error, :enoent} = FileOps.write(path, "x")
    assert :ok = FileOps.write(path, "x", mkdir_p: true)
    assert {:error, :enotdir} = FileOps.write(Path.join(path, "child"), "x", mkdir_p: true)
  end

  test "create is exclusive and owner-only; append extends", %{dir: dir} do
    path = Path.join(dir, "log")

    assert :ok = FileOps.write(path, "a", mode: :create)
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert {:error, :eexist} = FileOps.write(path, "b", mode: :create)
    assert :ok = FileOps.write(path, "b", mode: :append)
    assert File.read!(path) == "ab"
  end

  test "lists directories", %{dir: dir} do
    File.write!(Path.join(dir, "file"), "x")
    assert {:ok, ["file"]} = FileOps.list(dir)
    assert {:error, :enotdir} = FileOps.list(Path.join(dir, "file"))
  end

  test "deletes files but not directories", %{dir: dir} do
    path = Path.join(dir, "file")
    File.write!(path, "x")

    assert :ok = FileOps.delete(path)
    assert {:error, :enoent} = FileOps.delete(path)
    assert {:error, _reason} = FileOps.delete(dir)
    assert File.dir?(dir)
  end

  test "commands that finish instantly still deliver their output and status", %{dir: dir} do
    # A command can exit before its OS process ID is read. Under load this used
    # to be misreported as a spawn failure, so exercise it concurrently.
    1..32
    |> Task.async_stream(
      fn _ ->
        for _ <- 1..50 do
          assert {:ok, port, _os_pid} = Command.open(["echo", "fast"], dir, [])
          assert_receive {^port, {:data, "fast\n"}}, 5_000
          assert_receive {^port, {:exit_status, 0}}, 5_000
        end
      end,
      max_concurrency: 32,
      timeout: 60_000
    )
    |> Stream.run()

    assert :ok = Command.kill_group(nil, :kill)
  end

  test "commands resolve from PATH and report spawn failures", %{dir: dir} do
    assert {:ok, port, os_pid} = Command.open(["sh", "-c", "echo $X"], dir, [{"X", "1"}])
    assert is_integer(os_pid)
    assert_receive {^port, {:data, "1\n"}}, 5_000
    assert_receive {^port, {:exit_status, 0}}, 5_000

    assert {:error, "tackle-missing: command not found"} =
             Command.open(["tackle-missing"], dir, [])

    assert {:error, "sh: command not found"} = Command.open(["sh"], dir, [{"PATH", dir}])
    assert {:error, :enoent} = Command.open(["./missing"], dir, [])
  end
end
