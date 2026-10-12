defmodule Tackle.Review.DiffTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.Diff

  doctest Diff

  defp parse!(text) do
    assert {:ok, %Diff{files: files}} = Diff.parse(text)
    files
  end

  defp summary(lines), do: Enum.map(lines, &{&1.kind, &1.old, &1.new, &1.text})

  test "empty text is an empty diff" do
    assert Diff.parse("") == {:ok, %Diff{files: []}}
  end

  test "parses a modified file with several hunks and absolute line numbers" do
    [file] =
      parse!("""
      diff --git a/lib/a.ex b/lib/a.ex
      index 1111111..2222222 100644
      --- a/lib/a.ex
      +++ b/lib/a.ex
      @@ -1,3 +1,3 @@ defmodule A do
       one
      -two
      +TWO
       three
      @@ -10,2 +10,4 @@ def other
       ten
      +eleven
      +twelve
       last
      """)

    assert %{path: "lib/a.ex", old_path: "lib/a.ex", status: :modified, binary: false} = file
    assert {file.additions, file.deletions} == {3, 1}
    assert {file.old_content, file.new_content} == {nil, nil}

    assert [first, second] = file.hunks
    assert first.header == "@@ -1,3 +1,3 @@ defmodule A do"
    assert {first.old_start, first.old_count, first.new_start, first.new_count} == {1, 3, 1, 3}
    assert first.section == "defmodule A do"

    assert summary(first.lines) == [
             {:context, 1, 1, "one"},
             {:remove, 2, nil, "two"},
             {:add, nil, 2, "TWO"},
             {:context, 3, 3, "three"}
           ]

    assert summary(second.lines) == [
             {:context, 10, 10, "ten"},
             {:add, nil, 11, "eleven"},
             {:add, nil, 12, "twelve"},
             {:context, 11, 13, "last"}
           ]
  end

  test "parses new, deleted, and renamed files" do
    files =
      parse!("""
      diff --git a/new.ex b/new.ex
      new file mode 100644
      index 0000000..1111111
      --- /dev/null
      +++ b/new.ex
      @@ -0,0 +1,2 @@
      +a
      +b
      diff --git a/gone.ex b/gone.ex
      deleted file mode 100644
      index 1111111..0000000
      --- a/gone.ex
      +++ /dev/null
      @@ -1 +0,0 @@
      -bye
      diff --git a/old name.ex b/new name.ex
      similarity index 80%
      rename from old name.ex
      rename to new name.ex
      index 1111111..2222222 100644
      --- a/old name.ex\t
      +++ b/new name.ex\t
      @@ -1 +1 @@
      -x
      +y
      diff --git a/same.ex b/moved/same.ex
      similarity index 100%
      rename from same.ex
      rename to moved/same.ex
      """)

    assert [added, deleted, renamed, pure_rename] = files

    assert %{path: "new.ex", old_path: nil, status: :added, additions: 2} = added
    assert summary(hd(added.hunks).lines) == [{:add, nil, 1, "a"}, {:add, nil, 2, "b"}]

    assert %{path: "gone.ex", old_path: "gone.ex", status: :deleted, deletions: 1} = deleted
    assert summary(hd(deleted.hunks).lines) == [{:remove, 1, nil, "bye"}]

    assert %{path: "new name.ex", old_path: "old name.ex", status: :renamed} = renamed

    assert %{path: "moved/same.ex", old_path: "same.ex", status: :renamed, hunks: []} =
             pure_rename
  end

  test "parses copies and mode changes" do
    [copy, mode] =
      parse!("""
      diff --git a/a.ex b/b.ex
      similarity index 100%
      copy from a.ex
      copy to b.ex
      diff --git a/run.sh b/run.sh
      old mode 100644
      new mode 100755
      """)

    assert %{path: "b.ex", old_path: "a.ex", status: :copied} = copy
    assert %{path: "run.sh", old_path: "run.sh", status: :modified, hunks: []} = mode
  end

  test "marks binary files from either binary marker" do
    [changed, added] =
      parse!("""
      diff --git a/image.png b/image.png
      index 1111111..2222222 100644
      Binary files a/image.png and b/image.png differ
      diff --git a/blob.bin b/blob.bin
      new file mode 100644
      index 0000000..1111111
      GIT binary patch
      literal 4
      LcmZQzWMT#Y01f~L

      literal 0
      HcmV?d00001

      """)

    assert %{path: "image.png", status: :modified, binary: true, hunks: []} = changed
    assert %{path: "blob.bin", old_path: nil, status: :added, binary: true, hunks: []} = added
  end

  test "attaches no-newline notes to the line they annotate" do
    [file] =
      parse!("""
      diff --git a/n.txt b/n.txt
      --- a/n.txt
      +++ b/n.txt
      @@ -1,2 +1,2 @@
       first
      -old
      \\ No newline at end of file
      +new
      \\ No newline at end of file
      """)

    assert [
             %{kind: :context, no_newline: false},
             %{kind: :remove, text: "old", no_newline: true},
             %{kind: :add, text: "new", no_newline: true}
           ] = hd(file.hunks).lines
  end

  test "reads hunk content by its counts, even when it looks like a header" do
    [file, next] =
      parse!("""
      diff --git a/sql.sql b/sql.sql
      --- a/sql.sql
      +++ b/sql.sql
      @@ -1,2 +1,2 @@
      --- a comment
      +++ a counter
       @@ not a header
      diff --git a/b.txt b/b.txt
      --- a/b.txt
      +++ b/b.txt
      @@ -1 +1 @@
      -b
      +c
      """)

    assert summary(hd(file.hunks).lines) == [
             {:remove, 1, nil, "-- a comment"},
             {:add, nil, 1, "++ a counter"},
             {:context, 2, 2, "@@ not a header"}
           ]

    assert next.path == "b.txt"
  end

  test "accepts empty context lines without their leading space" do
    [file] = parse!("--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n a\n\n-b\n+c\n")

    assert summary(hd(file.hunks).lines) == [
             {:context, 1, 1, "a"},
             {:context, 2, 2, ""},
             {:remove, 3, nil, "b"},
             {:add, nil, 3, "c"}
           ]
  end

  test "unquotes C-quoted paths" do
    [file] =
      parse!("""
      diff --git "a/caf\\303\\251.txt" "b/tab\\there.txt"
      similarity index 100%
      rename from "caf\\303\\251.txt"
      rename to "tab\\there.txt"
      """)

    assert file.old_path == "café.txt"
    assert file.path == "tab\there.txt"
  end

  test "takes paths from the diff --git line when nothing else names them" do
    [spaced, quoted] =
      parse!("""
      diff --git a/dir with space/a b.bin b/dir with space/a b.bin
      Binary files a/dir with space/a b.bin and b/dir with space/a b.bin differ
      diff --git a/plain.bin "b/\\303\\251.bin"
      Binary files a/plain.bin and "b/\\303\\251.bin" differ
      """)

    assert spaced.path == "dir with space/a b.bin"
    assert spaced.old_path == "dir with space/a b.bin"
    assert {quoted.old_path, quoted.path} == {"plain.bin", "é.bin"}
  end

  test "parses plain unified diffs and ignores text before the first file" do
    files =
      parse!("""
      warning: in the working copy of 'x', LF will be replaced by CRLF
      --- a.txt\t2024-01-01 00:00:00
      +++ a.txt\t2024-01-02 00:00:00
      @@ -1 +1 @@
      -a
      +b
      --- /dev/null
      +++ b.txt
      @@ -0,0 +1 @@
      +new
      """)

    assert [%{path: "a.txt", status: :modified}, %{path: "b.txt", status: :added}] = files
  end

  test "rejects an invalid hunk header" do
    assert Diff.parse("--- a/x\n+++ b/x\n@@ -1 +1\n-a\n") ==
             {:error, {:malformed_diff, 3, "invalid hunk header"}}
  end

  test "rejects a hunk that ends before its counts" do
    assert Diff.parse("--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n a\n") ==
             {:error, {:malformed_diff, 3, "hunk ends before its line counts"}}
  end

  test "rejects lines that do not fit the hunk" do
    assert Diff.parse("--- a/x\n+++ b/x\n@@ -1 +1,2 @@\n a\n-b\n") ==
             {:error, {:malformed_diff, 5, "unexpected line in hunk"}}
  end
end
