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
  `$TACKLE_HOME`) are not writable from the jail and are accessed locally, but
  they may be symlinks into the workspace, such as a user skill linked to a
  repository's copy. Such a path is resolved on the host, one component at a
  time: once a resolved prefix lands inside the workspace, the rest of the
  path goes through the executor, so no symlink the jail can change is ever
  followed on the host. Writes route the same way.
  """

  alias Tackle.Executor

  require Logger

  # Project files are small text. The executor may be hostile, so bound what
  # one read or one directory walk can make the host hold.
  @max_file_bytes 1_024 * 1_024
  @max_walk_dirs 256
  @max_dir_entries 1_000

  @max_symlinks 40

  @enforce_keys [:executor, :workspace, :real_workspace]
  defstruct [:executor, :workspace, :real_workspace]

  @typedoc "Routes project file access between the session executor and the host."
  @type t :: %__MODULE__{
          executor: Executor.t(),
          workspace: Path.t() | nil,
          real_workspace: Path.t() | nil
        }

  @doc """
  Creates a router for an executor (default: the local executor).

  Paths inside the executor's `c:Tackle.Executor.workspace/1` are read through
  it; everything else is read locally (see the module documentation).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    executor = Keyword.get(opts, :executor) || Executor.local()
    workspace = Executor.workspace(executor)

    %__MODULE__{
      executor: executor,
      workspace: workspace,
      real_workspace: workspace && host_realpath(workspace)
    }
  end

  @doc "Reads a whole file of at most 1 MiB; larger files return `{:error, :too_large}`."
  @spec read(t(), Path.t()) :: {:ok, binary()} | {:error, Executor.reason()}
  def read(files, path) do
    with {:ok, executor, path} <- route(files, path),
         do: Executor.read_file(executor, path, @max_file_bytes)
  end

  @doc """
  Writes a file through the same routing as reads.

  Options are executor write options: `:mode` (`:replace`, `:append`, or
  exclusive `:create`) and `:mkdir_p` to create parent directories.
  """
  @spec write(t(), Path.t(), binary(), keyword()) :: :ok | {:error, Executor.reason()}
  def write(files, path, data, opts \\ []) do
    with {:ok, executor, path} <- route(files, path),
         do: Executor.write(executor, path, data, opts)
  end

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
    with {:ok, executor, path} <- route(files, path),
         {:ok, %{type: type}} <- Executor.stat(executor, path) do
      {:ok, type}
    end
  end

  @doc """
  Lists the entry names of a directory, sorted, keeping at most the first
  1,000.
  """
  @spec list(t(), Path.t()) :: {:ok, [String.t()]} | {:error, Executor.reason()}
  def list(files, path) do
    with {:ok, executor, path} <- route(files, path),
         {:ok, names} <- Executor.list(executor, path) do
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

  @doc """
  Returns whether a path is the workspace or inside it, by its text.

  Routing also follows host symlinks (see the module documentation); this
  check does not.
  """
  @spec in_workspace?(t(), Path.t()) :: boolean()
  def in_workspace?(%__MODULE__{workspace: nil}, _path), do: false

  def in_workspace?(%__MODULE__{workspace: workspace}, path),
    do: contains?(workspace, Path.expand(path))

  # Returns the executor for a path and the path to give it. Without a
  # workspace the executor sees the host, so the host reads everything.
  defp route(%__MODULE__{workspace: nil}, path), do: {:ok, Executor.local(), path}

  defp route(files, path) do
    path = Path.expand(path)

    if in_workspace?(files, path),
      do: {:ok, files.executor, path},
      else: resolve(files, Path.split(path), "/", 0)
  end

  # Resolves a host path one component at a time, following its symlinks.
  # `resolved` holds no symlinks; once it is inside the workspace, the rest of
  # the path is the executor's to resolve, so no symlink the jail controls is
  # followed on the host.
  defp resolve(_files, _parts, _resolved, links) when links > @max_symlinks,
    do: {:error, :eloop}

  defp resolve(files, parts, resolved, links) do
    case workspace_path(files, resolved) do
      {:ok, inside} -> {:ok, files.executor, Path.join([inside | parts])}
      :error -> resolve_next(files, parts, resolved, links)
    end
  end

  defp resolve_next(_files, [], resolved, _links), do: {:ok, Executor.local(), resolved}
  defp resolve_next(files, ["/" | rest], _resolved, links), do: resolve(files, rest, "/", links)

  defp resolve_next(files, ["." | rest], resolved, links),
    do: resolve(files, rest, resolved, links)

  defp resolve_next(files, [".." | rest], resolved, links),
    do: resolve(files, rest, Path.dirname(resolved), links)

  defp resolve_next(files, [part | rest], resolved, links) do
    candidate = Path.join(resolved, part)

    case File.read_link(candidate) do
      {:ok, target} -> resolve(files, Path.split(target) ++ rest, resolved, links + 1)
      {:error, _reason} -> resolve(files, rest, candidate, links)
    end
  end

  # A path inside the workspace, given by text or through the workspace's
  # resolved location, as the executor names it.
  defp workspace_path(nil, _path), do: :error

  defp workspace_path(%__MODULE__{workspace: workspace, real_workspace: real} = files, path) do
    cond do
      in_workspace?(files, path) ->
        {:ok, path}

      is_binary(real) and contains?(real, path) ->
        {:ok,
         Path.join(workspace, path |> String.replace_prefix(real, "") |> String.trim_leading("/"))}

      true ->
        :error
    end
  end

  # Resolves every symlink of a host path; a symlink loop leaves it as given.
  defp host_realpath(path) do
    path = Path.expand(path)

    case resolve(nil, Path.split(path), "/", 0) do
      {:ok, _executor, resolved} -> resolved
      {:error, :eloop} -> path
    end
  end

  defp contains?("/", _path), do: true
  defp contains?(dir, path), do: path == dir or String.starts_with?(path, dir <> "/")
end
