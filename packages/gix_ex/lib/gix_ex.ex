defmodule GixEx do
  @moduledoc """
  Read-only Git access backed by Rust's [gitoxide](https://github.com/GitoxideLabs/gitoxide).

  Revisions are resolved, histories walked, and diffs computed in-process,
  without a `git` executable. Diffs come back as data (`GixEx.Diff.File`,
  `GixEx.Diff.Hunk`) rather than patch text:

      {:ok, repo} = GixEx.open(".")
      {:ok, base} = GixEx.merge_base(repo, "main", "HEAD")
      {:ok, files} = GixEx.diff(repo, base, :worktree)

  Paths, file contents, and commit messages are returned as binaries; Git
  does not require them to be valid UTF-8.

  ## Untrusted repositories

  A repository is opened isolated: only its own configuration is read, never
  the environment's, the user's, or the system's. No call runs a program the
  repository configures — clean and smudge filters, `textconv`, external
  diff drivers, hooks — so reading a hostile repository does not execute code.
  Working-tree files are therefore compared as they are stored, without
  end-of-line conversion.

  Reading stays inside the working tree: a repository whose working tree is
  configured elsewhere (`core.worktree`) is refused, a tracked path below a
  symbolic link counts as deleted, and only regular files and symbolic links
  are read. When searching upwards, only `.git` directories are recognised,
  so a bare repository committed inside a checkout is not picked up.

  Every call runs on a dirty I/O scheduler and cannot be interrupted. The
  `:max_file_bytes` option of `diff/4` bounds the memory a diff uses for any
  one file, including working-tree files, which are hashed as a stream when
  they are larger.
  """

  alias GixEx.{Commit, Native, Repository}
  alias GixEx.Diff.File

  @typedoc "Why a call failed."
  @type error ::
          :not_a_repository
          | :bare_repository
          | :external_worktree
          | {:unknown_revision, String.t()}
          | :no_merge_base
          | {:reference_not_found, String.t()}
          | {:not_symbolic, String.t()}
          | {:git, String.t()}

  @typedoc """
  The old side of a diff: a revision (anything `git rev-parse` accepts that
  names a commit or tree) or `:empty` for the empty tree.
  """
  @type from :: String.t() | :empty

  @typedoc """
  The new side of a diff: a revision, `:empty`, `:index` for the staging area,
  or `:worktree` for the tracked files in the working tree, as `git diff REV`
  compares them. Untracked files are not part of the working tree, and a
  submodule is compared by the commit recorded in the index rather than by
  its checkout. An unmerged path is reported with status `:unmerged` against
  `:index`, and with its conflict markers against `:worktree`, as Git does.
  """
  @type to :: String.t() | :empty | :index | :worktree

  @typedoc """
  Diff options:

    * `:context` - unchanged lines around each change (default 3).
    * `:renames` - minimum similarity, from `0.0` to `1.0`, for a deleted and
      an added file to be reported as a rename (default `0.5`, Git's
      `--find-renames`), or `false` to disable rename detection.
    * `:algorithm` - `:histogram` (default) or `:myers`. Histogram output is
      identical to `git diff --histogram`. Myers is Git's default algorithm,
      but this implementation is not Git's and aligns some changes
      differently.
    * `:contents` - include the full text of both sides of each file
      (default `false`).
    * `:max_file_bytes` - files larger than this are treated as binary and
      not read into memory (default 16 MiB).
  """
  @type diff_option ::
          {:context, non_neg_integer()}
          | {:renames, float() | false}
          | {:algorithm, :myers | :histogram}
          | {:contents, boolean()}
          | {:max_file_bytes, pos_integer()}

  @default_max_file_bytes 16 * 1024 * 1024

  @doc """
  Opens the repository containing `path`, searching upwards for a `.git`
  directory, or the repository directory `path` itself (such as a bare
  repository).

  Returns `{:error, :not_a_repository}` when no repository is found, and
  `{:error, :external_worktree}` when the repository configures its working
  tree outside the directory that holds it.
  """
  @spec open(Path.t()) :: {:ok, Repository.t()} | {:error, error()}
  def open(path) when is_binary(path) or is_list(path) do
    with {:ok, {ref, workdir, git_dir}} <- Native.open(Path.expand(path)) do
      {:ok, %Repository{ref: ref, workdir: workdir, git_dir: git_dir}}
    end
  end

  @doc """
  Resolves `rev` to the full id of the commit it names, as
  `git rev-parse --verify rev^{commit}` does.
  """
  @spec resolve(Repository.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def resolve(%Repository{ref: ref}, rev) when is_binary(rev), do: Native.resolve(ref, rev)

  @doc """
  Returns the best common ancestor of two revisions, or
  `{:error, :no_merge_base}` when their histories are unrelated.
  """
  @spec merge_base(Repository.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, error()}
  def merge_base(%Repository{ref: ref}, one, two) when is_binary(one) and is_binary(two),
    do: Native.merge_base(ref, one, two)

  @doc """
  Returns the reference a symbolic reference points at.

  The full name is returned (`refs/remotes/origin/main`); with `short: true`,
  the name `git symbolic-ref --short` prints (`origin/main`).
  """
  @spec symbolic_ref(Repository.t(), String.t(), short: boolean()) ::
          {:ok, binary()} | {:error, error()}
  def symbolic_ref(%Repository{ref: ref}, name, opts \\ []) when is_binary(name) do
    short? = Keyword.validate!(opts, short: false)[:short]

    with {:ok, {full, short}} <- Native.symbolic_ref(ref, name) do
      {:ok, if(short?, do: short, else: full)}
    end
  end

  @doc "Returns the id of the empty tree in the repository's hash format."
  @spec empty_tree(Repository.t()) :: String.t()
  def empty_tree(%Repository{ref: ref}), do: Native.empty_tree(ref)

  @doc """
  Lists the commits reachable from `head` but not from `base`, newest first,
  as `git log base..head` does. A `nil` base lists the whole history.

  Options: `:limit`, the maximum number of commits (default: no limit).
  """
  @spec commits(Repository.t(), String.t() | nil, String.t(), limit: pos_integer()) ::
          {:ok, [Commit.t()]} | {:error, error()}
  def commits(%Repository{ref: ref}, base, head, opts \\ [])
      when (is_binary(base) or is_nil(base)) and is_binary(head) do
    limit = Keyword.validate!(opts, limit: nil)[:limit]

    unless is_nil(limit) or (is_integer(limit) and limit > 0) do
      raise ArgumentError, "expected :limit to be a positive integer, got: #{inspect(limit)}"
    end

    Native.commits(ref, base, head, limit)
  end

  @doc """
  Computes the changes from `from` to `to`, sorted by path.

  See `t:from/0`, `t:to/0`, and `t:diff_option/0`. Renames are detected
  between the two sides; copies are not. Similarity is scored differently
  from Git, so a pair near the threshold may be a rename in one and a deletion
  plus an addition in the other.
  """
  @spec diff(Repository.t(), from(), to(), [diff_option()]) ::
          {:ok, [File.t()]} | {:error, error()}
  def diff(%Repository{ref: ref}, from, to, opts \\ []) do
    Native.diff(ref, side(from, [:empty]), side(to, [:empty, :index, :worktree]), options(opts))
  end

  @doc "Formats an error for people."
  @spec format_error(error()) :: String.t()
  def format_error(:not_a_repository), do: "not a git repository"
  def format_error(:bare_repository), do: "the repository has no working tree"

  def format_error(:external_worktree),
    do: "the repository's working tree is configured outside it (core.worktree)"

  def format_error({:unknown_revision, rev}), do: "unknown revision: #{rev}"
  def format_error(:no_merge_base), do: "the revisions have no common ancestor"
  def format_error({:reference_not_found, name}), do: "reference not found: #{name}"
  def format_error({:not_symbolic, name}), do: "not a symbolic reference: #{name}"
  def format_error({:git, message}), do: message

  defp side(rev, _atoms) when is_binary(rev), do: {:rev, rev}

  defp side(side, atoms) when is_atom(side) do
    if side in atoms do
      side
    else
      raise ArgumentError,
            "expected a revision or one of #{inspect(atoms)}, got: #{inspect(side)}"
    end
  end

  defp side(side, atoms) do
    raise ArgumentError, "expected a revision or one of #{inspect(atoms)}, got: #{inspect(side)}"
  end

  defp options(opts) do
    opts =
      Keyword.validate!(opts,
        context: 3,
        renames: 0.5,
        algorithm: :histogram,
        contents: false,
        max_file_bytes: @default_max_file_bytes
      )

    %{
      context: validate(opts, :context, &(is_integer(&1) and &1 >= 0)),
      renames: renames(opts[:renames]),
      algorithm: validate(opts, :algorithm, &(&1 in [:myers, :histogram])),
      contents: validate(opts, :contents, &is_boolean/1),
      max_file_bytes: validate(opts, :max_file_bytes, &(is_integer(&1) and &1 > 0))
    }
  end

  defp renames(false), do: nil

  defp renames(similarity) when is_number(similarity) and similarity >= 0 and similarity <= 1,
    do: similarity / 1

  defp renames(other) do
    raise ArgumentError,
          "expected :renames to be a similarity from 0.0 to 1.0 or false, got: #{inspect(other)}"
  end

  defp validate(opts, key, valid?) do
    value = Keyword.fetch!(opts, key)

    if valid?.(value) do
      value
    else
      raise ArgumentError, "invalid value for #{inspect(key)}: #{inspect(value)}"
    end
  end
end
