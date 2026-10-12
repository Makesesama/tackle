defmodule Tackle.Review.ChangeTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.Change
  alias Tackle.Test.GitRepo

  defp load(opts), do: Change.load(opts)

  defp paths(%Change{diff: diff}), do: Enum.map(diff.files, & &1.path)

  defp base_repo do
    dir = GitRepo.init()
    GitRepo.write(dir, %{"lib/a.ex" => "a\nb\nc\n", "README.md" => "readme\n"})
    {dir, GitRepo.commit(dir, "base")}
  end

  describe "branch mode" do
    test "compares the merge base with the default branch to the working tree" do
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

      assert {:ok, change} = load(cwd: Path.join(dir, "lib"))

      assert %Change{mode: :branch, base_ref: "main", base_sha: ^base, head_sha: :worktree} =
               change

      assert change.root == dir
      assert change.cwd == Path.join(dir, "lib")
      assert paths(change) == ["lib/a.ex", "lib/b.ex", "lib/c.ex"]
      assert [%{old_content: "a\nb\nc\n", new_content: "a\nB\nc\n"} | _rest] = change.diff.files
      assert [%{subject: "Add b", body: "With a body.", sha: sha}] = change.commits
      assert sha == GitRepo.rev_parse(dir, "HEAD")
    end

    test "on the default branch only uncommitted changes remain" do
      {dir, head} = base_repo()
      GitRepo.write(dir, %{"lib/a.ex" => "a\nb\nc\nd\n"})

      assert {:ok, change} = load(cwd: dir)
      assert change.base_sha == head
      assert change.commits == []
      assert paths(change) == ["lib/a.ex"]
    end

    test "prefers origin/HEAD and accepts an explicit base" do
      {dir, base} = base_repo()
      GitRepo.git(dir, ["branch", "-m", "main", "work"])
      GitRepo.write(dir, %{"lib/a.ex" => "x\n"})
      GitRepo.commit(dir, "work")

      assert load(cwd: dir) == {:error, :no_default_branch}

      GitRepo.git(dir, ["update-ref", "refs/remotes/origin/trunk", base])

      GitRepo.git(dir, [
        "symbolic-ref",
        "refs/remotes/origin/HEAD",
        "refs/remotes/origin/trunk"
      ])

      assert {:ok, %Change{base_ref: "origin/trunk", base_sha: ^base}} =
               load(cwd: dir)

      GitRepo.git(dir, ["branch", "other", base])

      assert {:ok, %Change{base_ref: "other", base_sha: ^base}} =
               load(cwd: dir, base: "other")

      assert load(cwd: dir, base: "missing") ==
               {:error, {:unknown_revision, "missing"}}
    end

    test "fails without commits" do
      dir = GitRepo.init()
      assert load(cwd: dir) == {:error, {:unknown_revision, "HEAD"}}
    end
  end

  describe "staged mode" do
    test "compares the index with HEAD" do
      {dir, head} = base_repo()
      GitRepo.write(dir, %{"lib/a.ex" => "a\nB\nc\n", "README.md" => "unstaged\n"})
      GitRepo.git(dir, ["add", "lib/a.ex"])

      assert {:ok, change} = load(cwd: dir, staged: true)
      assert %Change{mode: :staged, base_sha: ^head, head_sha: :index, commits: []} = change
      assert paths(change) == ["lib/a.ex"]
    end

    test "compares with the empty tree before the first commit" do
      dir = GitRepo.init()
      GitRepo.write(dir, %{"first.ex" => "one\n"})
      GitRepo.git(dir, ["add", "first.ex"])

      assert {:ok, change} = load(cwd: dir, staged: true)
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

    test "base..head compares two revisions", ctx do
      assert {:ok, change} = load(cwd: ctx.dir, range: "main..feature")
      assert %Change{mode: :range, base_ref: "main", base_sha: base, head_sha: head} = change
      assert {base, head} == {ctx.main, ctx.feature}
      assert paths(change) == ["README.md", "lib/a.ex"]
      assert [%{subject: "Change a"}] = change.commits
    end

    test "base...head compares the merge base with head", ctx do
      assert {:ok, change} = load(cwd: ctx.dir, range: "main...feature")
      assert {change.base_sha, change.head_sha} == {ctx.base, ctx.feature}
      assert paths(change) == ["lib/a.ex"]
    end

    test "an empty side means HEAD", ctx do
      assert {:ok, change} = load(cwd: ctx.dir, range: "feature..")
      assert {change.base_sha, change.head_sha} == {ctx.feature, ctx.main}
    end

    test "a single revision compares it with the working tree", ctx do
      GitRepo.write(ctx.dir, %{"lib/new.ex" => "x\n"})
      GitRepo.git(ctx.dir, ["add", "lib/new.ex"])

      assert {:ok, change} = load(cwd: ctx.dir, range: ctx.base)
      assert %Change{base_ref: base_ref, base_sha: base_sha, head_sha: :worktree} = change
      assert base_ref == ctx.base and base_sha == ctx.base
      assert paths(change) == ["README.md", "lib/new.ex"]
      assert [%{subject: "Change readme"}] = change.commits
    end

    test "reports invalid ranges and unknown revisions", ctx do
      assert load(cwd: ctx.dir, range: "..") == {:error, {:invalid_range, ".."}}
      assert load(cwd: ctx.dir, range: "") == {:error, {:invalid_range, ""}}

      assert load(cwd: ctx.dir, range: "main..nope") ==
               {:error, {:unknown_revision, "nope"}}

      assert load(cwd: ctx.dir, range: "--output=/tmp/x") ==
               {:error, {:unknown_revision, "--output=/tmp/x"}}
    end

    test "unrelated histories have no merge base", ctx do
      GitRepo.git(ctx.dir, ["checkout", "-q", "--orphan", "lonely"])
      GitRepo.write(ctx.dir, %{"lonely.txt" => "x\n"})
      GitRepo.commit(ctx.dir, "lonely")

      assert load(cwd: ctx.dir, range: "main...lonely") ==
               {:error, {:no_merge_base, "main", "lonely"}}
    end
  end

  test "loads hunks and both sides' contents" do
    dir = GitRepo.init()
    function = Enum.map_join(1..12, "", &"\tline#{&1};\n")
    old = "int f(void)\n{\n" <> function <> "}\n"
    new = String.replace(old, "line12", "LINE12")
    GitRepo.write(dir, %{"a.c" => old, "gone.c" => "x\n", "logo.bin" => <<0, 1, 2>>})
    GitRepo.commit(dir, "base")
    File.rm!(Path.join(dir, "gone.c"))
    GitRepo.write(dir, %{"a.c" => new, "logo.bin" => <<0, 1, 3>>})

    assert {:ok, change} = load(cwd: dir)
    assert [file, gone, binary] = change.diff.files

    assert %{path: "a.c", old_path: "a.c", status: :modified, binary: false} = file
    assert %{additions: 1, deletions: 1, old_content: ^old, new_content: ^new} = file

    assert [%{header: "@@ -11,5 +11,5 @@ int f(void)", old_start: 11, section: "int f(void)"}] =
             file.hunks

    assert [%{kind: :context, old: 11, new: 11, text: "\tline9;", no_newline: false} | _rest] =
             hd(file.hunks).lines

    assert %{path: "logo.bin", binary: true, hunks: [], new_content: nil} = binary
    assert %{path: "gone.c", status: :deleted, old_content: "x\n", new_content: nil} = gone
  end

  test "treats files above :max_file_bytes as binary" do
    {dir, _base} = base_repo()
    GitRepo.write(dir, %{"lib/a.ex" => String.duplicate("long line\n", 20)})

    assert {:ok, %{diff: %{files: [%{binary: true, hunks: []}]}}} =
             load(cwd: dir, max_file_bytes: 64)
  end

  test "reports unmerged paths in staged mode" do
    {dir, _base} = base_repo()
    GitRepo.git(dir, ["checkout", "-q", "-b", "other"])
    GitRepo.write(dir, %{"lib/a.ex" => "a\nother\nc\n"})
    GitRepo.commit(dir, "other")
    GitRepo.git(dir, ["checkout", "-q", "main"])
    GitRepo.write(dir, %{"lib/a.ex" => "a\nmain\nc\n"})
    GitRepo.commit(dir, "main")

    assert_raise RuntimeError, ~r/merge/, fn -> GitRepo.git(dir, ["merge", "-q", "other"]) end

    assert {:ok, change} = load(cwd: dir, staged: true)
    assert [%{path: "lib/a.ex", status: :unmerged, hunks: []}] = change.diff.files
  end

  test "rejects --staged together with a range" do
    {dir, _base} = base_repo()
    assert load(cwd: dir, staged: true, range: "HEAD") == {:error, :conflicting_options}
  end

  test "reports a directory outside any repository" do
    dir =
      Path.join(System.tmp_dir!(), "tackle-review-norepo-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # GIT_CEILING_DIRECTORIES is not set by the harness, so this relies on the
    # system temporary directory not being inside a repository.
    assert load(cwd: dir) == {:error, {:not_a_git_repository, dir}}
  end

  test "reports a missing directory as outside any repository" do
    dir =
      Path.join(System.tmp_dir!(), "tackle-review-missing-#{System.unique_integer([:positive])}")

    assert load(cwd: dir) == {:error, {:not_a_git_repository, dir}}
  end

  describe "with a jail workspace" do
    test "does not search above the workspace" do
      {dir, _base} = base_repo()
      workspace = Path.join(dir, "lib")

      assert load(cwd: workspace, workspace: workspace) ==
               {:error, {:not_a_git_repository, workspace}}

      assert {:ok, %Change{root: ^dir}} = load(cwd: workspace, workspace: dir)
      assert {:ok, %Change{root: ^dir}} = load(cwd: workspace, workspace: dir <> "/")
      assert {:ok, %Change{root: ^dir}} = load(cwd: workspace, workspace: nil)

      assert load(cwd: dir, workspace: dir <> "-sibling") ==
               {:error, {:outside_workspace, dir, dir <> "-sibling"}}
    end

    test "refuses a Git file that points outside the workspace" do
      {secret, _base} = base_repo()
      workspace = GitRepo.init("workspace")
      File.rm_rf!(Path.join(workspace, ".git"))
      File.write!(Path.join(workspace, ".git"), "gitdir: #{secret}/.git\n")
      GitRepo.write(workspace, %{"lib/a.ex" => "harmless\n"})

      # Without a workspace, Git's rules apply and the pointer is followed.
      assert {:ok, %Change{}} = load(cwd: workspace, range: "HEAD")

      assert load(cwd: workspace, range: "HEAD", workspace: workspace) ==
               {:error, {:outside_workspace, Path.join(secret, ".git"), workspace}}

      assert Change.format_error({:outside_workspace, "/s", "/w"}) =~ "outside the workspace /w"
    end
  end

  test "refuses a bare repository" do
    {dir, _base} = base_repo()
    bare = dir <> ".git"
    on_exit(fn -> File.rm_rf!(bare) end)
    GitRepo.git(dir, ["clone", "-q", "--bare", dir, bare])

    assert load(cwd: bare) == {:error, :bare_repository}
  end

  test "refuses a working tree configured outside the repository" do
    {dir, _base} = base_repo()
    elsewhere = GitRepo.init("elsewhere")
    GitRepo.git(dir, ["config", "core.worktree", elsewhere])

    assert load(cwd: dir) == {:error, :external_worktree}
  end

  test "formats errors" do
    assert Change.format_error({:unknown_revision, "x"}) == "unknown revision: x"
    assert Change.format_error(:no_default_branch) =~ "default branch"
    assert Change.format_error({:no_merge_base, "a", "b"}) == "a and b have no common ancestor"

    assert Change.format_error({:not_a_git_repository, "/x"}) ==
             "/x is not inside a Git repository"

    assert Change.format_error(:bare_repository) == "the repository has no working tree"
    assert Change.format_error(:external_worktree) =~ "core.worktree"
    assert Change.format_error({:git, "boom"}) == "boom"
  end
end
