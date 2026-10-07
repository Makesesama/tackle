defmodule Tackle.CLI.TestExecutor do
  @moduledoc false
  # The local executor with its own temporary directory, standing in for a
  # jail whose temporary directory differs from the host's.

  @behaviour Tackle.Executor

  alias Tackle.Executor.Local

  def new(tmp_dir, workspace \\ nil), do: {__MODULE__, {tmp_dir, workspace}}

  @impl true
  def exec(_config, argv, opts), do: Local.exec(nil, argv, opts)
  @impl true
  def await(_config, handle, timeout), do: Local.await(nil, handle, timeout)
  @impl true
  def cancel(_config, handle), do: Local.cancel(nil, handle)
  @impl true
  def read(_config, path, offset, length), do: Local.read(nil, path, offset, length)
  @impl true
  def write(_config, path, data, opts), do: Local.write(nil, path, data, opts)
  @impl true
  def delete(_config, path), do: Local.delete(nil, path)
  @impl true
  def stat(_config, path), do: Local.stat(nil, path)
  @impl true
  def list(_config, path), do: Local.list(nil, path)
  @impl true
  def tmp_dir({tmp_dir, _workspace}), do: tmp_dir
  @impl true
  def workspace({_tmp_dir, workspace}), do: workspace
end
