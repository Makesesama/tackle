defmodule GixEx.DiffTest do
  use ExUnit.Case, async: true

  import GixEx.TestRepo

  alias GixEx.Diff.{File, Hunk}

  setup context do
    dir = init!(context)
    %{dir: dir}
  end

  defp open!(dir) do
    {:ok, repo} = GixEx.open(dir)
    repo
  end

  defp numbered(range, prefix \\ "line"), do: Enum.map_join(range, &"#{prefix} #{&1}\n")

  describe "between commits" do
    test "matches git for modified, added, deleted, and renamed files", %{dir: dir} do
      write!(dir, "lib/app.ex", "defmodule App do\n" <> numbered(1..30, "  # line") <> "end\n")
      write!(dir, "README.md", "# App\n\nSome text.\n")
      write!(dir, "old_name.txt", numbered(1..20))
      write!(dir, "gone.txt", "bye\n")
      base = commit!(dir, "base")

      app =
        "defmodule App do\n" <>
          (numbered(1..30, "  # line")
           |> String.replace("  # line 2\n", "  # line two\n")
           |> String.replace("  # line 25\n", "  # line 25\n  # inserted\n")) <> "end\n"

      write!(dir, "lib/app.ex", app)
      write!(dir, "new.txt", "hello\nworld\n")
      Elixir.File.rm!(Path.join(dir, "gone.txt"))
      Elixir.File.rm!(Path.join(dir, "old_name.txt"))
      write!(dir, "new_name.txt", String.replace(numbered(1..20), "line 10\n", "line ten\n"))
      head = commit!(dir, "head")

      {:ok, files} = GixEx.diff(open!(dir), base, head)

      assert render(files) == git_diff(dir, [base, head])
      assert Enum.map(files, & &1.status) == [:deleted, :modified, :added, :renamed]

      renamed = Enum.find(files, &(&1.status == :renamed))
      assert renamed.old_path == "old_name.txt"
      assert renamed.path == "new_name.txt"
    end

    test "matches git for sections, hunk merging, and context sizes", %{dir: dir} do
      body = Enum.map_join(1..40, fn n -> "    value_#{n} = #{n}\n" end)
      write!(dir, "main.py", "def first():\n" <> body <> "\ndef second():\n" <> body)
      base = commit!(dir, "base")

      changed =
        "def first():\n" <>
          String.replace(body, "value_5 = 5", "value_5 = 50") <>
          "\ndef second():\n" <>
          (body
           |> String.replace("value_20 = 20", "value_20 = 200")
           |> String.replace("value_26 = 26", "value_26 = 260")
           |> String.replace("value_40 = 40\n", "value_40 = 40\n    extra = True\n"))

      write!(dir, "main.py", changed)
      head = commit!(dir, "head")
      repo = open!(dir)

      for context <- [0, 1, 3, 8] do
        {:ok, files} = GixEx.diff(repo, base, head, context: context)

        assert render(files) == git_diff(dir, [base, head], context: context),
               "context #{context}"
      end

      {:ok, [%File{hunks: hunks}]} = GixEx.diff(repo, base, head)
      assert Enum.map(hunks, & &1.section) == ["def first():", "def second():", "def second():"]
    end

    test "supports Myers' algorithm", %{dir: dir} do
      write!(dir, "a.txt", numbered(1..10))
      base = commit!(dir, "base")

      write!(
        dir,
        "a.txt",
        numbered(1..10) |> String.replace("line 4\n", "") |> Kernel.<>("end\n")
      )

      head = commit!(dir, "head")

      {:ok, [file]} = GixEx.diff(open!(dir), base, head, algorithm: :myers)
      assert {file.additions, file.deletions} == {1, 1}
    end

    test "numbers every line on its own side", %{dir: dir} do
      write!(dir, "a.txt", "one\ntwo\nthree\n")
      base = commit!(dir, "base")
      write!(dir, "a.txt", "one\n2\nthree\nfour")
      head = commit!(dir, "head")

      {:ok, [%File{hunks: [%Hunk{} = hunk]}]} = GixEx.diff(open!(dir), base, head)

      assert %Hunk{old_start: 1, old_count: 3, new_start: 1, new_count: 4} = hunk

      assert hunk.lines == [
               %{kind: :context, old: 1, new: 1, text: "one", no_newline: false},
               %{kind: :remove, old: 2, new: nil, text: "two", no_newline: false},
               %{kind: :add, old: nil, new: 2, text: "2", no_newline: false},
               %{kind: :context, old: 3, new: 3, text: "three", no_newline: false},
               %{kind: :add, old: nil, new: 4, text: "four", no_newline: true}
             ]
    end

    test "matches git for missing final newlines", %{dir: dir} do
      write!(dir, "a.txt", "one\ntwo")
      write!(dir, "b.txt", "one\ntwo\n")
      base = commit!(dir, "base")
      write!(dir, "a.txt", "one\ntwo\n")
      write!(dir, "b.txt", "one\n2")
      head = commit!(dir, "head")

      {:ok, files} = GixEx.diff(open!(dir), base, head)
      assert render(files) == git_diff(dir, [base, head])
    end

    test "reports binary files, mode changes, and empty files without hunks", %{dir: dir} do
      write!(dir, "image.bin", <<0, 1, 2, 3>>)
      write!(dir, "script.sh", "echo hi\n")
      base = commit!(dir, "base")

      write!(dir, "image.bin", <<0, 1, 2, 4>>)
      Elixir.File.chmod!(Path.join(dir, "script.sh"), 0o755)
      write!(dir, "empty.txt", "")
      head = commit!(dir, "head")

      {:ok, files} = GixEx.diff(open!(dir), base, head)
      assert render(files) == git_diff(dir, [base, head])

      assert [
               %File{path: "empty.txt", status: :added, new_mode: 0o100644, hunks: []},
               %File{path: "image.bin", binary: true, hunks: []},
               %File{path: "script.sh", old_mode: 0o100644, new_mode: 0o100755, hunks: []}
             ] = files
    end

    test "follows the diff attribute from .gitattributes, like git", %{dir: dir} do
      write!(dir, ".gitattributes", "*.dat -diff\n*.lock diff=lockfile\n*.txt diff\n")
      git!(dir, ["config", "diff.lockfile.binary", "true"])
      write!(dir, "data.dat", "one\n")
      write!(dir, "deps.lock", "one\n")
      write!(dir, "nul.txt", "one\n")
      base = commit!(dir, "base")
      write!(dir, "data.dat", "two\n")
      write!(dir, "deps.lock", "two\n")
      write!(dir, "nul.txt", "two\0\n")
      head = commit!(dir, "head")

      {:ok, files} = GixEx.diff(open!(dir), base, head)
      assert render(files) == git_diff(dir, [base, head])

      assert Enum.map(files, &{&1.path, &1.binary}) ==
               [{"data.dat", true}, {"deps.lock", true}, {"nul.txt", false}]
    end

    test "shows submodules as the commit they point at", %{dir: dir} do
      first = commit!(dir, "first")
      second = commit!(dir, "second")
      # `commit!/2` stages everything, which would drop the checkout-less
      # gitlink, so these commit the index as it is.
      git!(dir, ["update-index", "--add", "--cacheinfo", "160000,#{first},sub"])
      git!(dir, ["commit", "--quiet", "--message", "base"])
      base = dir |> git!(["rev-parse", "HEAD"]) |> String.trim()
      git!(dir, ["update-index", "--cacheinfo", "160000,#{second},sub"])
      git!(dir, ["commit", "--quiet", "--message", "head"])
      head = dir |> git!(["rev-parse", "HEAD"]) |> String.trim()

      {:ok, files} = GixEx.diff(open!(dir), base, head)
      assert render(files) == git_diff(dir, [base, head])
      assert [%File{path: "sub", old_mode: 0o160000, new_mode: 0o160000}] = files
    end

    test "treats files above :max_file_bytes as binary", %{dir: dir} do
      write!(dir, "big.txt", "small\n")
      base = commit!(dir, "base")
      write!(dir, "big.txt", String.duplicate("x", 100) <> "\n")
      head = commit!(dir, "head")

      {:ok, [file]} = GixEx.diff(open!(dir), base, head, max_file_bytes: 50)
      assert %File{binary: true, hunks: [], additions: 0, deletions: 0} = file
    end

    test "splits a change between file and symlink into deletion and addition", %{dir: dir} do
      write!(dir, "target.txt", "target\n")
      write!(dir, "link", "a file\n")
      base = commit!(dir, "base")
      Elixir.File.rm!(Path.join(dir, "link"))
      Elixir.File.ln_s!("target.txt", Path.join(dir, "link"))
      head = commit!(dir, "head")

      {:ok, files} = GixEx.diff(open!(dir), base, head)

      assert [
               %File{path: "link", status: :deleted, old_mode: 0o100644},
               %File{path: "link", status: :added, new_mode: 0o120000} = added
             ] = files

      assert [%Hunk{lines: [%{text: "target.txt", no_newline: true}]}] = added.hunks

      patch = git!(dir, ["diff", "--no-color", base, head])
      rendered = files |> render() |> Enum.map_join(& &1.hunks)

      assert rendered ==
               patch |> String.split(~r/^(?=@@ )/m) |> tl() |> Enum.map_join(&strip_headers/1)
    end

    test "detects renames among many moved files, as git's rename limit allows", %{dir: dir} do
      for n <- 1..40, do: write!(dir, "old/file_#{n}.ex", numbered(1..20, "module #{n} line"))
      base = commit!(dir, "base")
      Elixir.File.rm_rf!(Path.join(dir, "old"))

      for n <- 1..40 do
        content = String.replace(numbered(1..20, "module #{n} line"), "line 3\n", "line three\n")
        write!(dir, "new/file_#{n}.ex", content)
      end

      head = commit!(dir, "head")

      {:ok, files} = GixEx.diff(open!(dir), base, head)
      assert render(files) == git_diff(dir, [base, head])
      assert length(files) == 40
      assert Enum.all?(files, &(&1.status == :renamed))
    end

    test "can disable rename detection", %{dir: dir} do
      write!(dir, "a.txt", numbered(1..10))
      base = commit!(dir, "base")
      Elixir.File.rename!(Path.join(dir, "a.txt"), Path.join(dir, "b.txt"))
      head = commit!(dir, "head")
      repo = open!(dir)

      {:ok, [%File{status: :renamed, hunks: []}]} = GixEx.diff(repo, base, head)

      {:ok, files} = GixEx.diff(repo, base, head, renames: false)
      assert Enum.map(files, &{&1.status, &1.path}) == [{:deleted, "a.txt"}, {:added, "b.txt"}]
    end

    test "includes both versions with :contents", %{dir: dir} do
      write!(dir, "a.txt", "old\n")
      base = commit!(dir, "base")
      write!(dir, "a.txt", "new\n")
      write!(dir, "bin", <<0>>)
      head = commit!(dir, "head")
      repo = open!(dir)

      {:ok, [a, bin]} = GixEx.diff(repo, base, head, contents: true)
      assert {a.old_content, a.new_content} == {"old\n", "new\n"}
      assert {bin.old_content, bin.new_content} == {nil, nil}

      {:ok, [a, _bin]} = GixEx.diff(repo, base, head)
      assert {a.old_content, a.new_content} == {nil, nil}
    end

    test "accepts trees and the empty tree", %{dir: dir} do
      write!(dir, "a.txt", "a\n")
      head = commit!(dir, "first")
      repo = open!(dir)

      {:ok, from_empty} = GixEx.diff(repo, :empty, head)
      assert render(from_empty) == git_diff(dir, [GixEx.empty_tree(repo), head])
      assert {:ok, ^from_empty} = GixEx.diff(repo, :empty, "HEAD^{tree}")
      assert {:ok, []} = GixEx.diff(repo, head, head)
    end
  end

  describe "against the working tree" do
    test "matches git diff REV for modified, deleted, and intent-to-add files", %{dir: dir} do
      write!(dir, "a.txt", numbered(1..10))
      write!(dir, "b.txt", "b\n")
      write!(dir, "c.txt", "c\n")
      base = commit!(dir, "base")
      write!(dir, "a.txt", "line 0\n" <> numbered(1..10))
      head = commit!(dir, "head")

      write!(dir, "b.txt", "b changed\n")
      Elixir.File.rm!(Path.join(dir, "c.txt"))
      write!(dir, "added.txt", "added\n")
      git!(dir, ["add", "--intent-to-add", "added.txt"])
      write!(dir, "untracked.txt", "untracked\n")

      repo = open!(dir)
      {:ok, files} = GixEx.diff(repo, base, :worktree)
      assert render(files) == git_diff(dir, [base])
      assert Enum.map(files, & &1.path) == ["a.txt", "added.txt", "b.txt", "c.txt"]

      {:ok, files} = GixEx.diff(repo, head, :worktree)
      assert render(files) == git_diff(dir, [head])
    end

    test "sees a same-size change made right after the index was written", %{dir: dir} do
      write!(dir, "a.txt", "aaaa\n")
      head = commit!(dir, "head")
      write!(dir, "a.txt", "bbbb\n")

      {:ok, files} = GixEx.diff(open!(dir), head, :worktree)
      assert render(files) == git_diff(dir, [head])
      assert [%File{path: "a.txt", additions: 1, deletions: 1}] = files
    end

    test "reports a worktree rename of a staged deletion and an untracked add", %{dir: dir} do
      write!(dir, "a.txt", numbered(1..10))
      head = commit!(dir, "head")
      git!(dir, ["mv", "a.txt", "b.txt"])

      {:ok, files} = GixEx.diff(open!(dir), head, :worktree)
      assert render(files) == git_diff(dir, [head])
      assert [%File{status: :renamed, old_path: "a.txt", path: "b.txt"}] = files
    end

    test "treats a tracked path below a symbolic link as deleted, like git", %{dir: dir} do
      write!(dir, "dir/secret.txt", "tracked\n")
      write!(dir, "keep.txt", "keep\n")
      head = commit!(dir, "head")

      outside = dir <> "-outside"
      on_exit(fn -> Elixir.File.rm_rf!(outside) end)
      write!(outside, "secret.txt", "outside the repository\n")
      Elixir.File.rm_rf!(Path.join(dir, "dir"))
      Elixir.File.ln_s!(outside, Path.join(dir, "dir"))

      {:ok, files} = GixEx.diff(open!(dir), head, :worktree, contents: true)
      assert render(files) == git_diff(dir, [head])
      assert [%File{path: "dir/secret.txt", status: :deleted, new_content: nil}] = files
    end

    test "treats a FIFO or a directory in place of a tracked file as deleted", %{dir: dir} do
      write!(dir, "fifo", "was a file\n")
      write!(dir, "dir", "was a file\n")
      write!(dir, "keep.txt", "keep\n")
      head = commit!(dir, "head")

      Elixir.File.rm!(Path.join(dir, "fifo"))
      {_, 0} = System.cmd("mkfifo", [Path.join(dir, "fifo")])
      Elixir.File.rm!(Path.join(dir, "dir"))
      write!(dir, "dir/inside.txt", "untracked\n")

      {:ok, files} = GixEx.diff(open!(dir), head, :worktree)
      assert Enum.map(files, &{&1.path, &1.status}) == [{"dir", :deleted}, {"fifo", :deleted}]
    end

    test "bounds working-tree files by :max_file_bytes", %{dir: dir} do
      big = String.duplicate("x", 200) <> "\n"
      write!(dir, "big.txt", big)
      write!(dir, "same.txt", big)
      head = commit!(dir, "head")

      write!(dir, "big.txt", String.duplicate("y", 200) <> "\n")
      # Rewritten with the same content: the stat data changes, the content not.
      Elixir.File.write!(Path.join(dir, "same.txt"), big)
      Elixir.File.touch!(Path.join(dir, "same.txt"), System.os_time(:second) + 5)

      {:ok, files} = GixEx.diff(open!(dir), head, :worktree, max_file_bytes: 100, contents: true)

      assert [%File{path: "big.txt", status: :modified, binary: true, hunks: []} = big_file] =
               files

      assert {big_file.old_content, big_file.new_content} == {nil, nil}
    end

    test "ignores assume-unchanged and skip-worktree entries, like git", %{dir: dir} do
      write!(dir, "assumed.txt", "a\n")
      write!(dir, "skipped.txt", "s\n")
      head = commit!(dir, "head")
      git!(dir, ["update-index", "--assume-unchanged", "assumed.txt"])
      git!(dir, ["update-index", "--skip-worktree", "skipped.txt"])
      write!(dir, "assumed.txt", "changed\n")
      write!(dir, "skipped.txt", "changed\n")

      {:ok, files} = GixEx.diff(open!(dir), head, :worktree)
      assert files == []
      assert render(files) == git_diff(dir, [head])
    end

    test "honours core.fileMode=false", %{dir: dir} do
      write!(dir, "script.sh", "echo\n")
      head = commit!(dir, "head")
      git!(dir, ["config", "core.fileMode", "false"])
      Elixir.File.chmod!(Path.join(dir, "script.sh"), 0o755)

      assert {:ok, []} = GixEx.diff(open!(dir), head, :worktree)
      assert git_diff(dir, [head]) == []
    end

    test "works in a linked worktree", %{dir: dir} do
      write!(dir, "a.txt", "a\n")
      head = commit!(dir, "head")
      linked = dir <> "-linked"
      on_exit(fn -> Elixir.File.rm_rf!(linked) end)
      git!(dir, ["worktree", "add", "--quiet", "--detach", linked])
      write!(linked, "a.txt", "changed\n")

      {:ok, repo} = GixEx.open(linked)
      assert repo.workdir == linked |> git!(["rev-parse", "--show-toplevel"]) |> String.trim()
      {:ok, files} = GixEx.diff(repo, head, :worktree)
      assert render(files) == git_diff(linked, [head])
      assert [%File{path: "a.txt", status: :modified}] = files
    end

    test "uses the working-tree version of an unmerged path", %{dir: dir} do
      conflict!(dir)

      {:ok, files} = GixEx.diff(open!(dir), "HEAD", :worktree)
      assert render(files) == git_diff(dir, ["HEAD"])
      assert [%File{path: "a.txt", status: :modified, additions: 4}] = files
    end

    test "fails for a bare repository", %{dir: dir} do
      write!(dir, "a.txt", "a\n")
      commit!(dir, "head")
      bare = dir <> ".git-bare"
      git!(dir, ["clone", "--quiet", "--bare", dir, bare])
      on_exit(fn -> Elixir.File.rm_rf!(bare) end)

      {:ok, repo} = GixEx.open(bare)
      assert repo.workdir == nil
      assert GixEx.diff(repo, "HEAD", :worktree) == {:error, :bare_repository}
    end
  end

  describe "against the index" do
    test "matches git diff --cached", %{dir: dir} do
      write!(dir, "a.txt", numbered(1..5))
      head = commit!(dir, "head")
      write!(dir, "a.txt", numbered(1..6))
      write!(dir, "staged.txt", "staged\n")
      git!(dir, ["add", "a.txt", "staged.txt"])
      write!(dir, "a.txt", "unstaged\n")
      write!(dir, "later.txt", "later\n")
      git!(dir, ["add", "--intent-to-add", "later.txt"])

      {:ok, files} = GixEx.diff(open!(dir), head, :index)
      assert render(files) == git_diff(dir, ["--cached", head])
    end

    test "reports unmerged paths like git diff --cached", %{dir: dir} do
      conflict!(dir)
      write!(dir, "other.txt", "staged\n")
      git!(dir, ["add", "other.txt"])

      {:ok, files} = GixEx.diff(open!(dir), "HEAD", :index)

      assert [
               %File{path: "a.txt", old_path: "a.txt", status: :unmerged, hunks: []},
               %File{path: "other.txt", status: :added}
             ] = files

      assert dir
             |> git!(["diff", "--cached", "--name-status", "HEAD"])
             |> String.split("\n", trim: true) ==
               ["U\ta.txt", "A\tother.txt"]
    end

    test "handles a sparse index", %{dir: dir} do
      write!(dir, "in/a.txt", "a\n")
      write!(dir, "out/b.txt", "b\n")
      write!(dir, "top.txt", "top\n")
      head = commit!(dir, "head")
      git!(dir, ["sparse-checkout", "init", "--cone", "--sparse-index"])
      git!(dir, ["sparse-checkout", "set", "in"])
      write!(dir, "in/a.txt", "changed\n")
      git!(dir, ["add", "in/a.txt"])
      repo = open!(dir)

      {:ok, staged} = GixEx.diff(repo, head, :index)
      assert render(staged) == git_diff(dir, ["--cached", head])
      {:ok, worktree} = GixEx.diff(repo, head, :worktree)
      assert render(worktree) == git_diff(dir, [head])
      assert [%File{path: "in/a.txt"}] = worktree
    end

    test "compares the empty tree before the first commit", %{dir: dir} do
      write!(dir, "a.txt", "a\n")
      git!(dir, ["add", "a.txt"])
      repo = open!(dir)

      assert GixEx.resolve(repo, "HEAD") == {:error, {:unknown_revision, "HEAD"}}
      {:ok, files} = GixEx.diff(repo, :empty, :index)
      assert render(files) == git_diff(dir, ["--cached", GixEx.empty_tree(repo)])
    end
  end

  test "does not run filters or textconv configured by the repository", %{dir: dir} do
    marker = Path.join(dir, "executed")
    write!(dir, ".gitattributes", "* filter=evil diff=evil\n")
    write!(dir, "a.txt", "a\n")
    write!(dir, "b.txt", numbered(1..10))
    head = commit!(dir, "head")

    write!(dir, "a.txt", "changed\n")
    # A rename with changes makes the diff score similarity, which reads blobs
    # through gix's diff pipeline.
    Elixir.File.rename!(Path.join(dir, "b.txt"), Path.join(dir, "renamed.txt"))
    write!(dir, "renamed.txt", numbered(1..9) <> "line ten\n")
    git!(dir, ["add", "--all", "--intent-to-add"])

    # Configured last: git itself would run them.
    git!(dir, ["config", "filter.evil.clean", "touch #{marker}; cat"])
    git!(dir, ["config", "filter.evil.smudge", "touch #{marker}; cat"])
    git!(dir, ["config", "diff.evil.textconv", "touch #{marker}; cat"])
    git!(dir, ["config", "diff.external", "touch #{marker}"])
    repo = open!(dir)

    assert {:ok, files} = GixEx.diff(repo, head, :worktree)

    assert Enum.map(files, &{&1.status, &1.path}) == [
             {:modified, "a.txt"},
             {:renamed, "renamed.txt"}
           ]

    # `add --all` staged the deletion; the new name is only intended.
    assert {:ok, [%File{path: "b.txt", status: :deleted}]} = GixEx.diff(repo, head, :index)
    refute Elixir.File.exists?(marker)
  end

  test "rejects invalid sides and options", %{dir: dir} do
    commit!(dir, "head")
    repo = open!(dir)

    assert_raise ArgumentError, fn -> GixEx.diff(repo, :worktree, "HEAD") end
    assert_raise ArgumentError, fn -> GixEx.diff(repo, "HEAD", :other) end
    assert_raise ArgumentError, fn -> GixEx.diff(repo, "HEAD", "HEAD", context: -1) end
    assert_raise ArgumentError, fn -> GixEx.diff(repo, "HEAD", "HEAD", renames: 2) end
    assert_raise ArgumentError, fn -> GixEx.diff(repo, "HEAD", "HEAD", bogus: true) end
    assert GixEx.diff(repo, "nope", "HEAD") == {:error, {:unknown_revision, "nope"}}
  end

  # Leaves a.txt conflicted between main and a feature branch.
  defp conflict!(dir) do
    write!(dir, "a.txt", "base\n")
    commit!(dir, "base")
    git!(dir, ["switch", "--quiet", "--create", "feature"])
    write!(dir, "a.txt", "feature\n")
    commit!(dir, "feature")
    git!(dir, ["switch", "--quiet", "main"])
    write!(dir, "a.txt", "main\n")
    commit!(dir, "main")

    {_output, 1} =
      System.cmd("git", ["merge", "feature"], cd: dir, env: git_env(), stderr_to_stdout: true)
  end

  defp strip_headers(hunk), do: String.replace(hunk, ~r/^diff --git .*\z/ms, "")
end
