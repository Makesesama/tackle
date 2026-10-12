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

  Besides the parsed diff, a change holds the same diff with function context
  (`git diff -W`), which `Tackle.Review.Units` uses to show whole functions,
  and the commits between base and head (newest first, at most 100). Paths are relative to the repository root.

  Git runs through `Tackle.Review.Git`, hence through the configured executor.
  """

  alias Tackle.Review.{Diff, Git}

  @max_commits 100
  @branch_candidates ["main", "master", "origin/main", "origin/master"]

  @enforce_keys [:cwd, :root, :mode, :base_sha, :head_sha, :diff, :context_diff]
  defstruct [
    :cwd,
    :root,
    :mode,
    :base_ref,
    :base_sha,
    :head_sha,
    :diff,
    :context_diff,
    commits: []
  ]

  @typedoc "How the change was selected."
  @type mode :: :branch | :staged | :range

  @typedoc "A commit between base and head."
  @type commit :: %{sha: String.t(), subject: String.t(), body: String.t()}

  @typedoc """
  A loaded change.

  `base_ref` is the name the base was derived from (the default branch, or
  the range's base), or `nil` for staged changes. `head_sha` is a commit, or
  `:worktree`/`:index` when the head is the working tree or the index.
  """
  @type t :: %__MODULE__{
          cwd: Path.t(),
          root: Path.t(),
          mode: mode(),
          base_ref: String.t() | nil,
          base_sha: String.t(),
          head_sha: String.t() | :worktree | :index,
          diff: Diff.t(),
          context_diff: Diff.t(),
          commits: [commit()]
        }

  @typedoc """
  Load options: `:cwd` (default: the current directory), `:staged`,
  `:range`, `:base` (the default branch for `:branch` mode), and the
  `t:Tackle.Review.Git.option/0` options `:executor`, `:timeout`, and
  `:max_bytes`.
  """
  @type option ::
          {:cwd, Path.t()}
          | {:staged, boolean()}
          | {:range, String.t()}
          | {:base, String.t()}
          | Git.option()

  @typedoc "Why a change could not be loaded."
  @type error ::
          {:not_a_git_repository, Path.t()}
          | :conflicting_options
          | {:invalid_range, String.t()}
          | {:unknown_revision, String.t()}
          | :no_default_branch
          | {:no_merge_base, String.t(), String.t()}
          | Diff.error()
          | Git.error()

  @doc """
  Loads the change selected by `opts` (see the module documentation).

  `staged: true` and `:range` are mutually exclusive.
  """
  @spec load([option()]) :: {:ok, t()} | {:error, error()}
  def load(opts \\ []) do
    cwd = Path.expand(Keyword.get(opts, :cwd) || File.cwd!())
    git_opts = Keyword.take(opts, [:executor, :timeout, :max_bytes])

    with {:ok, mode} <- mode(opts),
         {:ok, root} <- root(cwd, git_opts),
         {:ok, target} <- target(mode, root, opts, git_opts),
         {:ok, diff} <- diff(root, target, [], git_opts),
         {:ok, context_diff} <- diff(root, target, ["--function-context"], git_opts),
         {:ok, commits} <- commits(root, target, git_opts) do
      {:ok,
       %__MODULE__{
         cwd: cwd,
         root: root,
         mode: target.mode,
         base_ref: target.base_ref,
         base_sha: target.base_sha,
         head_sha: target.head_sha,
         diff: diff,
         context_diff: context_diff,
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

  def format_error({:malformed_diff, line, message}),
    do: "could not parse the diff at line #{line}: #{message}"

  def format_error(reason), do: Git.format_error(reason)

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

  defp root(cwd, git_opts) do
    case Git.run(cwd, ["rev-parse", "--show-toplevel"], git_opts) do
      {:ok, output} ->
        {:ok, String.trim_trailing(output, "\n")}

      {:error, {:git_failed, _status, output}} = error ->
        if output =~ "not a git repository",
          do: {:error, {:not_a_git_repository, cwd}},
          else: error

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp target(:branch, root, opts, git_opts) do
    with {:ok, head} <- resolve(root, "HEAD", git_opts),
         {:ok, base_ref} <- default_branch(root, Keyword.get(opts, :base), git_opts),
         {:ok, base} <- resolve(root, base_ref, git_opts),
         {:ok, merge_base} <- merge_base(root, {base_ref, base}, {"HEAD", head}, git_opts) do
      {:ok, target(:branch, base_ref, merge_base, :worktree, {merge_base, head})}
    end
  end

  defp target(:staged, root, _opts, git_opts) do
    case resolve(root, "HEAD", git_opts) do
      {:ok, head} ->
        {:ok, target(:staged, nil, head, :index, nil)}

      {:error, {:unknown_revision, _rev}} ->
        with {:ok, empty_tree} <-
               Git.run(root, ["hash-object", "-t", "tree", "/dev/null"], git_opts) do
          {:ok, target(:staged, nil, String.trim(empty_tree), :index, nil)}
        end

      error ->
        error
    end
  end

  defp target({:range, :single, rev}, root, _opts, git_opts) do
    with {:ok, base} <- resolve(root, rev, git_opts),
         {:ok, head} <- resolve(root, "HEAD", git_opts) do
      {:ok, target(:range, rev, base, :worktree, {base, head})}
    end
  end

  defp target({:range, kind, base_rev, head_rev}, root, _opts, git_opts) do
    with {:ok, base} <- resolve(root, base_rev, git_opts),
         {:ok, head} <- resolve(root, head_rev, git_opts),
         {:ok, base} <- range_base(kind, root, {base_rev, base}, {head_rev, head}, git_opts) do
      {:ok, target(:range, base_rev, base, head, {base, head})}
    end
  end

  defp target(mode, base_ref, base_sha, head_sha, log_range) do
    %{mode: mode, base_ref: base_ref, base_sha: base_sha, head_sha: head_sha, log: log_range}
  end

  defp range_base(:two_dot, _root, {_rev, base}, _head, _git_opts), do: {:ok, base}

  defp range_base(:symmetric, root, base, head, git_opts),
    do: merge_base(root, base, head, git_opts)

  defp resolve(_root, "-" <> _ = rev, _git_opts), do: {:error, {:unknown_revision, rev}}

  defp resolve(root, rev, git_opts) do
    args = ["rev-parse", "--verify", "--quiet", "--end-of-options", rev <> "^{commit}"]

    case Git.run(root, args, git_opts) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, {:git_failed, _status, _output}} -> {:error, {:unknown_revision, rev}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_base(root, {base_rev, base}, {head_rev, head}, git_opts) do
    case Git.run(root, ["merge-base", base, head], git_opts) do
      {:ok, sha} -> {:ok, String.trim(sha)}
      {:error, {:git_failed, 1, _output}} -> {:error, {:no_merge_base, base_rev, head_rev}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_branch(_root, base, _git_opts) when is_binary(base), do: {:ok, base}

  defp default_branch(root, nil, git_opts) do
    remote_head =
      case Git.run(
             root,
             ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
             git_opts
           ) do
        {:ok, ref} -> [String.trim(ref)]
        {:error, _reason} -> []
      end

    Enum.find_value(remote_head ++ @branch_candidates, {:error, :no_default_branch}, fn ref ->
      case resolve(root, ref, git_opts) do
        {:ok, _sha} -> {:ok, ref}
        {:error, _reason} -> nil
      end
    end)
  end

  @diff_args [
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--no-relative",
    "--find-renames",
    "--unified=3",
    "--src-prefix=a/",
    "--dst-prefix=b/"
  ]

  defp diff(root, target, extra, git_opts) do
    revisions =
      case target.head_sha do
        :worktree -> [target.base_sha]
        :index -> ["--cached", target.base_sha]
        head -> [target.base_sha, head]
      end

    with {:ok, text} <-
           Git.diff(root, Enum.concat([@diff_args, extra, revisions, ["--"]]), git_opts) do
      Diff.parse(text)
    end
  end

  defp commits(_root, %{log: nil}, _git_opts), do: {:ok, []}
  defp commits(_root, %{log: {base, base}}, _git_opts), do: {:ok, []}

  defp commits(root, %{log: {base, head}}, git_opts) do
    args = [
      "log",
      "--no-color",
      "--max-count=#{@max_commits}",
      "--format=%H%x1f%s%x1f%b%x1e",
      "#{base}..#{head}",
      "--"
    ]

    with {:ok, output} <- Git.run(root, args, git_opts) do
      {:ok, parse_commits(output)}
    end
  end

  defp parse_commits(output) do
    output
    |> String.split("\x1e")
    |> Enum.map(&String.trim_leading(&1, "\n"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(fn record ->
      case String.split(record, "\x1f", parts: 3) do
        [sha, subject, body] -> [%{sha: sha, subject: subject, body: String.trim(body)}]
        _other -> []
      end
    end)
  end
end
