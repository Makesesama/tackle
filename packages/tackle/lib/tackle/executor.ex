defmodule Tackle.Executor do
  @moduledoc """
  Where the built-in tools touch the workspace and run commands.

  `Tackle.Tools.Read`, `Write`, `Edit`, and `Bash` keep their tool logic on the
  host and delegate filesystem and process primitives to an executor taken from
  the tool context:

      context: %{cwd: "/work", executor: Tackle.Executor.Jailed.new(client)}

  Without `:executor`, tools use `Tackle.Executor.Local`, which runs everything
  with the Tackle process's own permissions. `Tackle.Executor.Jailed` runs the
  same primitives inside a jail through `Tackle.Exec.Client`.

  An executor is a `{module, config}` tuple. Paths are absolute paths as seen
  by the executor; the jailed launcher is expected to mount the workspace at
  the same path as on the host.

  ## Commands

  `exec/3` starts a command owned by the calling process. The caller then pulls
  events with `await/3` until it gets `{:exit_status, status}` or
  `{:error, reason}`, or stops early with `cancel/2`, which kills the
  command's whole process group. A command that cannot be started may be
  reported either by `exec/3` or as an `{:error, reason}` event, depending on
  whether the executor spawns synchronously.
  """

  alias Tackle.Executor.Local

  @typedoc "An executor implementation and its configuration."
  @type t :: {module(), term()}

  @typedoc "Opaque handle of a running command."
  @type handle :: term()

  @typedoc "Events returned by `await/3`."
  @type event :: {:data, binary()} | {:exit_status, non_neg_integer()} | {:error, term()}

  @typedoc "Result of a byte-range read."
  @type read_result :: %{data: binary(), size: non_neg_integer(), eof: boolean()}

  @typedoc "Error reasons: POSIX atoms such as `:enoent`, executor atoms, or messages."
  @type reason :: atom() | String.t()

  @doc """
  Starts `argv` with standard error merged into standard output.

  Options: `:cwd` (required) and `:env`, a list of `{name, value}` strings.
  """
  @callback exec(config :: term(), argv :: [String.t()], opts :: keyword()) ::
              {:ok, handle()} | {:error, reason()}

  @doc "Waits up to `timeout` milliseconds for the next command event."
  @callback await(config :: term(), handle(), timeout :: non_neg_integer()) :: event() | :timeout

  @doc "Kills the command's process group and discards its remaining events."
  @callback cancel(config :: term(), handle()) :: :ok

  @doc "Reads up to `length` bytes at `offset`. Directories return `:eisdir`."
  @callback read(config :: term(), Path.t(), non_neg_integer(), pos_integer()) ::
              {:ok, read_result()} | {:error, reason()}

  @doc """
  Writes data to a file.

  Options: `:mode` (`:replace`, `:append`, or `:create` for a new owner-only
  file) and `:mkdir_p`. See `Tackle.Exec.FileOps.write/3`.
  """
  @callback write(config :: term(), Path.t(), binary(), keyword()) :: :ok | {:error, reason()}

  @doc "Deletes a file."
  @callback delete(config :: term(), Path.t()) :: :ok | {:error, reason()}

  @doc "Returns a directory for temporary files, as seen by the executor."
  @callback tmp_dir(config :: term()) :: Path.t()

  @read_file_chunk 1_024 * 1_024

  @doc "Returns the local executor."
  @spec local() :: t()
  def local, do: {Local, nil}

  @doc "Returns the executor from a tool context, defaulting to the local executor."
  @spec from_context(map()) :: t()
  def from_context(%{executor: {module, _config} = executor}) when is_atom(module), do: executor
  def from_context(_context), do: local()

  @doc "See the `c:exec/3` callback."
  @spec exec(t(), [String.t()], keyword()) :: {:ok, handle()} | {:error, reason()}
  def exec({module, config}, argv, opts), do: module.exec(config, argv, opts)

  @doc "See the `c:await/3` callback."
  @spec await(t(), handle(), non_neg_integer()) :: event() | :timeout
  def await({module, config}, handle, timeout), do: module.await(config, handle, timeout)

  @doc "See the `c:cancel/2` callback."
  @spec cancel(t(), handle()) :: :ok
  def cancel({module, config}, handle), do: module.cancel(config, handle)

  @doc "See the `c:read/4` callback."
  @spec read(t(), Path.t(), non_neg_integer(), pos_integer()) ::
          {:ok, read_result()} | {:error, reason()}
  def read({module, config}, path, offset, length), do: module.read(config, path, offset, length)

  @doc "See the `c:write/4` callback."
  @spec write(t(), Path.t(), binary(), keyword()) :: :ok | {:error, reason()}
  def write({module, config}, path, data, opts \\ []), do: module.write(config, path, data, opts)

  @doc "See the `c:delete/2` callback."
  @spec delete(t(), Path.t()) :: :ok | {:error, reason()}
  def delete({module, config}, path), do: module.delete(config, path)

  @doc "See the `c:tmp_dir/1` callback."
  @spec tmp_dir(t()) :: Path.t()
  def tmp_dir({module, config}), do: module.tmp_dir(config)

  @doc "Reads a whole file in chunks."
  @spec read_file(t(), Path.t()) :: {:ok, binary()} | {:error, reason()}
  def read_file(executor, path), do: read_file(executor, path, 0, [])

  defp read_file(executor, path, offset, chunks) do
    case read(executor, path, offset, @read_file_chunk) do
      {:ok, %{data: data, eof: true}} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([data | chunks]))}

      {:ok, %{data: ""}} ->
        {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}

      {:ok, %{data: data}} ->
        read_file(executor, path, offset + byte_size(data), [data | chunks])

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Formats an error reason for a model-facing message."
  @spec format_reason(reason()) :: String.t()
  def format_reason(reason) when is_binary(reason), do: reason
  def format_reason(:too_large), do: "data is too large for the execution environment"
  def format_reason(:exec_server_down), do: "the execution environment is not available"
  def format_reason(:busy), do: "the execution environment is busy"
  def format_reason(:timeout), do: "the execution environment did not respond in time"
  def format_reason(:invalid_request), do: "invalid request"

  def format_reason(reason) when is_atom(reason),
    do: reason |> :file.format_error() |> List.to_string()

  def format_reason(reason), do: inspect(reason)
end
