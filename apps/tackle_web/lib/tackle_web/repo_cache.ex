defmodule Tackle.Web.RepoCache do
  @moduledoc """
  Keeps one local clone per reviewed pull request, with a working tree.

  One clone per pull request, not per repository. Two reviews of the same
  repository would otherwise share a single work tree and could not both be
  checked out at their own head commit — and the assistant reads the code from
  that work tree, so it has to match the diff being reviewed.

  The clone itself is created with `--no-checkout` and the pull request head is
  materialised afterwards, which skips checking out the default branch on the
  way. A plain clone is used rather than a blobless one because the clone is
  also the agent's working directory, so on-demand blob fetches would turn every
  file read into a network round trip.

  Cloning into a unique directory and renaming it into place is what makes this
  safe without a coordinating process: two viewers can race to open the same
  pull request, and the loser discards its clone instead of corrupting the
  winner's.

  All git access goes through `Tackle.Web.Git`, and therefore through forcola,
  so a timed-out clone takes its transports and credential helpers with it.
  """

  alias Tackle.Web.GitHub
  alias Tackle.Web.Paths
  alias Tackle.Web.Git, as: WebGit

  # A first clone can be large; a fetch is incremental and much quicker, and a
  # checkout writes the whole work tree.
  @clone_timeout 600_000
  @fetch_timeout 300_000
  @checkout_timeout 300_000

  @doc """
  Ensures the clone for `owner/name#number` exists and returns its path.

  `refspecs` are fetched from `origin` after the clone; an empty list is fine
  when the caller only needs the default clone. The work tree is left untouched:
  use `pull_request_checkout/4` when the caller needs files on disk.
  """
  @spec checkout(String.t(), String.t(), pos_integer(), [String.t()]) ::
          {:ok, Path.t()} | {:error, String.t()}
  def checkout(owner, name, number, refspecs \\ []) do
    path = Paths.pull_request_path(owner, name, number)

    with :ok <- ensure_clone(owner, name, path),
         :ok <- fetch(path, refspecs) do
      {:ok, path}
    end
  end

  @doc """
  Ensures a clone holding both sides of a pull request, checked out at its head.

  The head is fetched through GitHub's `refs/pull/<number>/head`, which exists on
  the base repository even for pull requests opened from a fork and survives the
  contributor deleting their branch. The returned path is a working tree at that
  head commit, which is what the assistant reads.
  """
  @spec pull_request_checkout(String.t(), String.t(), pos_integer(), String.t()) ::
          {:ok, Path.t()} | {:error, String.t()}
  def pull_request_checkout(owner, name, number, base_ref) do
    refspecs = [
      "+refs/pull/#{number}/head:refs/remotes/origin/pr/#{number}",
      "+refs/heads/#{base_ref}:refs/remotes/origin/#{base_ref}"
    ]

    with {:ok, path} <- checkout(owner, name, number, refspecs),
         :ok <- materialize(path, pull_ref(number)) do
      {:ok, path}
    end
  end

  @doc """
  Ensures the clone of `owner/name` has a working tree at `branch`.

  This is the checkout a chat runs in: one clone per repository, left on the
  default branch rather than on a pull request. When `branch` is unknown to the
  clone (a stale default, say) the clone's own `origin/HEAD` is used instead, so
  a project added while a repository was named differently still opens.
  """
  @spec default_checkout(String.t(), String.t(), String.t() | nil) ::
          {:ok, Path.t()} | {:error, String.t()}
  def default_checkout(owner, name, branch) do
    path = Paths.repo_path(owner, name)

    with :ok <- ensure_clone(owner, name, path) do
      materialize_branch(path, branch)
    end
  end

  # A clone made with `--no-checkout` already has HEAD pointing at the default
  # branch, so the usual "same commit, skip the switch" shortcut would leave the
  # work tree empty. The switch is therefore forced while the tree has never been
  # materialised, and skipped afterwards.
  defp materialize_branch(path, branch) do
    ref = if is_binary(branch) and branch != "", do: "refs/remotes/origin/#{branch}"

    case materialize(path, ref || "refs/remotes/origin/HEAD", not materialized?(path)) do
      :ok -> {:ok, path}
      {:error, _reason} -> materialize_default(path)
    end
  end

  defp materialized?(path), do: File.exists?(Path.join(path, ".git/index"))

  defp materialize_default(path) do
    case materialize(path, "refs/remotes/origin/HEAD", not materialized?(path)) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Local ref holding a pull request's head, as produced by `pull_request_checkout/4`."
  @spec pull_ref(pos_integer()) :: String.t()
  def pull_ref(number), do: "refs/remotes/origin/pr/#{number}"

  @doc "Local ref holding a base branch, as produced by `pull_request_checkout/4`."
  @spec base_ref(String.t()) :: String.t()
  def base_ref(branch), do: "refs/remotes/origin/#{branch}"

  defp ensure_clone(owner, name, path) do
    if WebGit.valid_repo?(path) do
      :ok
    else
      clone(owner, name, path)
    end
  end

  defp clone(owner, name, path) do
    url = GitHub.clone_url(owner, name)
    parent = Paths.ensure_dir!(Path.dirname(path))
    staging = "#{path}.staging-#{System.unique_integer([:positive])}"

    config = Git.Config.new(working_dir: parent, env: GitHub.git_env(), timeout: @clone_timeout)

    case Git.clone(url, directory: staging, no_checkout: true, config: config) do
      {:ok, _result} ->
        install(staging, path)

      {:error, reason} ->
        File.rm_rf(staging)
        {:error, clone_error(owner, name, reason)}
    end
  end

  # Renaming into place is what makes concurrent clones safe without a
  # coordinating process: the loser of the race finds the destination occupied
  # and simply discards its own clone.
  defp install(staging, path) do
    case File.rename(staging, path) do
      :ok ->
        :ok

      {:error, _reason} ->
        settle(staging, path)
    end
  end

  defp settle(staging, path) do
    cond do
      # Another review finished its clone first. The two are equivalent.
      WebGit.valid_repo?(path) ->
        discard(staging)
        :ok

      # A clone that was interrupted leaves a `.git` that is not a usable
      # repository. Clearing it is how the next attempt recovers.
      incomplete_checkout?(path) ->
        File.rm_rf(path)
        retry_install(staging, path)

      true ->
        discard(staging)

        {:error,
         "#{path} already exists and is not a git checkout. Move it aside, or " <>
           "point the repos root somewhere else."}
    end
  end

  defp retry_install(staging, path) do
    case File.rename(staging, path) do
      :ok ->
        :ok

      {:error, reason} ->
        discard(staging)
        {:error, "Could not install the checkout at #{path}: #{:file.format_error(reason)}"}
    end
  end

  # Only a directory holding a `.git` is recognisably ours to remove. Anything
  # else is left alone, because the repos root is operator-configurable and one
  # typo away from a directory that matters.
  defp incomplete_checkout?(path), do: File.dir?(Path.join(path, ".git"))

  defp discard(staging), do: File.rm_rf(staging)

  defp fetch(_path, []), do: :ok

  defp fetch(path, refspecs) do
    config = Git.Config.new(working_dir: path, env: GitHub.git_env(), timeout: @fetch_timeout)

    case Git.fetch(remote: "origin", refspecs: refspecs, config: config) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, fetch_error(reason)}
    end
  end

  # Leaves the work tree at `ref`. Skipping the switch when HEAD already points
  # at the right commit keeps reopening a pull request cheap: a switch rewrites
  # every file, and this runs on each page load.
  defp materialize(path, ref, force? \\ false) do
    config = Git.Config.new(working_dir: path, env: GitHub.git_env(), timeout: @checkout_timeout)

    with {:ok, sha} <- rev_parse(config, ref),
         :ok <- switch_if_needed(path, config, sha, force?) do
      :ok
    end
  end

  defp rev_parse(config, ref) do
    case Git.rev_parse(ref: ref, config: config) do
      {:ok, sha} when is_binary(sha) ->
        {:ok, String.trim(sha)}

      {:ok, other} ->
        {:error, "Could not resolve #{ref} in the checkout: #{inspect(other)}"}

      {:error, reason} ->
        {:error, "Could not resolve #{ref} in the checkout: #{first_line(output_of(reason))}"}
    end
  end

  defp switch_if_needed(path, config, sha, force?) do
    current =
      case Git.rev_parse(ref: "HEAD", config: config) do
        {:ok, head} when is_binary(head) -> String.trim(head)
        _other -> nil
      end

    if not force? and current == sha do
      :ok
    else
      case Git.switch(detach: true, branch: sha, config: config) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          {:error,
           "Could not check out the pull request head in #{path}: " <>
             first_line(output_of(reason))}
      end
    end
  end

  defp clone_error(owner, name, reason) do
    output = output_of(reason)

    cond do
      denial?(output) ->
        "GitHub refused to clone #{owner}/#{name}. If the repository is private, configure a token."

      network?(output) ->
        "Could not reach github.com to clone #{owner}/#{name}."

      true ->
        "Could not clone #{owner}/#{name}: #{first_line(output)}"
    end
  end

  defp fetch_error(reason) do
    output = output_of(reason)

    cond do
      denial?(output) -> "GitHub refused to fetch the pull request refs."
      network?(output) -> "Could not reach github.com to fetch the pull request refs."
      true -> "Could not fetch the pull request refs: #{first_line(output)}"
    end
  end

  # git reports both a missing repository and an unauthenticated one this way,
  # because it cannot tell the difference without credentials.
  defp denial?(output) do
    Enum.any?(
      [
        "could not read Username",
        "Repository not found",
        "Authentication failed",
        "terminal prompts disabled"
      ],
      &String.contains?(output, &1)
    )
  end

  defp network?(output) do
    Enum.any?(
      ["Could not resolve host", "unable to access", "Connection refused"],
      &String.contains?(
        output,
        &1
      )
    )
  end

  defp output_of({output, _exit_code}) when is_binary(output), do: output
  defp output_of(reason), do: inspect(reason)

  defp first_line(output) do
    output
    |> String.split("\n", trim: true)
    |> List.first()
    |> Kernel.||("git failed")
    |> String.replace_prefix("fatal: ", "")
  end
end
