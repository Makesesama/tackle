defmodule Tackle.Web.GitTest do
  use ExUnit.Case, async: true

  alias Tackle.Web.{Git, GitFixture}

  setup_all do
    repo = GitFixture.build()
    on_exit(fn -> File.rm_rf(repo) end)
    {:ok, repo: repo}
  end

  test "accepts a repository", %{repo: repo} do
    assert Git.validate(repo) == :ok
  end

  test "accepts a subdirectory of a repository", %{repo: repo} do
    assert Git.validate(Path.join(repo, "lib")) == :ok
  end

  test "rejects a directory that is not a repository" do
    dir =
      Path.join(System.tmp_dir!(), "tackle_web_plain_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:error, message} = Git.validate(dir)
    assert message =~ "not a git repository"
  end

  test "reads a blob at a ref", %{repo: repo} do
    assert {:ok, content} = Git.blob(repo, "HEAD", "lib/added.ex")
    assert content =~ "defmodule Added"
  end

  test "reports a path that does not exist at a ref", %{repo: repo} do
    # The base side of an added file takes this path, so it has to be quiet.
    assert Git.blob(repo, "HEAD", "lib/removed.ex") == :error
  end

  test "diffs from the merge base of the two refs", %{repo: repo} do
    assert {:ok, %{base_sha: base, head_sha: head, patch: patch}} =
             Git.load(repo, "HEAD~1", "HEAD")

    assert patch =~ "diff --git"
    refute base == head
  end

  test "resolves refs other than HEAD", %{repo: repo} do
    assert {:ok, %{patch: patch}} = Git.load(repo, "main~1", "main")
    assert patch =~ "diff --git"
  end

  test "reports an unknown revision", %{repo: repo} do
    assert {:error, message} = Git.load(repo, "HEAD~1", "no-such-revision")
    assert message =~ "unknown revision"
  end
end
