defmodule Tackle.Executor.Jailed do
  @moduledoc """
  Executor that runs commands and file operations inside a jail through a
  `Tackle.Exec.Client`.

  The host starts and supervises the client; this module only routes tool
  primitives to it:

      {:ok, client} = Tackle.Exec.Client.start_link(launcher: launcher)
      executor = Tackle.Executor.Jailed.new(client, workspace: workspace)
      context = %{cwd: workspace, executor: executor}

  Paths are interpreted inside the jail, so the launcher should mount the
  workspace at the same path as on the host. Command output is acknowledged to
  the client as `await/3` returns it.
  """

  @behaviour Tackle.Executor

  alias Tackle.Exec.Client

  @cancel_drain_timeout 2_000

  @doc """
  Returns an executor for `client`.

  ## Options

    * `:workspace` - required host directory that the jail mounts at the same
      path. Host-side reads of project files inside it go through the jail.
    * `:tmp_dir` - directory for temporary files inside the jail (default `"/tmp"`).
  """
  @spec new(GenServer.server(), keyword()) :: Tackle.Executor.t()
  def new(client, opts) do
    workspace =
      case Keyword.fetch(opts, :workspace) do
        {:ok, path} when is_binary(path) -> Path.expand(path)
        _missing -> raise ArgumentError, "Tackle.Executor.Jailed.new/2 requires :workspace"
      end

    {__MODULE__,
     %{client: client, workspace: workspace, tmp_dir: Keyword.get(opts, :tmp_dir, "/tmp")}}
  end

  @impl true
  def exec(%{client: client}, argv, opts) do
    Client.exec(client, argv, cwd: Keyword.fetch!(opts, :cwd), env: Keyword.get(opts, :env, []))
  end

  @impl true
  def await(%{client: client}, ref, timeout) do
    receive do
      {:tackle_exec, ^ref, {:data, data}} ->
        Client.ack(client, ref, byte_size(data))
        {:data, data}

      {:tackle_exec, ^ref, {:exit_status, status}} ->
        Process.demonitor(ref, [:flush])
        {:exit_status, status}

      {:tackle_exec, ^ref, {:error, reason}} ->
        Process.demonitor(ref, [:flush])
        {:error, reason}

      {:DOWN, ^ref, :process, _pid, _reason} ->
        {:error, :exec_server_down}
    after
      timeout -> :timeout
    end
  end

  @impl true
  def cancel(%{client: client} = config, ref) do
    Client.signal(client, ref, :kill)
    drain(config, ref, System.monotonic_time(:millisecond) + @cancel_drain_timeout)
  end

  @impl true
  def read(%{client: client}, path, offset, length), do: Client.read(client, path, offset, length)

  @impl true
  def write(%{client: client}, path, data, opts) do
    Client.write(client, path, data, Keyword.take(opts, [:mode, :mkdir_p]))
  end

  @impl true
  def delete(%{client: client}, path), do: Client.delete(client, path)

  @impl true
  def stat(%{client: client}, path), do: Client.stat(client, path)

  @impl true
  def list(%{client: client}, path), do: Client.list(client, path)

  @impl true
  def tmp_dir(%{tmp_dir: tmp_dir}), do: tmp_dir

  @impl true
  def workspace(%{workspace: workspace}), do: workspace

  # Wait for the killed command to finish so no stray messages reach the
  # caller later. If the client stops answering, give up and drop the monitor.
  defp drain(config, ref, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case await(config, ref, remaining) do
      {:data, _data} ->
        drain(config, ref, deadline)

      :timeout ->
        Process.demonitor(ref, [:flush])
        :ok

      _finished ->
        :ok
    end
  end
end
