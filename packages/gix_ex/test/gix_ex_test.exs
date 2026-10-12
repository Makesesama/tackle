defmodule GixExTest do
  use ExUnit.Case, async: true

  import GixEx.TestRepo

  alias GixEx.Commit

  setup context do
    %{dir: init!(context)}
  end

  describe "open/1" do
    test "finds the repository from a subdirectory", %{dir: dir} do
      write!(dir, "lib/a.txt", "a\n")
      commit!(dir, "first")

      {:ok, repo} = GixEx.open(Path.join(dir, "lib"))
      toplevel = dir |> git!(["rev-parse", "--show-toplevel"]) |> String.trim()

      assert repo.workdir == toplevel
      assert repo.git_dir == Path.join(toplevel, ".git")
      assert inspect(repo) == "#GixEx.Repository<#{toplevel}>"
    end

    test "refuses a working tree configured outside the repository", %{dir: dir} do
      commit!(dir, "first")
      elsewhere = dir <> "-elsewhere"
      Elixir.File.mkdir_p!(elsewhere)
      on_exit(fn -> Elixir.File.rm_rf!(elsewhere) end)
      git!(dir, ["config", "core.worktree", elsewhere])

      assert GixEx.open(dir) == {:error, :external_worktree}
      assert GixEx.open(Path.join(dir, ".git")) == {:error, :external_worktree}
    end

    test "does not pick up a bare repository nested in a checkout", %{dir: dir} do
      commit!(dir, "first")
      nested = Path.join(dir, "nested.git")
      git!(dir, ["init", "--quiet", "--bare", nested])

      {:ok, repo} = GixEx.open(Path.join(nested, "refs"))
      assert repo.workdir == dir |> git!(["rev-parse", "--show-toplevel"]) |> String.trim()

      # Opened explicitly, it is the bare repository.
      {:ok, bare} = GixEx.open(nested)
      assert bare.workdir == nil
    end

    test "fails outside a repository" do
      dir = Path.join(System.tmp_dir!(), "gix_ex-none-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      # A repository above the temporary directory would be found instead.
      if match?({_, 0}, System.cmd("git", ["rev-parse"], cd: dir, stderr_to_stdout: true)) do
        flunk("#{dir} is inside a git repository")
      end

      assert GixEx.open(dir) == {:error, :not_a_repository}
    end
  end

  describe "resolve/2 and merge_base/3" do
    test "resolve revisions to commits like git rev-parse", %{dir: dir} do
      first = commit!(dir, "first")
      second = commit!(dir, "second")
      git!(dir, ["tag", "--annotate", "v1", "--message", "v1", first])
      {:ok, repo} = GixEx.open(dir)

      assert GixEx.resolve(repo, "HEAD") == {:ok, second}
      assert GixEx.resolve(repo, "HEAD~1") == {:ok, first}
      assert GixEx.resolve(repo, "main") == {:ok, second}
      # An annotated tag is peeled to its commit.
      assert GixEx.resolve(repo, "v1") == {:ok, first}
      assert GixEx.resolve(repo, String.slice(second, 0, 10)) == {:ok, second}
      assert GixEx.resolve(repo, "missing") == {:error, {:unknown_revision, "missing"}}
      assert GixEx.resolve(repo, "HEAD^{tree}") == {:error, {:unknown_revision, "HEAD^{tree}"}}
    end

    test "finds the merge base of diverged branches", %{dir: dir} do
      base = commit!(dir, "base")
      git!(dir, ["switch", "--quiet", "--create", "feature"])
      commit!(dir, "feature")
      git!(dir, ["switch", "--quiet", "main"])
      commit!(dir, "main")
      {:ok, repo} = GixEx.open(dir)

      assert GixEx.merge_base(repo, "main", "feature") == {:ok, base}
      assert GixEx.merge_base(repo, "main", "nope") == {:error, {:unknown_revision, "nope"}}
    end

    test "reports unrelated histories", %{dir: dir} do
      commit!(dir, "main")
      git!(dir, ["switch", "--quiet", "--orphan", "other"])
      commit!(dir, "other")
      {:ok, repo} = GixEx.open(dir)

      assert GixEx.merge_base(repo, "main", "other") == {:error, :no_merge_base}
    end
  end

  describe "symbolic_ref/3" do
    test "returns the target, optionally shortened", %{dir: dir} do
      commit!(dir, "first")
      git!(dir, ["update-ref", "refs/remotes/origin/main", "HEAD"])
      git!(dir, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
      {:ok, repo} = GixEx.open(dir)

      assert GixEx.symbolic_ref(repo, "refs/remotes/origin/HEAD") ==
               {:ok, "refs/remotes/origin/main"}

      expected =
        dir |> git!(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) |> String.trim()

      assert GixEx.symbolic_ref(repo, "refs/remotes/origin/HEAD", short: true) == {:ok, expected}
      assert GixEx.symbolic_ref(repo, "HEAD", short: true) == {:ok, "main"}
    end

    test "fails for missing and direct references", %{dir: dir} do
      commit!(dir, "first")
      {:ok, repo} = GixEx.open(dir)

      assert GixEx.symbolic_ref(repo, "refs/remotes/origin/HEAD") ==
               {:error, {:reference_not_found, "refs/remotes/origin/HEAD"}}

      assert GixEx.symbolic_ref(repo, "refs/heads/main") ==
               {:error, {:not_symbolic, "refs/heads/main"}}
    end
  end

  describe "commits/4" do
    test "lists base..head newest first with git's subject and body", %{dir: dir} do
      base = commit!(dir, "base")
      one = commit!(dir, "first line\nstill the subject\n\n\nbody line 1\n\nbody line 2\n")
      two = commit!(dir, "\n\nsubject only \u00A0  \n")
      {:ok, repo} = GixEx.open(dir)

      {:ok, commits} = GixEx.commits(repo, base, "HEAD")
      log = git!(dir, ["log", "--format=%H%x1f%s%x1f%b%x1e", "#{base}..HEAD"])

      expected =
        log
        |> String.split("\x1e", trim: true)
        |> Enum.map(&String.trim_leading(&1, "\n"))
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn record ->
          [id, subject, body] = String.split(record, "\x1f")
          %Commit{id: id, subject: subject, body: body}
        end)

      assert commits == expected
      assert Enum.map(commits, & &1.id) == [two, one]
      assert hd(tl(commits)).subject == "first line still the subject"
    end

    test "walks the whole history without a base and honours :limit", %{dir: dir} do
      ids = for n <- 1..5, do: commit!(dir, "commit #{n}")
      {:ok, repo} = GixEx.open(dir)

      {:ok, all} = GixEx.commits(repo, nil, "HEAD")
      assert Enum.map(all, & &1.id) == Enum.reverse(ids)

      {:ok, limited} = GixEx.commits(repo, nil, "HEAD", limit: 2)
      assert Enum.map(limited, & &1.subject) == ["commit 5", "commit 4"]

      assert GixEx.commits(repo, "HEAD", "HEAD") == {:ok, []}
      assert_raise ArgumentError, fn -> GixEx.commits(repo, nil, "HEAD", limit: 0) end
    end
  end

  test "format_error/1 describes every reason" do
    for reason <- [
          :not_a_repository,
          :bare_repository,
          :external_worktree,
          {:unknown_revision, "x"},
          :no_merge_base,
          {:reference_not_found, "x"},
          {:not_symbolic, "x"},
          {:git, "boom"}
        ] do
      assert is_binary(GixEx.format_error(reason))
    end
  end
end
