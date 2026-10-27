defmodule Tackle.ProjectFiles do
  @moduledoc """
  Host-side access to project files such as `AGENTS.md`, `.agents/skills`,
  `.tackle/agents`, `.tackle/config.json`, and saved workflows.

  The harness accesses these files itself, outside the agent's tools. With a jailed
  executor, jailed code can write anywhere in the workspace, so a path inside
  the workspace could be a symlink planted to a host file such as
  `~/.tackle/auth.json`. Paths inside the workspace are therefore accessed through
  the session's executor: with `Tackle.Executor.Jailed` they resolve in the
  jail's view of the filesystem, where such host files do not exist.

  The workspace is the directory the executor mounts
  (`c:Tackle.Executor.workspace/1`), which may contain the agent's working
  directory. Paths outside it (its parent directories, `~/.agents`, and
  `$TACKLE_HOME`) are not writable from the jail and are accessed locally.
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

  @doc """
  Writes a file through the same routing as reads.

  Options are executor write options: `:mode` (`:replace`, `:append`, or
  exclusive `:create`) and `:mkdir_p` to create parent directories.
  """
  @spec write(t(), Path.t(), binary(), keyword()) :: :ok | {:error, Executor.reason()}
  def write(files, path, data, opts \\ []),
    do: files |> executor_for(path) |> Executor.write(path, data, opts)

  @doc """
  Finds the nearest existing project directory at or above `cwd`.

  `relative_dir` is relative to each ancestor (for example `.tackle/agents`).
  The search includes, but never passes, the nearest ancestor containing `.git`;
  without one it stops at the filesystem root. All probes use this router.
  """
  @spec nearest_project_dir(t(), Path.t(), Path.t()) :: Path.t() | nil
  def nearest_project_dir(files, cwd, relative_dir),
    do: nearest_project_path(files, cwd, relative_dir, &dir?/2)

  @doc """
  Finds the nearest existing regular file at `relative_path` at or above `cwd`
  (for example `.tackle/config.json`), with the same search bounds as
  `nearest_project_dir/3`.
  """
  @spec nearest_project_file(t(), Path.t(), Path.t()) :: Path.t() | nil
  def nearest_project_file(files, cwd, relative_path),
    do: nearest_project_path(files, cwd, relative_path, &regular?/2)

  defp nearest_project_path(files, cwd, relative_path, found?) do
    cwd = Path.expand(cwd)
    nearest_path(files, cwd, relative_path, found?, git_root(files, cwd))
  end

  defp nearest_path(files, dir, relative_path, found?, boundary) do
    candidate = Path.join(dir, relative_path)
    parent = Path.dirname(dir)

    cond do
      found?.(files, candidate) -> candidate
      dir == parent or dir == boundary -> nil
      true -> nearest_path(files, parent, relative_path, found?, boundary)
    end
  end

  @doc """
  Returns the nearest directory at or above `dir` containing `.git`, or `nil`
  outside a Git repository. All probes use this router.
  """
  @spec git_root(t(), Path.t()) :: Path.t() | nil
  def git_root(files, dir), do: find_git_root(files, Path.expand(dir))

  defp find_git_root(files, dir) do
    parent = Path.dirname(dir)

    cond do
      exists?(files, Path.join(dir, ".git")) -> dir
      dir == parent -> nil
      true -> find_git_root(files, parent)
    end
  end

  @doc """
  Returns whether two paths name the same directory, by expanded path or by
  file identity on the host.

  Outside a Git repository the project search can reach `$TACKLE_HOME` itself
  (`~/.tackle`), whose files are the user's, not a project's. Comparing
  identity as well as text also recognises a symlinked home directory
  (`/home` -> `/var/home`).
  """
  @spec same_dir?(Path.t(), Path.t()) :: boolean()
  def same_dir?(a, b) do
    Path.expand(a) == Path.expand(b) or
      case {File.stat(a), File.stat(b)} do
        {{:ok, x}, {:ok, y}} ->
          {x.major_device, x.minor_device, x.inode} == {y.major_device, y.minor_device, y.inode}

        _ ->
          false
      end
  end

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
  explode; a truncated walk logs a warning and still returns the files
  already listed.
  """
  @spec walk(t(), Path.t(), (Path.t() -> [{:file | :dir, Path.t()}])) :: [Path.t()]
  def walk(%__MODULE__{}, root, visit) when is_function(visit, 1),
    do: walk([{:dir, root}], visit, @max_walk_dirs, root, [])

  defp walk([], _visit, _budget, _root, found), do: Enum.reverse(found)

  defp walk([{:file, path} | rest], visit, budget, root, found),
    do: walk(rest, visit, budget, root, [path | found])

  defp walk([{:dir, _path} | _rest] = pending, _visit, 0, root, found) do
    Logger.warning("stopped walking #{root} after #{@max_walk_dirs} directories")
    Enum.reverse(found, for({:file, path} <- pending, do: path))
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
