defmodule Tackle.Test.FakeJail do
  @moduledoc false
  # A local executor that behaves like a jail whose only mount is the workspace:
  # any path that resolves (following symlinks) outside it does not exist.
  # Calls are reported to `config.observer` so tests can see what was routed.

  @behaviour Tackle.Executor

  alias Tackle.Executor.Local

  def new(workspace, observer \\ nil),
    do: {__MODULE__, %{workspace: Path.expand(workspace), observer: observer}}

  @impl true
  def exec(_config, argv, opts), do: Local.exec(nil, argv, opts)
  @impl true
  def await(_config, handle, timeout), do: Local.await(nil, handle, timeout)
  @impl true
  def cancel(_config, handle), do: Local.cancel(nil, handle)
  @impl true
  def tmp_dir(_config), do: System.tmp_dir!()
  @impl true
  def workspace(config), do: config.workspace

  @impl true
  def read(config, path, offset, length),
    do: guarded(config, :read, path, fn -> Local.read(nil, path, offset, length) end)

  @impl true
  def write(config, path, data, opts),
    do: guarded(config, :write, path, fn -> Local.write(nil, path, data, opts) end)

  @impl true
  def delete(config, path), do: guarded(config, :delete, path, fn -> Local.delete(nil, path) end)

  @impl true
  def stat(config, path), do: guarded(config, :stat, path, fn -> Local.stat(nil, path) end)

  @impl true
  def list(config, path), do: guarded(config, :list, path, fn -> Local.list(nil, path) end)

  defp guarded(config, op, path, fun) do
    if config.observer, do: send(config.observer, {:fake_jail, op, path})

    if inside?(realpath(path), config.workspace), do: fun.(), else: {:error, :enoent}
  end

  defp inside?(path, workspace),
    do: path == workspace or String.starts_with?(path, workspace <> "/")

  defp realpath(path), do: resolve(Path.split(Path.expand(path)), "/", 0)

  defp resolve(_parts, _acc, 40), do: "/nonexistent-symlink-loop"
  defp resolve([], acc, _depth), do: acc
  defp resolve(["/" | rest], _acc, depth), do: resolve(rest, "/", depth)

  defp resolve([part | rest], acc, depth) do
    candidate = Path.join(acc, part)

    case File.read_link(candidate) do
      {:ok, target} ->
        resolve(Path.split(Path.expand(target, acc)) ++ rest, "/", depth + 1)

      {:error, _reason} ->
        resolve(rest, candidate, depth)
    end
  end
end

defmodule Tackle.Test.EndlessReads do
  @moduledoc false
  # A hostile executor whose reads never reach end of file.

  @behaviour Tackle.Executor

  alias Tackle.Executor.Local

  @impl true
  def exec(_workspace, argv, opts), do: Local.exec(nil, argv, opts)
  @impl true
  def await(_workspace, handle, timeout), do: Local.await(nil, handle, timeout)
  @impl true
  def cancel(_workspace, handle), do: Local.cancel(nil, handle)
  @impl true
  def read(_workspace, _path, _offset, length),
    do: {:ok, %{data: :binary.copy("x", length), size: 0, eof: false}}

  @impl true
  def write(_workspace, path, data, opts), do: Local.write(nil, path, data, opts)
  @impl true
  def delete(_workspace, path), do: Local.delete(nil, path)
  @impl true
  def stat(_workspace, _path), do: {:ok, %{type: :regular, size: 0, mode: 0o100644}}
  @impl true
  def list(_workspace, _path), do: {:ok, []}
  @impl true
  def tmp_dir(_workspace), do: System.tmp_dir!()
  @impl true
  def workspace(workspace), do: workspace
end
