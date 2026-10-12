defmodule Tackle.Review.ConfinementTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.Confinement
  alias Tackle.Test.GitRepo

  # A committed repository standing for the jail's workspace.
  defp workspace do
    dir = GitRepo.init("confined")
    GitRepo.write(dir, %{"lib/a.ex" => "a\n"})
    GitRepo.commit(dir, "base")
    dir
  end

  defp git_dir(dir), do: Path.join(dir, ".git")

  test "locates the repository from a subdirectory" do
    dir = workspace()

    assert Confinement.locate(Path.join(dir, "lib"), dir) ==
             {:ok, %{workdir: dir, git_dir: git_dir(dir)}}
  end

  test "stops searching at the workspace" do
    dir = workspace()
    inner = Path.join(dir, "lib")
    assert Confinement.locate(inner, inner) == {:error, :not_found}
  end

  test "refuses a working directory outside the workspace or behind a link" do
    dir = workspace()
    other = GitRepo.init("elsewhere")
    assert Confinement.locate(other, dir) == {:error, {:outside_workspace, other, dir}}

    link = Path.join(dir, "link")
    File.ln_s!(Path.join(other, ""), link)
    assert Confinement.locate(link, dir) == {:error, {:outside_workspace, link, dir}}
  end

  test "refuses a .git that is a symbolic link" do
    dir = workspace()
    other = workspace()
    File.rm_rf!(git_dir(dir))
    File.ln_s!(git_dir(other), git_dir(dir))

    assert Confinement.locate(dir, dir) == {:error, {:unsafe_repository, git_dir(dir)}}
  end

  test "follows a Git file only inside the workspace" do
    dir = workspace()
    File.rename!(git_dir(dir), Path.join(dir, "store.git"))
    File.write!(git_dir(dir), "gitdir: store.git\n")

    assert Confinement.locate(dir, dir) ==
             {:ok, %{workdir: dir, git_dir: Path.join(dir, "store.git")}}

    File.write!(git_dir(dir), "nonsense\n")
    assert Confinement.locate(dir, dir) == {:error, {:unsafe_repository, git_dir(dir)}}
  end

  test "checks a linked worktree's common directory" do
    dir = workspace()
    worktree = Path.join(dir, "trees/feature")
    GitRepo.git(dir, ["worktree", "add", "-q", "-b", "feature", worktree])

    assert {:ok, %{workdir: ^worktree, git_dir: git_dir}} = Confinement.locate(worktree, dir)
    assert git_dir == Path.join(dir, ".git/worktrees/feature")

    # The same worktree in a workspace of its own reaches outside it.
    assert {:error, {:outside_workspace, ^git_dir, ^worktree}} =
             Confinement.locate(worktree, worktree)
  end

  test "refuses symbolic links and alternates in the Git data" do
    for entry <- ["HEAD", "config", "index", "packed-refs", "objects", "refs"] do
      dir = workspace()
      other = workspace()
      path = Path.join(git_dir(dir), entry)
      File.rm_rf!(path)
      File.ln_s!(Path.join(git_dir(other), entry), path)

      assert Confinement.locate(dir, dir) == {:error, {:unsafe_repository, path}}, entry
    end

    dir = workspace()
    branch = Path.join(git_dir(dir), "refs/heads/main")
    File.rm!(branch)
    File.ln_s!(Path.join(git_dir(workspace()), "refs/heads/main"), branch)
    assert Confinement.locate(dir, dir) == {:error, {:unsafe_repository, branch}}

    dir = workspace()
    alternates = Path.join(git_dir(dir), "objects/info/alternates")
    File.mkdir_p!(Path.dirname(alternates))
    File.write!(alternates, Path.join(git_dir(workspace()), "objects") <> "\n")

    assert Confinement.locate(dir, dir) ==
             {:error, {:unsafe_repository, Path.join(git_dir(dir), "objects/info/alternates")}}
  end

  test "formats refusals" do
    assert Confinement.format_error(:not_found) == "no Git repository in the workspace"
    assert Confinement.format_error({:outside_workspace, "/a", "/w"}) =~ "/a lies outside"
    assert Confinement.format_error({:unsafe_repository, "/w/.git"}) =~ "/w/.git is a symbolic"
  end
end
