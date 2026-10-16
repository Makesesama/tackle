defmodule Tackle.Review.Test.GitRepo do
  @moduledoc false
  # Throwaway Git repositories for review tests. Commands ignore the user's
  # global and system Git configuration, so signing or hooks do not leak in.

  import ExUnit.Callbacks, only: [on_exit: 1]

  @env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_AUTHOR_NAME", "Review"},
    {"GIT_AUTHOR_EMAIL", "review@example.com"},
    {"GIT_COMMITTER_NAME", "Review"},
    {"GIT_COMMITTER_EMAIL", "review@example.com"}
  ]

  @doc "Creates an empty repository on branch `main`, removed when the test exits."
  def init(label \\ "repo") do
    dir =
      Path.join(System.tmp_dir!(), "tackle-review-#{label}-#{System.unique_integer([:positive])}")

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    git(dir, ["init", "-q", "-b", "main"])
    dir
  end

  @doc "Writes files (`%{path => contents}`) relative to the repository."
  def write(dir, files) do
    Enum.each(files, fn {path, contents} ->
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, contents)
    end)

    dir
  end

  @doc "Stages everything and commits it, returning the new commit's SHA."
  def commit(dir, message) do
    git(dir, ["add", "-A"])
    git(dir, ["commit", "-q", "--no-verify", "-m", message])
    rev_parse(dir, "HEAD")
  end

  def rev_parse(dir, rev), do: dir |> git(["rev-parse", rev]) |> String.trim()

  def git(dir, args) do
    case System.cmd("git", args, cd: dir, env: @env, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end
end
