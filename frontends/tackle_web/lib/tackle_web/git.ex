defmodule Tackle.Web.Git do
  @moduledoc """
  Read-only git access for the review UI.

  Commands run through `Git.Config`, whose default runner is forcola: git and
  every process it spawns (hooks, credential helpers, transports) runs in its
  own process group, which is killed when the timeout fires. A stuck command
  therefore cannot leave a git process behind holding `.git/index.lock`.
  """

  # A local diff of a large repository is the slowest thing the UI asks for.
  @timeout_ms 30_000

  @type repo :: Path.t()

  @type loaded :: %{
          base_sha: String.t(),
          head_sha: String.t(),
          patch: String.t()
        }

  @doc """
  Checks that `repo` is a path inside a git work tree.
  """
  @spec validate(repo) :: :ok | {:error, String.t()}
  def validate(repo) do
    case Git.rev_parse(show_toplevel: true, config: config(repo)) do
      {:ok, _top_level} -> :ok
      {:error, _reason} -> {:error, "#{repo} is not a git repository"}
    end
  end

  @doc """
  Loads the patch that `head` introduces relative to `base`.

  The patch is taken from the merge base of the two refs, which is what GitHub's
  "Files changed" tab shows: commits that landed on `base` independently of
  `head` are not part of the diff.
  """
  @spec load(repo, String.t(), String.t()) :: {:ok, loaded} | {:error, String.t()}
  def load(repo, base, head) do
    with :ok <- validate(repo),
         {:ok, base_sha} <- resolve(repo, base),
         {:ok, head_sha} <- resolve(repo, head) do
      from = merge_base(repo, base_sha, head_sha)

      case Git.diff(ref: from, ref_end: head_sha, config: config(repo)) do
        {:ok, %Git.Diff{raw: patch}} ->
          {:ok, %{base_sha: from, head_sha: head_sha, patch: patch}}

        {:error, reason} ->
          {:error, describe(reason)}
      end
    end
  end

  @doc """
  Returns true when `repo` is a path inside a git work tree.
  """
  @spec valid_repo?(repo) :: boolean()
  def valid_repo?(repo), do: validate(repo) == :ok

  @doc """
  Reads the blob at `ref:path`.

  Returns `:error` when the path does not exist in that tree, which is the
  normal case for the base side of an added file and the head side of a deleted
  one.
  """
  @spec blob(repo, String.t(), Path.t()) :: {:ok, binary()} | :error
  def blob(repo, ref, path) do
    case Git.cat_file("#{ref}:#{path}", config: config(repo)) do
      {:ok, content} when is_binary(content) -> {:ok, content}
      _error -> :error
    end
  end

  defp resolve(repo, ref) do
    case Git.rev_parse(ref: ref, config: config(repo)) do
      {:ok, sha} -> {:ok, sha}
      {:error, reason} -> {:error, "unknown revision #{inspect(ref)}: #{describe(reason)}"}
    end
  end

  # Refuse to fold the closest common ancestor into the diff. Unrelated
  # histories have none, and diffing from `base` is then the only option.
  defp merge_base(repo, base_sha, head_sha) do
    case Git.merge_base(commits: [base_sha, head_sha], config: config(repo)) do
      {:ok, sha} -> sha
      {:error, _reason} -> base_sha
    end
  end

  defp config(repo) do
    Git.Config.new(working_dir: repo, timeout: @timeout_ms)
  end

  # git reports expected failures on stderr and exits non-zero. Only the first
  # line is useful in the UI; the rest is usage hints.
  defp describe({output, _exit_code}) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> List.first()
    |> Kernel.||("git command failed")
    |> String.replace_prefix("fatal: ", "")
  end

  defp describe(reason), do: inspect(reason)
end
