defmodule Tackle.ProjectFiles do
  @moduledoc """
  Host-side access to project files such as `AGENTS.md`, `.agents/skills`, and
  `.tackle/agents`.

  The harness reads these files itself, outside the agent's tools. With a jailed
  executor, jailed code can write anywhere in the workspace, so a path inside
  the workspace could be a symlink planted to a host file such as
  `~/.tackle/auth.json`. Paths inside the workspace are therefore read through
  the session's executor: with `Tackle.Executor.Jailed` they resolve in the
  jail's view of the filesystem, where such host files do not exist.

  The workspace is the directory the executor mounts
  (`c:Tackle.Executor.workspace/1`), which may contain the agent's working
  directory. Paths outside it (its parent directories, `~/.agents`, and
  `$TACKLE_HOME`) are not writable from the jail and are read locally.
  """

  alias Tackle.Executor

  require Logger

  # Project files are small text. The executor may be hostile, so bound what
  # one read or one directory walk can make the host hold.
  @max_file_bytes 1_024 * 1_024
  @max_walk_dirs 256
  @max_dir_entries 1_000

  @enforce_keys [:executor, :workspace]
  defstruct [:executor, :workspace]

  @typedoc "Routes project file access between the session executor and the host."
  @type t :: %__MODULE__{executor: Executor.t(), workspace: Path.t() | nil}

  @doc """
  Creates a router for an executor (default: the local executor).

  Paths inside the executor's `c:Tackle.Executor.workspace/1` are read through
  it; everything else is read locally.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    executor = Keyword.get(opts, :executor) || Executor.local()
    %__MODULE__{executor: executor, workspace: Executor.workspace(executor)}
  end

  @doc "Reads a whole file of at most 1 MiB; larger files return `{:error, :too_large}`."
  @spec read(t(), Path.t()) :: {:ok, binary()} | {:error, Executor.reason()}
  def read(files, path),
    do: files |> executor_for(path) |> Executor.read_file(path, @max_file_bytes)

  @doc "Returns the type of a path, following symlinks."
  @spec type(t(), Path.t()) :: {:ok, atom()} | {:error, Executor.reason()}
  def type(files, path) do
    with {:ok, %{type: type}} <- files |> executor_for(path) |> Executor.stat(path) do
      {:ok, type}
    end
  end

  @doc """
  Lists the entry names of a directory, sorted, keeping at most the first
  1,000.
  """
  @spec list(t(), Path.t()) :: {:ok, [String.t()]} | {:error, Executor.reason()}
  def list(files, path) do
    with {:ok, names} <- files |> executor_for(path) |> Executor.list(path) do
      {:ok, names |> Enum.sort() |> Enum.take(@max_dir_entries)}
    end
  end

  @doc """
  Walks a directory tree depth-first and returns the files it selects, in
  order.

  `visit` receives a directory and returns its ordered contents to keep, each
  `{:file, path}` (returned) or `{:dir, path}` (visited next). At most 256
  directories are visited, so symlinked directory loops cannot make the walk
  explode; a truncated walk logs a warning.
  """
  @spec walk(t(), Path.t(), (Path.t() -> [{:file | :dir, Path.t()}])) :: [Path.t()]
  def walk(%__MODULE__{}, root, visit) when is_function(visit, 1),
    do: walk([{:dir, root}], visit, @max_walk_dirs, root, [])

  defp walk([], _visit, _budget, _root, found), do: Enum.reverse(found)

  defp walk([{:file, path} | rest], visit, budget, root, found),
    do: walk(rest, visit, budget, root, [path | found])

  defp walk([{:dir, _path} | _rest], _visit, 0, root, found) do
    Logger.warning("stopped walking #{root} after #{@max_walk_dirs} directories")
    Enum.reverse(found)
  end

  defp walk([{:dir, path} | rest], visit, budget, root, found),
    do: walk(visit.(path) ++ rest, visit, budget - 1, root, found)

  @doc "Returns whether a path is a regular file."
  @spec regular?(t(), Path.t()) :: boolean()
  def regular?(files, path), do: type(files, path) == {:ok, :regular}

  @doc "Returns whether a path is a directory."
  @spec dir?(t(), Path.t()) :: boolean()
  def dir?(files, path), do: type(files, path) == {:ok, :directory}

  @doc "Returns whether a path exists."
  @spec exists?(t(), Path.t()) :: boolean()
  def exists?(files, path), do: match?({:ok, _type}, type(files, path))

  @doc "Returns whether a path is the workspace or inside it."
  @spec in_workspace?(t(), Path.t()) :: boolean()
  def in_workspace?(%__MODULE__{workspace: nil}, _path), do: false
  def in_workspace?(%__MODULE__{workspace: "/"}, _path), do: true

  def in_workspace?(%__MODULE__{workspace: workspace}, path) do
    path = Path.expand(path)
    path == workspace or String.starts_with?(path, workspace <> "/")
  end

  defp executor_for(files, path) do
    if in_workspace?(files, path), do: files.executor, else: Executor.local()
  end
end
