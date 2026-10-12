defmodule Tackle.Review.ChangeTest do
  alias Tackle.Test.Executors

  # Git runs through the executor, so every case also runs under the jailed
  # executor (a real exec-server without a jail).
  use ExUnit.Case, async: true, parameterize: Executors.parameters()

  import Executors, only: [start_executor: 1]

  alias Tackle.Review.Change
  alias Tackle.Test.GitRepo

  setup :start_executor

  defp load(executor, opts), do: Change.load([executor: executor] ++ opts)

  defp paths(%Change{diff: diff}), do: Enum.map(diff.files, & &1.path)

  defp base_repo do
    dir = GitRepo.init()
    GitRepo.write(dir, %{"lib/a.ex" => "a\nb\nc\n", "README.md" => "readme\n"})
    {dir, GitRepo.commit(dir, "base")}
  end

  describe "branch mode" do
    test "compares the merge base with the default branch to the working tree",
         %{executor: executor} do
      {dir, base} = base_repo()
      GitRepo.git(dir, ["checkout", "-q", "-b", "feature"])
      GitRepo.write(dir, %{"lib/b.ex" => "new\n"})
      GitRepo.commit(dir, "Add b\n\nWith a body.")

      # Work committed on main after branching off is not part of the change.
      GitRepo.git(dir, ["checkout", "-q", "main"])
      GitRepo.write(dir, %{"README.md" => "changed on main\n"})
      GitRepo.commit(dir, "main moves on")
      GitRepo.git(dir, ["checkout", "-q", "feature"])

      # Uncommitted, staged and unstaged, changes are included.
      GitRepo.write(dir, %{"lib/a.ex" => "a\nB\nc\n", "lib/c.ex" => "staged\n"})
      GitRepo.git(dir, ["add", "lib/c.ex"])

      assert {:ok, change} = load(executor, cwd: Path.join(dir, "lib"))

      assert %Change{mode: :branch, base_ref: "main", base_sha: ^base, head_sha: :worktree} =
               change

      assert change.root == dir
      assert change.cwd == Path.join(dir, "lib")
      assert paths(change) == ["lib/a.ex", "lib/b.ex", "lib/c.ex"]
      assert Enum.map(change.context_diff.files, & &1.path) == paths(change)
      assert [%{subject: "Add b", body: "With a body.", sha: sha}] = change.commits
      assert sha == GitRepo.rev_parse(dir, "HEAD")
    end

    test "on the default branch only uncommitted changes remain", %{executor: executor} do
      {dir, head} = base_repo()
      GitRepo.write(dir, %{"lib/a.ex" => "a\nb\nc\nd\n"})

      assert {:ok, change} = load(executor, cwd: dir)
      assert change.base_sha == head
      assert change.commits == []
      assert paths(change) == ["lib/a.ex"]
    end

    test "prefers origin/HEAD and accepts an explicit base", %{executor: executor} do
      {dir, base} = base_repo()
      GitRepo.git(dir, ["branch", "-m", "main", "work"])
      GitRepo.write(dir, %{"lib/a.ex" => "x\n"})
      GitRepo.commit(dir, "work")

      assert load(executor, cwd: dir) == {:error, :no_default_branch}

      GitRepo.git(dir, ["update-ref", "refs/remotes/origin/trunk", base])

      GitRepo.git(dir, [
        "symbolic-ref",
        "refs/remotes/origin/HEAD",
        "refs/remotes/origin/trunk"
      ])

      assert {:ok, %Change{base_ref: "origin/trunk", base_sha: ^base}} =
               load(executor, cwd: dir)

      GitRepo.git(dir, ["branch", "other", base])

      assert {:ok, %Change{base_ref: "other", base_sha: ^base}} =
               load(executor, cwd: dir, base: "other")

      assert load(executor, cwd: dir, base: "missing") ==
               {:error, {:unknown_revision, "missing"}}
    end

    test "fails without commits", %{executor: executor} do
      dir = GitRepo.init()
      assert load(executor, cwd: dir) == {:error, {:unknown_revision, "HEAD"}}
    end
  end

  describe "staged mode" do
    test "compares the index with HEAD", %{executor: executor} do
      {dir, head} = base_repo()
      GitRepo.write(dir, %{"lib/a.ex" => "a\nB\nc\n", "README.md" => "unstaged\n"})
      GitRepo.git(dir, ["add", "lib/a.ex"])

      assert {:ok, change} = load(executor, cwd: dir, staged: true)
      assert %Change{mode: :staged, base_sha: ^head, head_sha: :index, commits: []} = change
      assert paths(change) == ["lib/a.ex"]
    end

    test "compares with the empty tree before the first commit", %{executor: executor} do
      dir = GitRepo.init()
      GitRepo.write(dir, %{"first.ex" => "one\n"})
      GitRepo.git(dir, ["add", "first.ex"])

      assert {:ok, change} = load(executor, cwd: dir, staged: true)
      assert [%{path: "first.ex", status: :added}] = change.diff.files
    end
  end

  describe "range mode" do
    setup do
      {dir, base} = base_repo()
      GitRepo.git(dir, ["checkout", "-q", "-b", "feature"])
      GitRepo.write(dir, %{"lib/a.ex" => "a\nB\nc\n"})
      feature = GitRepo.commit(dir, "Change a")
      GitRepo.git(dir, ["checkout", "-q", "main"])
      GitRepo.write(dir, %{"README.md" => "main\n"})
      main = GitRepo.commit(dir, "Change readme")
      %{dir: dir, base: base, feature: feature, main: main}
    end

    test "base..head compares two revisions", %{executor: executor} = ctx do
      assert {:ok, change} = load(executor, cwd: ctx.dir, range: "main..feature")
      assert %Change{mode: :range, base_ref: "main", base_sha: base, head_sha: head} = change
      assert {base, head} == {ctx.main, ctx.feature}
      assert paths(change) == ["README.md", "lib/a.ex"]
      assert [%{subject: "Change a"}] = change.commits
    end

    test "base...head compares the merge base with head", %{executor: executor} = ctx do
      assert {:ok, change} = load(executor, cwd: ctx.dir, range: "main...feature")
      assert {change.base_sha, change.head_sha} == {ctx.base, ctx.feature}
      assert paths(change) == ["lib/a.ex"]
    end

    test "an empty side means HEAD", %{executor: executor} = ctx do
      assert {:ok, change} = load(executor, cwd: ctx.dir, range: "feature..")
      assert {change.base_sha, change.head_sha} == {ctx.feature, ctx.main}
    end

    test "a single revision compares it with the working tree", %{executor: executor} = ctx do
      GitRepo.write(ctx.dir, %{"lib/new.ex" => "x\n"})
      GitRepo.git(ctx.dir, ["add", "lib/new.ex"])

      assert {:ok, change} = load(executor, cwd: ctx.dir, range: ctx.base)
      assert %Change{base_ref: base_ref, base_sha: base_sha, head_sha: :worktree} = change
      assert base_ref == ctx.base and base_sha == ctx.base
      assert paths(change) == ["README.md", "lib/new.ex"]
      assert [%{subject: "Change readme"}] = change.commits
    end

    test "reports invalid ranges and unknown revisions", %{executor: executor} = ctx do
      assert load(executor, cwd: ctx.dir, range: "..") == {:error, {:invalid_range, ".."}}
      assert load(executor, cwd: ctx.dir, range: "") == {:error, {:invalid_range, ""}}

      assert load(executor, cwd: ctx.dir, range: "main..nope") ==
               {:error, {:unknown_revision, "nope"}}

      assert load(executor, cwd: ctx.dir, range: "--output=/tmp/x") ==
               {:error, {:unknown_revision, "--output=/tmp/x"}}
    end

    test "unrelated histories have no merge base", %{executor: executor} = ctx do
      GitRepo.git(ctx.dir, ["checkout", "-q", "--orphan", "lonely"])
      GitRepo.write(ctx.dir, %{"lonely.txt" => "x\n"})
      GitRepo.commit(ctx.dir, "lonely")

      assert load(executor, cwd: ctx.dir, range: "main...lonely") ==
               {:error, {:no_merge_base, "main", "lonely"}}
    end
  end

  test "includes the function-context diff", %{executor: executor} do
    dir = GitRepo.init()
    function = Enum.map_join(1..12, "", &"\tline#{&1};\n")
    GitRepo.write(dir, %{"a.c" => "int f(void)\n{\n" <> function <> "}\n"})
    GitRepo.commit(dir, "base")

    GitRepo.write(dir, %{
      "a.c" => "int f(void)\n{\n" <> String.replace(function, "line12", "LINE12") <> "}\n"
    })

    assert {:ok, change} = load(executor, cwd: dir)
    assert [%{hunks: [plain]}] = change.diff.files
    assert [%{hunks: [whole]}] = change.context_diff.files
    assert plain.old_start == 11
    assert whole.old_start == 1 and whole.old_count == 15
  end

  test "rejects --staged together with a range", %{executor: executor} do
    {dir, _base} = base_repo()
    assert load(executor, cwd: dir, staged: true, range: "HEAD") == {:error, :conflicting_options}
  end

  test "reports a directory outside any repository", %{executor: executor} do
    dir =
      Path.join(System.tmp_dir!(), "tackle-review-norepo-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # GIT_CEILING_DIRECTORIES is not set by the harness, so this relies on the
    # system temporary directory not being inside a repository.
    assert load(executor, cwd: dir) == {:error, {:not_a_git_repository, dir}}
  end

  test "formats errors" do
    assert Change.format_error({:unknown_revision, "x"}) == "unknown revision: x"
    assert Change.format_error(:no_default_branch) =~ "default branch"

    assert Change.format_error({:git_failed, 128, "fatal: boom\n"}) ==
             "git exited with status 128: fatal: boom"

    assert Change.format_error(:timeout) == "git did not finish in time"
  end
end
