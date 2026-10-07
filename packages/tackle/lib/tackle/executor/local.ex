defmodule Tackle.Executor.Local do
  @moduledoc """
  Executor that runs commands and file operations in the Tackle process's own
  environment, with its filesystem and operating-system permissions.

  This is the default executor. It provides no isolation.
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
    after
      timeout -> :timeout
    end
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
