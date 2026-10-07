defmodule Tackle.Exec.FileOps do
  @moduledoc """
  Filesystem primitives shared by the jailed exec-server and local executors.

  Keeping one implementation means a tool sees the same semantics whether it
  runs locally or through the jail. Errors are POSIX atoms such as `:enoent`.
  """

  @private_file_mode 0o600

  @typedoc "How `write/3` treats an existing file."
  @type write_mode :: :replace | :append | :create

  @typedoc "Result of `read/3`."
  @type read_result :: %{data: binary(), size: non_neg_integer(), eof: boolean()}

  @doc """
  Reads up to `length` bytes at `offset`.

  `size` is the file size when the read started; `eof` is true when fewer than
  `length` bytes were available. Directories return `{:error, :eisdir}`.
  """
  @spec read(Path.t(), non_neg_integer(), pos_integer()) ::
          {:ok, read_result()} | {:error, atom()}
  def read(path, offset, length) do
    with {:ok, %File.Stat{type: type, size: size}} <- File.stat(path),
         :ok <- if(type == :directory, do: {:error, :eisdir}, else: :ok),
         {:ok, io} <- :file.open(path, [:read, :raw, :binary]) do
      try do
        case :file.pread(io, offset, length) do
          {:ok, data} -> {:ok, %{data: data, size: size, eof: byte_size(data) < length}}
          :eof -> {:ok, %{data: "", size: size, eof: true}}
          {:error, reason} -> {:error, reason}
        end
      after
        :file.close(io)
      end
    end
  end

  @doc """
  Writes `data` to `path`.

  ## Options

    * `:mode` - `:replace` (default) truncates and rewrites the file in place,
      `:append` appends to it, and `:create` creates a new file readable only by
      its owner, failing with `{:error, :eexist}` if the path exists.
    * `:mkdir_p` - create missing parent directories first (default `false`).
  """
  @spec write(Path.t(), iodata(), keyword()) :: :ok | {:error, atom()}
  def write(path, data, opts \\ []) do
    with :ok <- if(Keyword.get(opts, :mkdir_p, false), do: mkdir_p(path), else: :ok) do
      case Keyword.get(opts, :mode, :replace) do
        :replace -> File.write(path, data)
        :append -> File.write(path, data, [:append])
        :create -> create(path, data)
      end
    end
  end

  @doc "Deletes a file. Directories are not removed."
  @spec delete(Path.t()) :: :ok | {:error, atom()}
  def delete(path), do: File.rm(path)

  @doc "Lists the entry names of a directory, following symlinks."
  @spec list(Path.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def list(path), do: File.ls(path)

  @doc "Returns the type, size, and mode of a path, following symlinks."
  @spec stat(Path.t()) ::
          {:ok, %{type: atom(), size: non_neg_integer(), mode: non_neg_integer()}}
          | {:error, atom()}
  def stat(path) do
    with {:ok, %File.Stat{type: type, size: size, mode: mode}} <- File.stat(path) do
      {:ok, %{type: type, size: size, mode: mode}}
    end
  end

  defp mkdir_p(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create(path, data) do
    with {:ok, io} <- :file.open(path, [:write, :exclusive, :raw, :binary]) do
      result =
        with :ok <- File.chmod(path, @private_file_mode) do
          :file.write(io, data)
        end

      case {:file.close(io), result} do
        {:ok, :ok} ->
          :ok

        {_close, error} ->
          File.rm(path)
          if error == :ok, do: {:error, :eio}, else: error
      end
    end
  end
end
