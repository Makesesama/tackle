defmodule Tackle.Review.Confinement do
  @moduledoc """
  Keeps a review that a jailed session asks for inside the jail's workspace.

  `Tackle.Review.Change` reads repositories on the host with `GixEx`, which
  keeps working-tree reads inside the working tree but, like Git, follows
  the repository's own pointers: a `.git` file (`gitdir: ...`), a
  `commondir` file, object alternates, and symbolic links inside the Git
  directory. A jailed agent can write all of those into its workspace and
  point them at a repository the jail hides, which a `git` running inside
  the jail could not read. `locate/2` therefore finds the repository without
  following links before anything is opened, and refuses one whose working
  tree, Git directory, or common directory lies outside the workspace or is
  reached through a symbolic link, and one whose `HEAD`, `config`, `index`,
  `packed-refs`, `objects`, or `refs` (anywhere below) is a symbolic link or
  that has object alternates.

  Unlike Git, discovery stops at the workspace: a workspace inside a larger
  checkout is not a repository, as it is not for a `git` in the jail.

  Paths are compared as given, so the workspace must be a resolved path (as
  the CLI's jail workspace is); a workspace path through a symbolic link
  matches nothing and every repository is refused. The checks and the read
  that follows are not atomic: a process in the jail that rewrites the Git
  directory while a review loads is not prevented from racing them.
  """

  @max_git_file_bytes 4_096

  # Git data whose target decides which objects and refs are read.
  @git_entries ~w(HEAD config index packed-refs commondir objects objects/info objects/pack refs)

  @typedoc """
  Why a repository was refused: `{:outside_workspace, path, workspace}` for
  a working directory, Git directory, or common directory outside the
  workspace or behind a symbolic link; `{:unsafe_repository, path}` for a
  symbolic link, malformed Git file, or object alternates in the Git data.
  """
  @type error ::
          :not_found
          | {:outside_workspace, Path.t(), Path.t()}
          | {:unsafe_repository, Path.t()}

  @doc """
  Finds the working tree of the repository containing `cwd`, searching up
  to `workspace`, and returns it with its Git directory once every check
  passes. `{:error, :not_found}` when there is no repository in the
  workspace.
  """
  @spec locate(Path.t(), Path.t()) ::
          {:ok, %{workdir: Path.t(), git_dir: Path.t()}} | {:error, error()}
  def locate(cwd, workspace) do
    workspace = Path.expand(workspace)
    cwd = Path.expand(cwd)

    with :ok <- confined(cwd, workspace),
         {:ok, workdir, git_dir} <- find(cwd, workspace),
         :ok <- confined(git_dir, workspace),
         {:ok, common_dir} <- common_dir(git_dir, workspace),
         :ok <- safe_entries(git_dir),
         :ok <- if(common_dir, do: safe_entries(common_dir), else: :ok) do
      {:ok, %{workdir: workdir, git_dir: git_dir}}
    end
  end

  @doc "Formats a refusal for people."
  @spec format_error(error()) :: String.t()
  def format_error(:not_found), do: "no Git repository in the workspace"

  def format_error({:outside_workspace, path, workspace}),
    do: "#{path} lies outside the workspace #{workspace} or is reached through a symbolic link"

  def format_error({:unsafe_repository, path}),
    do:
      "#{path} is a symbolic link, a malformed Git file, or object alternates, " <>
        "which a review in a jail does not follow"

  # `path` is the workspace or below it, with no symbolic link on the way.
  defp confined(path, workspace) do
    if path == workspace or String.starts_with?(path, String.trim_trailing(workspace, "/") <> "/") do
      path
      |> Path.relative_to(workspace)
      |> Path.split()
      |> Enum.reject(&(&1 == "."))
      |> Enum.scan(workspace, &Path.join(&2, &1))
      |> Enum.find(&(type(&1) == :symlink))
      |> case do
        nil -> :ok
        _link -> {:error, {:outside_workspace, path, workspace}}
      end
    else
      {:error, {:outside_workspace, path, workspace}}
    end
  end

  # Searches `.git` from `dir` up to the workspace, without following links.
  defp find(dir, workspace) do
    dot_git = Path.join(dir, ".git")

    case type(dot_git) do
      :directory -> {:ok, dir, dot_git}
      :regular -> git_file(dot_git, dir)
      nil when dir == workspace -> {:error, :not_found}
      nil -> find(Path.dirname(dir), workspace)
      _link_or_other -> {:error, {:unsafe_repository, dot_git}}
    end
  end

  # A `.git` file: `gitdir: PATH`, relative to the directory holding it.
  defp git_file(path, dir) do
    with {:ok, "gitdir: " <> target} <- read_small(path),
         target = String.trim_trailing(target, "\n"),
         git_dir = Path.expand(target, dir),
         :directory <- type(git_dir) do
      {:ok, dir, git_dir}
    else
      _malformed -> {:error, {:unsafe_repository, path}}
    end
  end

  # A linked worktree's `commondir` file names the shared Git directory.
  defp common_dir(git_dir, workspace) do
    path = Path.join(git_dir, "commondir")

    case type(path) do
      nil ->
        {:ok, nil}

      :regular ->
        with {:ok, target} <- read_small(path),
             common = Path.expand(String.trim_trailing(target, "\n"), git_dir),
             :ok <- confined(common, workspace) do
          {:ok, common}
        else
          {:error, {:outside_workspace, _path, _workspace}} = error -> error
          _malformed -> {:error, {:unsafe_repository, path}}
        end

      _link_or_other ->
        {:error, {:unsafe_repository, path}}
    end
  end

  defp safe_entries(git_dir) do
    unsafe =
      Enum.find(@git_entries, &(type(Path.join(git_dir, &1)) == :symlink)) ||
        if(type(Path.join(git_dir, "objects/info/alternates")), do: "objects/info/alternates")

    if unsafe,
      do: {:error, {:unsafe_repository, Path.join(git_dir, unsafe)}},
      else: safe_refs(Path.join(git_dir, "refs"))
  end

  # No symbolic link anywhere below `refs`.
  defp safe_refs(dir) do
    case unsafe_ref(dir) do
      nil -> :ok
      path -> {:error, {:unsafe_repository, path}}
    end
  end

  defp unsafe_ref(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.find_value(names, &unsafe_ref_entry(Path.join(dir, &1)))
      {:error, _reason} -> nil
    end
  end

  defp unsafe_ref_entry(path) do
    case type(path) do
      :symlink -> path
      :directory -> unsafe_ref(path)
      _file -> nil
    end
  end

  defp read_small(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_git_file_bytes ->
        File.read(path)

      _other ->
        :error
    end
  end

  defp type(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} -> type
      {:error, _reason} -> nil
    end
  end
end
