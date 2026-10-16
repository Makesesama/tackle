defmodule Tackle.Review.Change do
  @moduledoc """
  A change to review, loaded from Git.

  Three modes select what is reviewed:

    * `:branch` (default): everything the current branch adds relative to the
      repository's default branch, committed or not. The base is the merge
      base of `HEAD` and the default branch; the head is the working tree.
      Untracked files are not included.
    * `:staged` (`staged: true`): the index against `HEAD` (against the empty
      tree before the first commit).
    * `:range` (`range: "..."`): `base..head` compares two revisions,
      `base...head` compares the merge base of both with `head`, and a single
      revision compares it with the working tree, as `git diff REV` does.
      An empty side of `..`/`...` means `HEAD`.

  The default branch is the `:base` option when given, otherwise the target of
  `origin/HEAD`, then the first of `main`, `master`, `origin/main`, and
  `origin/master` that exists.

  A change holds the diff, with the full text of both sides of every text
  file, which `Tackle.Review.Units` uses to show whole functions (see
  `Tackle.Review.FunctionContext`), and the commits between base and head
  (newest first, at most 100). Paths are relative to the repository root.
  Diffs follow `git diff --histogram` with rename detection.

  ## Reading the repository

  The repository is read in-process with `GixEx` (gitoxide), not with `git`
  subprocesses, and not through the host's tool executor (in the harness,
  `Tackle.Executor`), so a jailed session's review reads the workspace from
  the host. That is
  acceptable because the repository is only read, and read defensively, as
  it may have been written by an agent:

    * `GixEx` opens it isolated: only the repository's own configuration is
      read, and no program it configures runs (filters, `textconv`,
      external diff drivers, hooks), so reading it cannot execute code;
    * a repository whose working tree is configured elsewhere
      (`core.worktree`) is refused, a tracked path below a symbolic link
      counts as deleted, and files are opened without following links, so
      reads stay inside the working tree;
    * the jail mounts the workspace at the same path on the host, so the
      session's working directory names the same checkout;
    * `GixEx` follows the repository's own pointers (a `.git` file, a
      `commondir` file, object alternates, and symbolic links inside the
      Git directory), which a jailed agent could aim at a repository the
      jail hides. A caller with a jailed executor therefore passes its
      workspace as `:workspace`, and `Tackle.Review.Confinement` refuses a
      repository that is not entirely inside it before anything is read;
    * a file larger than `:max_file_bytes` is hashed as a stream and treated
      as binary, which bounds the memory any one file takes.

  Reading cannot be interrupted or given a timeout.
  """

  alias Tackle.Review.{Confinement, Diff}

  @max_commits 100
  @default_max_file_bytes 4 * 1_024 * 1_024
  @branch_candidates ["main", "master", "origin/main", "origin/master"]

  @enforce_keys [:cwd, :root, :mode, :base_sha, :head_sha, :diff]
  defstruct [
    :cwd,
    :root,
    :mode,
    :base_ref,
    :base_sha,
    :head_sha,
    :diff,
    commits: []
  ]

  @typedoc "How the change was selected."
  @type mode :: :branch | :staged | :range

  @typedoc "A commit between base and head."
  @type commit :: %{sha: String.t(), subject: String.t(), body: String.t()}

  @typedoc """
  A loaded change.

  `base_ref` is the name the base was derived from (the default branch, or
  the range's base), or `nil` for staged changes. `base_sha` is a commit, or
  the empty tree for staged changes before the first commit. `head_sha` is a
  commit, or `:worktree`/`:index` when the head is the working tree or the
  index. The files of `diff` carry their contents.
  """
  @type t :: %__MODULE__{
          cwd: Path.t(),
          root: Path.t(),
          mode: mode(),
          base_ref: String.t() | nil,
          base_sha: String.t(),
          head_sha: String.t() | :worktree | :index,
          diff: Diff.t(),
          commits: [commit()]
        }

  @typedoc """
  Load options: `:cwd` (default: the current directory), `:staged`,
  `:range`, `:base` (the default branch for `:branch` mode),
  `:workspace`, the jail workspace the repository must lie in (default:
  none; see "Reading the repository"), and `:max_file_bytes`, the
  size above which a file is treated as binary and not reviewed line by
  line (default 4 MiB).
  """
  @type option ::
          {:cwd, Path.t()}
          | {:workspace, Path.t() | nil}
          | {:staged, boolean()}
          | {:range, String.t()}
          | {:base, String.t()}
          | {:max_file_bytes, pos_integer()}

  @typedoc """
  Why a change could not be loaded. Other `GixEx` errors, such as a
  repository without a working tree or with an external one, are passed
  through.
  """
  @type error ::
          {:not_a_git_repository, Path.t()}
          | :conflicting_options
          | {:invalid_range, String.t()}
          | {:unknown_revision, String.t()}
          | :no_default_branch
          | {:no_merge_base, String.t(), String.t()}
          | {:outside_workspace, Path.t(), Path.t()}
          | {:unsafe_repository, Path.t()}
          | GixEx.error()

  @doc """
  Loads the change selected by `opts` (see the module documentation).

  `staged: true` and `:range` are mutually exclusive.
  """
  @spec load([option()]) :: {:ok, t()} | {:error, error()}
  def load(opts \\ []) do
    cwd = Path.expand(Keyword.get(opts, :cwd) || File.cwd!())
    max_file_bytes = Keyword.get(opts, :max_file_bytes, @default_max_file_bytes)

    with {:ok, mode} <- mode(opts),
         {:ok, repo} <- open(cwd, Keyword.get(opts, :workspace)),
         {:ok, target} <- target(mode, repo, opts),
         {:ok, files} <- diff(repo, target, max_file_bytes),
         {:ok, commits} <- commits(repo, target) do
      {:ok,
       %__MODULE__{
         cwd: cwd,
         root: repo.workdir,
         mode: target.mode,
         base_ref: target.base_ref,
         base_sha: target.base_sha,
         head_sha: target.head_sha,
         diff: %Diff{files: files},
         commits: commits
       }}
    end
  end

  @doc "Formats a load error for people."
  @spec format_error(error()) :: String.t()
  def format_error({:not_a_git_repository, cwd}), do: "#{cwd} is not inside a Git repository"
  def format_error(:conflicting_options), do: "--staged cannot be combined with a range"
  def format_error({:invalid_range, range}), do: "invalid revision range: #{inspect(range)}"
  def format_error({:unknown_revision, rev}), do: "unknown revision: #{rev}"

  def format_error(:no_default_branch),
    do: "could not determine the default branch; pass a base or a range"

  def format_error({:no_merge_base, a, b}), do: "#{a} and #{b} have no common ancestor"

  def format_error({:outside_workspace, _path, _workspace} = reason),
    do: Confinement.format_error(reason)

  def format_error({:unsafe_repository, _path} = reason), do: Confinement.format_error(reason)

  def format_error(reason), do: GixEx.format_error(reason)

  defp mode(opts) do
    case {Keyword.get(opts, :staged, false), Keyword.get(opts, :range)} do
      {true, range} when range != nil -> {:error, :conflicting_options}
      {true, nil} -> {:ok, :staged}
      {_staged, nil} -> {:ok, :branch}
      {_staged, range} -> parse_range(range)
    end
  end

  defp parse_range(range) when is_binary(range) do
    parts =
      cond do
        String.contains?(range, "...") -> {:symmetric, String.split(range, "...", parts: 2)}
        String.contains?(range, "..") -> {:two_dot, String.split(range, "..", parts: 2)}
        true -> {:single, [range]}
      end

    case parts do
      {_kind, [""]} -> {:error, {:invalid_range, range}}
      {_kind, ["", ""]} -> {:error, {:invalid_range, range}}
      {:single, [rev]} -> {:ok, {:range, :single, rev}}
      {kind, [base, head]} -> {:ok, {:range, kind, default_head(base), default_head(head)}}
    end
  end

  defp parse_range(range), do: {:error, {:invalid_range, inspect(range)}}

  defp default_head(""), do: "HEAD"
  defp default_head(rev), do: rev

  # In a jail, the repository is located and checked first, and opened only
  # when `GixEx` finds the same one.
  defp open(cwd, nil), do: open(cwd)

  defp open(cwd, workspace) do
    case Confinement.locate(cwd, workspace) do
      {:ok, located} ->
        with {:ok, repo} <- open(located.workdir), do: same_repository(repo, located, workspace)

      {:error, :not_found} ->
        {:error, {:not_a_git_repository, cwd}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp same_repository(repo, %{workdir: workdir, git_dir: git_dir}, workspace) do
    if repo.workdir == workdir and repo.git_dir == git_dir,
      do: {:ok, repo},
      else: {:error, {:outside_workspace, repo.git_dir, Path.expand(workspace)}}
  end

  # A missing directory is reported like any other directory outside a
  # repository; other failures (a bare repository, an external working
  # tree) keep their reason.
  defp open(cwd) do
    case GixEx.open(cwd) do
      {:ok, %GixEx.Repository{workdir: nil}} ->
        {:error, :bare_repository}

      {:ok, repo} ->
        {:ok, repo}

      {:error, :not_a_repository} ->
        {:error, {:not_a_git_repository, cwd}}

      {:error, reason} ->
        if File.dir?(cwd), do: {:error, reason}, else: {:error, {:not_a_git_repository, cwd}}
    end
  end

  defp target(:branch, repo, opts) do
    with {:ok, head} <- GixEx.resolve(repo, "HEAD"),
         {:ok, base_ref} <- default_branch(repo, Keyword.get(opts, :base)),
         {:ok, base} <- GixEx.resolve(repo, base_ref),
         {:ok, merge_base} <- merge_base(repo, {base_ref, base}, {"HEAD", head}) do
      {:ok, target(:branch, base_ref, merge_base, :worktree, {merge_base, head})}
    end
  end

  defp target(:staged, repo, _opts) do
    case GixEx.resolve(repo, "HEAD") do
      {:ok, head} -> {:ok, target(:staged, nil, head, :index, nil)}
      {:error, {:unknown_revision, _rev}} -> {:ok, staged_before_first_commit(repo)}
      error -> error
    end
  end

  defp target({:range, :single, rev}, repo, _opts) do
    with {:ok, base} <- GixEx.resolve(repo, rev),
         {:ok, head} <- GixEx.resolve(repo, "HEAD") do
      {:ok, target(:range, rev, base, :worktree, {base, head})}
    end
  end

  defp target({:range, kind, base_rev, head_rev}, repo, _opts) do
    with {:ok, base} <- GixEx.resolve(repo, base_rev),
         {:ok, head} <- GixEx.resolve(repo, head_rev),
         {:ok, base} <- range_base(kind, repo, {base_rev, base}, {head_rev, head}) do
      {:ok, target(:range, base_rev, base, head, {base, head})}
    end
  end

  defp target(mode, base_ref, base_sha, head_sha, log_range) do
    %{
      mode: mode,
      base_ref: base_ref,
      base_sha: base_sha,
      from: base_sha,
      head_sha: head_sha,
      log: log_range
    }
  end

  # Without commits, the index is compared with the empty tree.
  defp staged_before_first_commit(repo) do
    %{target(:staged, nil, GixEx.empty_tree(repo), :index, nil) | from: :empty}
  end

  defp range_base(:two_dot, _repo, {_rev, base}, _head), do: {:ok, base}
  defp range_base(:symmetric, repo, base, head), do: merge_base(repo, base, head)

  defp merge_base(repo, {base_rev, base}, {head_rev, head}) do
    case GixEx.merge_base(repo, base, head) do
      {:ok, sha} -> {:ok, sha}
      {:error, :no_merge_base} -> {:error, {:no_merge_base, base_rev, head_rev}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_branch(_repo, base) when is_binary(base), do: {:ok, base}

  defp default_branch(repo, nil) do
    remote_head =
      case GixEx.symbolic_ref(repo, "refs/remotes/origin/HEAD", short: true) do
        {:ok, ref} -> [ref]
        {:error, _reason} -> []
      end

    Enum.find_value(remote_head ++ @branch_candidates, {:error, :no_default_branch}, fn ref ->
      case GixEx.resolve(repo, ref) do
        {:ok, _sha} -> {:ok, ref}
        {:error, _reason} -> nil
      end
    end)
  end

  defp diff(repo, target, max_file_bytes) do
    opts = [contents: true, max_file_bytes: max_file_bytes]

    with {:ok, files} <- GixEx.diff(repo, target.from, target.head_sha, opts) do
      {:ok, Enum.map(files, &file/1)}
    end
  end

  defp file(%GixEx.Diff.File{} = file) do
    %{
      path: file.path,
      old_path: file.old_path,
      status: file.status,
      binary: file.binary,
      additions: file.additions,
      deletions: file.deletions,
      hunks: Enum.map(file.hunks, &hunk/1),
      old_content: file.old_content,
      new_content: file.new_content
    }
  end

  defp hunk(%GixEx.Diff.Hunk{} = hunk) do
    hunk
    |> Map.from_struct()
    |> Map.update!(:lines, fn lines -> Enum.map(lines, &line/1) end)
  end

  defp line(line), do: Map.take(line, [:kind, :old, :new, :text, :no_newline])

  defp commits(_repo, %{log: nil}), do: {:ok, []}
  defp commits(_repo, %{log: {base, base}}), do: {:ok, []}

  defp commits(repo, %{log: {base, head}}) do
    with {:ok, commits} <- GixEx.commits(repo, base, head, limit: @max_commits) do
      {:ok,
       Enum.map(commits, fn commit ->
         %{sha: commit.id, subject: commit.subject, body: String.trim(commit.body)}
       end)}
    end
  end
end
