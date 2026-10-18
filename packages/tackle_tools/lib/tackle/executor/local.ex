defmodule Tackle.Executor.Local do
  @moduledoc """
  Executor that runs commands and file operations in the Tackle process's own
  environment, with its filesystem and operating-system permissions.

  This is the default executor. It provides no isolation.

  A command's port is linked to the process that started it. Writing input
  to a command that has closed its standard input closes the port with
  `:epipe`, which sends that process an exit signal; a process that writes
  input should trap exits, and `await/3` then reports the exit as
  `{:error, reason}`. `input/3` blocks while the command does not read its
  input; callers that must stay responsive write from a process of their own.
  """

  @behaviour Tackle.Executor

  alias Tackle.Exec.{Command, FileOps}

  @impl true
  def exec(_config, argv, opts) do
    with {:ok, port, os_pid} <-
           Command.open(argv, Keyword.fetch!(opts, :cwd), Keyword.get(opts, :env, [])) do
      {:ok, %{port: port, os_pid: os_pid}}
    end
  end

  @impl true
  def await(_config, %{port: port}, timeout) do
    receive do
      {^port, {:data, data}} -> {:data, data}
      {^port, {:exit_status, status}} -> {:exit_status, status}
      {:EXIT, ^port, reason} when reason != :normal -> {:error, reason}
    after
      timeout -> :timeout
    end
  end

  @impl true
  def input(_config, %{port: port}, data) do
    Port.command(port, data)
    :ok
  rescue
    ArgumentError -> {:error, :closed}
  end

  @impl true
  def cancel(_config, %{port: port, os_pid: os_pid}) do
    # Kill while the port is open, so the process group has not been reaped.
    if Port.info(port), do: Command.kill_group(os_pid, :kill)
    close(port)
    flush(port)
  end

  @impl true
  def read(_config, path, offset, length), do: FileOps.read(path, offset, length)

  @impl true
  def write(_config, path, data, opts), do: FileOps.write(path, data, opts)

  @impl true
  def delete(_config, path), do: FileOps.delete(path)

  @impl true
  def stat(_config, path), do: FileOps.stat(path)

  @impl true
  def list(_config, path), do: FileOps.list(path)

  @impl true
  def tmp_dir(_config), do: System.tmp_dir!()

  @impl true
  def workspace(_config), do: nil

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end
end
