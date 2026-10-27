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

  Project discovery searches the working directory and its ancestors, up to
  the nearest Git root. Without one it stops at the user's home directory
  (inclusive) when the working directory is under it, and searches only the
  working directory otherwise, so directories other users can write, such as
  `/tmp`, are never searched on behalf of a project below them.
  """

  alias Tackle.{Executor, Paths}

  require Logger

  # Project files are small text. The executor may be hostile, so bound what
  # one read or one directory walk can make the host hold.
  @max_file_bytes 1_024 * 1_024
  @max_walk_dirs 256
  @max_dir_entries 1_000

  @max_symlinks 40

  @enforce_keys [:executor, :workspace, :real_workspace, :user_home]
  defstruct [:executor, :workspace, :real_workspace, :user_home]

  @typedoc "Routes project file access between the session executor and the host."
  @type t :: %__MODULE__{
          executor: Executor.t(),
          workspace: Path.t() | nil,
          real_workspace: Path.t() | nil,
          user_home: Path.t() | nil
        }

  @doc """
  Creates a router for an executor (default: the local executor).

  Paths inside the executor's `c:Tackle.Executor.workspace/1` are read through
  it; everything else is read locally (see the module documentation).

  Options:

    * `:executor` - the session executor;
    * `:user_home` and `:env` - select the user's home directory that bounds
      project discovery outside a Git repository (see `Tackle.Paths.user_home/1`).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    executor = Keyword.get(opts, :executor) || Executor.local()
    workspace = Executor.workspace(executor)

    %__MODULE__{
      executor: executor,
      workspace: workspace,
      real_workspace: workspace && host_realpath(workspace),
      user_home: opts |> Keyword.take([:user_home, :env]) |> Paths.user_home()
    }
  end

  @doc """
  Reads a whole file of at most 1 MiB; larger files return `{:error, :too_large}`
  without being read further.

  Options:

    * `:max_bytes` - a lower limit than 1 MiB, for callers that reject larger
      files anyway.
  """
  @spec read(t(), Path.t(), max_bytes: pos_integer()) ::
          {:ok, binary()} | {:error, Executor.reason()}
  def read(files, path, opts \\ []) do
    max_bytes =
      case Keyword.get(opts, :max_bytes, @max_file_bytes) do
        max when is_integer(max) and max > 0 ->
          min(max, @max_file_bytes)

        other ->
          raise ArgumentError, ":max_bytes must be a positive integer, got: #{inspect(other)}"
      end

    with {:ok, executor, path} <- route(files, path),
         do: Executor.read_file(executor, path, max_bytes)
  end

  @doc """
  Reads a text file as `read/3` does; contents that are not valid UTF-8 are
  `{:error, :invalid_utf8}`.
  """
  @spec read_text(t(), Path.t(), max_bytes: pos_integer()) ::
          {:ok, String.t()} | {:error, :invalid_utf8 | Executor.reason()}
  def read_text(files, path, opts \\ []) do
    with {:ok, contents} <- read(files, path, opts) do
      if String.valid?(contents), do: {:ok, contents}, else: {:error, :invalid_utf8}
    end
  end

  @doc "Describes an error of `read_text/3` or `list_files/3` for a warning or message."
  @spec format_error(:invalid_utf8 | Executor.reason()) :: String.t()
  def format_error(:invalid_utf8), do: "file is not valid UTF-8"
  def format_error(reason), do: Executor.format_reason(reason)

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

  `relative_dir` is relative to each directory `ancestors/3` returns (for
  example `.tackle/agents`). All probes use this router.
  """
  @spec nearest_project_dir(t(), Path.t(), Path.t()) :: Path.t() | nil
  def nearest_project_dir(files, cwd, relative_dir),
    do: nearest(files, cwd, relative_dir, &dir?/2)

  @doc """
  Finds the nearest existing regular file at `relative_path` at or above `cwd`
  (for example `.tackle/config.json`), with the same search bounds as
  `nearest_project_dir/3`.
  """
  @spec nearest_project_file(t(), Path.t(), Path.t()) :: Path.t() | nil
  def nearest_project_file(files, cwd, relative_path),
    do: nearest(files, cwd, relative_path, &regular?/2)

  defp nearest(files, cwd, relative_path, found?) do
    files
    |> ancestors(cwd)
    |> Enum.map(&Path.join(&1, relative_path))
    |> Enum.find(&found?.(files, &1))
  end

  @doc """
  Returns the user directory `<tackle_home>/<sub>` and the nearest existing
  project directory `.tackle/<sub>`, lowest precedence first, as
  `{:user, dir}` and `{:project, dir}`.

  The user directory is returned whether or not it exists, and is left out
  when `tackle_home` is `nil`. A `.tackle` directory that is `tackle_home`
  itself is not a project's: the search can reach `~/.tackle` from a
  directory under the home directory.
  """
  @spec tackle_dirs(t(), Path.t(), Path.t() | nil, Path.t()) :: [{:user | :project, Path.t()}]
  def tackle_dirs(files, cwd, tackle_home, sub) do
    user = if tackle_home, do: {:user, Path.join(tackle_home, sub)}
    project = project_tackle_path(files, cwd, tackle_home, sub, &dir?/2)
    Enum.reject([user, project && {:project, project}], &is_nil/1)
  end

  @doc """
  Finds the nearest existing regular file `.tackle/<relative_path>` of the
  project, skipping `tackle_home` as `tackle_dirs/4` does.
  """
  @spec project_tackle_file(t(), Path.t(), Path.t() | nil, Path.t()) :: Path.t() | nil
  def project_tackle_file(files, cwd, tackle_home, relative_path),
    do: project_tackle_path(files, cwd, tackle_home, relative_path, &regular?/2)

  defp project_tackle_path(files, cwd, tackle_home, relative_path, found?) do
    files
    |> ancestors(cwd)
    |> Enum.map(&Path.join(&1, ".tackle"))
    |> Enum.reject(&(is_binary(tackle_home) and same_dir?(&1, tackle_home)))
    |> Enum.map(&Path.join(&1, relative_path))
    |> Enum.find(&found?.(files, &1))
  end

  @doc """
  Returns `cwd` and the ancestors project discovery searches, nearest first:
  up to the nearest Git root; without one, up to the user's home directory
  when `cwd` is under it; otherwise only `cwd`.

  With `beyond_git_root: true`, a `cwd` under the home directory is searched
  up to the home directory even when its Git root is below it, as for
  `AGENTS.md` files.
  """
  @spec ancestors(t(), Path.t(), keyword()) :: [Path.t()]
  def ancestors(files, cwd, opts \\ []) do
    cwd = Path.expand(cwd)
    home = home_containing(files, cwd)

    top =
      case {git_root(files, cwd), home} do
        {nil, nil} ->
          cwd

        {nil, home} ->
          home

        {root, nil} ->
          root

        {root, home} ->
          if Keyword.get(opts, :beyond_git_root, false), do: higher(root, home), else: root
      end

    up_to(cwd, top, [])
  end

  # Both are ancestors of the same directory, so the shorter is the higher.
  defp higher(a, b), do: if(byte_size(a) <= byte_size(b), do: a, else: b)

  defp up_to(dir, top, acc) do
    parent = Path.dirname(dir)

    if dir == top or dir == parent,
      do: Enum.reverse([dir | acc]),
      else: up_to(parent, top, [dir | acc])
  end

  # The home directory as a prefix of `cwd`, by text or after resolving its
  # symlinks (`/home` -> `/var/home`), or nil.
  defp home_containing(%__MODULE__{user_home: nil}, _cwd), do: nil

  defp home_containing(%__MODULE__{user_home: home}, cwd) do
    home = Path.expand(home)
    Enum.find([home, host_realpath(home)], &contains?(&1, cwd))
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

  Comparing identity as well as text also recognises a symlinked home
  directory (`/home` -> `/var/home`).
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
  Lists the regular files directly in `dir` whose names end in `extension`
  (such as `".md"`), as sorted paths; see `list/2` for the entry limit.
  """
  @spec list_files(t(), Path.t(), String.t()) :: {:ok, [Path.t()]} | {:error, Executor.reason()}
  def list_files(files, dir, extension) do
    with {:ok, names} <- list(files, dir) do
      {:ok,
       for(
         name <- names,
         String.ends_with?(name, extension),
         path = Path.join(dir, name),
         regular?(files, path),
         do: path
       )}
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
