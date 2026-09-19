defmodule Tackle.Web.RepoCacheTest do
  # Clones land under a configured repos root, which is global configuration.
  use ExUnit.Case, async: false

  alias Tackle.Web.GitFixture
  alias Tackle.Web.Paths
  alias Tackle.Web.RepoCache
  alias Tackle.Web.Git, as: WebGit

  @owner "acme"
  @name "widgets"
  @number 7

  setup do
    root = GitFixture.scratch_dir("cache")
    host = Path.join(root, "host")
    repos = Path.join(root, "repos")

    {_host, source} = GitFixture.hosted(host, @owner, @name, @number)

    previous_host = Application.get_env(:tackle_web, :github_host)
    previous_repos = Application.get_env(:tackle_web, :repos_root)
    Application.put_env(:tackle_web, :github_host, host)
    Application.put_env(:tackle_web, :repos_root, repos)

    on_exit(fn ->
      restore(:github_host, previous_host)
      restore(:repos_root, previous_repos)
      File.rm_rf(root)
      File.rm_rf(source)
    end)

    {:ok, repos: repos}
  end

  test "clones the repository into the repos root", %{repos: repos} do
    assert {:ok, path} = RepoCache.pull_request_checkout(@owner, @name, @number, "main")

    assert path == Path.join([repos, @owner, @name, "pr-#{@number}"])
    assert WebGit.valid_repo?(path)
  end

  test "checks the pull request head out into the working tree" do
    assert {:ok, path} = RepoCache.pull_request_checkout(@owner, @name, @number, "main")

    # The assistant reads the code from this directory, so it has to hold the
    # files of the pull request head, not an empty tree.
    assert File.read!(Path.join(path, "lib/from_the_pull_request.ex")) =~ "defmodule"
    refute File.exists?(Path.join(path, "lib/added.ex"))

    assert {:ok, head} = Git.rev_parse(ref: "HEAD", config: Git.Config.new(working_dir: path))

    assert {:ok, pr} =
             Git.rev_parse(
               ref: RepoCache.pull_ref(@number),
               config: Git.Config.new(working_dir: path)
             )

    assert head == pr
  end

  test "leaves no staging directory behind after cloning" do
    {:ok, path} = RepoCache.pull_request_checkout(@owner, @name, @number, "main")

    assert Path.wildcard(Path.join(Path.dirname(path), "*.staging-*")) == []
  end

  test "fetches both sides of the pull request as local refs" do
    {:ok, path} = RepoCache.pull_request_checkout(@owner, @name, @number, "main")
    config = Git.Config.new(working_dir: path)

    assert {:ok, head} = Git.rev_parse(ref: RepoCache.pull_ref(@number), config: config)
    assert {:ok, base} = Git.rev_parse(ref: RepoCache.base_ref("main"), config: config)
    assert head =~ ~r/^[0-9a-f]{40}$/
    assert base =~ ~r/^[0-9a-f]{40}$/
    refute head == base
  end

  test "the two refs diff to exactly the pull request's own change" do
    {:ok, path} = RepoCache.pull_request_checkout(@owner, @name, @number, "main")

    assert {:ok, %{patch: patch}} =
             WebGit.load(path, RepoCache.base_ref("main"), RepoCache.pull_ref(@number))

    assert patch =~ "lib/from_the_pull_request.ex"

    # Commits that landed on the base branch after the pull request diverged are
    # not part of it, which is what comparing against the merge base gives us.
    refute patch =~ "lib/added.ex"
  end

  test "reuses an existing clone instead of cloning again" do
    {:ok, path} = RepoCache.pull_request_checkout(@owner, @name, @number, "main")

    marker = Path.join([path, ".git", "tackle-web-marker"])
    File.write!(marker, "kept")

    assert {:ok, ^path} = RepoCache.pull_request_checkout(@owner, @name, @number, "main")
    assert File.exists?(marker)
  end

  test "recovers from a clone that was interrupted halfway" do
    path = checkout_path()
    File.mkdir_p!(Path.join(path, ".git"))
    File.write!(Path.join([path, ".git", "HEAD"]), "ref: refs/heads/not-there\n")

    assert {:ok, ^path} = RepoCache.pull_request_checkout(@owner, @name, @number, "main")
    assert WebGit.valid_repo?(path)
  end

  test "refuses to delete a directory it does not recognise" do
    path = checkout_path()
    File.mkdir_p!(path)
    File.write!(Path.join(path, "important.txt"), "not ours")

    assert {:error, message} = RepoCache.pull_request_checkout(@owner, @name, @number, "main")
    assert message =~ "already exists and is not a git checkout"

    # The directory has to survive the attempt untouched.
    assert File.read!(Path.join(path, "important.txt")) == "not ours"
  end

  test "explains a repository it cannot find" do
    assert {:error, message} = RepoCache.pull_request_checkout(@owner, "missing", 1, "main")
    assert message =~ "Could not clone acme/missing"
  end

  test "reports a pull request ref that the remote does not have" do
    assert {:error, message} = RepoCache.pull_request_checkout(@owner, @name, 999, "main")
    assert message =~ "Could not fetch the pull request refs"
  end

  test "an empty refspec list only clones" do
    assert {:ok, path} = RepoCache.checkout(@owner, @name, @number)
    assert WebGit.valid_repo?(path)

    config = Git.Config.new(working_dir: path)
    assert {:ok, _sha} = Git.rev_parse(ref: "refs/remotes/origin/main", config: config)
    assert {:error, _reason} = Git.rev_parse(ref: RepoCache.pull_ref(@number), config: config)
  end

  defp checkout_path do
    Paths.pull_request_path(@owner, @name, @number)
  end

  defp restore(key, nil), do: Application.delete_env(:tackle_web, key)
  defp restore(key, value), do: Application.put_env(:tackle_web, key, value)
end
