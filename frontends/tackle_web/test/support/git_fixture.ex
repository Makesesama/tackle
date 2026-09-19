defmodule Tackle.Web.GitFixture do
  @moduledoc """
  Builds a throwaway git repository whose history covers the patch shapes the
  diff view has to render.

  Two commits are created. The second one modifies a file, adds one, deletes one,
  renames one, changes a file with no trailing newline and rewrites a binary
  file, so `HEAD~1` to `HEAD` exercises every branch of the renderer.
  """

  @doc """
  Creates the repository and returns its path.
  """
  @spec build() :: Path.t()
  def build do
    dir = Path.join(System.tmp_dir!(), "tackle_web_git_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    git(dir, ["init", "-q", "-b", "main"])
    git(dir, ["config", "user.email", "review@example.com"])
    git(dir, ["config", "user.name", "Review"])

    write(dir, "lib/keep.ex", """
    defmodule Keep do
      def one, do: 1
      def two, do: 2
    end
    """)

    write(dir, "lib/removed.ex", "defmodule Removed do\nend\n")
    write(dir, "lib/renamed.ex", "defmodule Renamed do\nend\n")
    write(dir, "notes.txt", "no newline at end")
    File.write!(Path.join(dir, "image.bin"), <<0, 1, 2, 3>>)

    git(dir, ["add", "-A"])
    git(dir, ["commit", "-qm", "base"])

    File.rm!(Path.join(dir, "lib/removed.ex"))

    write(dir, "lib/keep.ex", """
    defmodule Keep do
      def one, do: 1
      def two, do: 22
      def three, do: 3
    end
    """)

    write(dir, "lib/added.ex", "defmodule Added do\n  def hello, do: :world\nend\n")
    git(dir, ["mv", "lib/renamed.ex", "lib/renamed_again.ex"])
    write(dir, "notes.txt", "no newline at end CHANGED")
    File.write!(Path.join(dir, "image.bin"), <<0, 9, 2, 3>>)

    git(dir, ["add", "-A"])
    git(dir, ["commit", "-qm", "change"])

    dir
  end

  @doc """
  Builds a repository laid out the way the review flow finds one on GitHub.

  `main` sits at the second commit and a pull request head sits on a commit that
  `main` does not contain, so the merge base of the two is the first commit and
  the diff is exactly the pull request's own change.

  GitHub publishes pull request refs under `refs/pull/`, which a bare clone does
  not copy across, so the published repository gets them recreated explicitly.

  Returns `{host_dir, source_dir}`; point `config :tackle_web, :github_host` at
  `host_dir` to clone from it without touching the network.
  """
  @spec hosted(Path.t(), String.t(), String.t(), pos_integer()) :: {Path.t(), Path.t()}
  def hosted(host, owner, name, number) do
    repo = build()

    git(repo, ["checkout", "-q", "-b", "contributor", "HEAD~1"])
    write(repo, "lib/from_the_pull_request.ex", "defmodule FromThePullRequest do\nend\n")
    git(repo, ["add", "-A"])
    git(repo, ["commit", "-qm", "pull request head"])
    head_sha = rev_parse(repo, "HEAD")
    git(repo, ["checkout", "-q", "main"])

    published = Path.join([host, owner, "#{name}.git"])
    File.mkdir_p!(Path.dirname(published))
    git(repo, ["clone", "--bare", "--quiet", repo, published])
    git(published, ["update-ref", "refs/pull/#{number}/head", head_sha])

    {host, repo}
  end

  @doc """
  Creates a directory nobody else is using, for tests that need scratch space.
  """
  @spec scratch_dir(String.t()) :: Path.t()
  def scratch_dir(label) do
    Path.join(System.tmp_dir!(), "tackle_web_#{label}_#{System.unique_integer([:positive])}")
  end

  defp rev_parse(repo, ref) do
    {output, 0} = System.cmd("git", ["rev-parse", ref], cd: repo, stderr_to_stdout: true)
    String.trim(output)
  end

  defp write(dir, path, contents) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
  end

  defp git(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end
end
