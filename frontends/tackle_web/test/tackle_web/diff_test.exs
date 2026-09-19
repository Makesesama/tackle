defmodule Tackle.Web.DiffTest do
  use ExUnit.Case, async: true

  alias Tackle.Web.Diff
  alias Tackle.Web.GitFixture

  setup_all do
    repo = GitFixture.build()
    on_exit(fn -> File.rm_rf(repo) end)
    {:ok, repo: repo}
  end

  setup %{repo: repo} do
    {:ok, diff} = Diff.load(repo, "HEAD~1", "HEAD")
    %{diff: diff}
  end

  test "loads every changed file once", %{diff: diff} do
    assert paths(diff) == [
             "image.bin",
             "lib/added.ex",
             "lib/keep.ex",
             "lib/removed.ex",
             "lib/renamed_again.ex",
             "notes.txt"
           ]
  end

  test "records the commit range it compared", %{diff: diff} do
    assert diff.base_sha =~ ~r/^[0-9a-f]{40}$/
    assert diff.head_sha =~ ~r/^[0-9a-f]{40}$/
    refute diff.base_sha == diff.head_sha
  end

  test "classifies how each file changed", %{diff: diff} do
    assert file(diff, "lib/added.ex").status == :added
    assert file(diff, "lib/removed.ex").status == :deleted
    assert file(diff, "lib/keep.ex").status == :modified
    assert file(diff, "lib/renamed_again.ex").status == :renamed
  end

  test "reports the path a renamed file came from", %{diff: diff} do
    renamed = file(diff, "lib/renamed_again.ex")

    assert renamed.old_path == "lib/renamed.ex"
    assert renamed.new_path == "lib/renamed_again.ex"
  end

  test "counts additions and deletions per file and in total", %{diff: diff} do
    assert file(diff, "lib/added.ex").additions == 3
    assert file(diff, "lib/added.ex").deletions == 0
    assert file(diff, "lib/removed.ex").additions == 0
    assert file(diff, "lib/removed.ex").deletions == 2

    assert diff.additions == diff.files |> Enum.map(& &1.additions) |> Enum.sum()
    assert diff.deletions == diff.files |> Enum.map(& &1.deletions) |> Enum.sum()
  end

  test "highlights both sides of the change", %{diff: diff} do
    lines = diff |> file("lib/keep.ex") |> all_lines()

    added = Enum.find(lines, &(&1.kind == :add))
    removed = Enum.find(lines, &(&1.kind == :remove))

    # The colour has to come from the highlighter rather than the plain-text
    # fallback, on both the head and the base side.
    assert added.html =~ ~s[style="color:]
    assert removed.html =~ ~s[style="color:]
  end

  test "renders each line's source unchanged, with the marker stripped", %{diff: diff} do
    lines = diff |> file("lib/keep.ex") |> all_lines()

    added = Enum.find(lines, &(&1.kind == :add))
    removed = Enum.find(lines, &(&1.kind == :remove))

    assert code_text(added.html) == "  def two, do: 22"
    assert code_text(removed.html) == "  def two, do: 2"
  end

  test "numbers removed lines from the base side and added ones from the head side", %{
    diff: diff
  } do
    lines = diff |> file("lib/keep.ex") |> all_lines()

    added = Enum.find(lines, &(&1.kind == :add))
    removed = Enum.find(lines, &(&1.kind == :remove))

    assert added.old == nil
    assert is_integer(added.new)
    assert removed.new == nil
    assert is_integer(removed.old)
  end

  test "numbers a context line on both sides", %{diff: diff} do
    context = diff |> file("lib/keep.ex") |> all_lines() |> Enum.find(&(&1.kind == :context))

    assert context.old == context.new
    assert code_text(context.html) == "defmodule Keep do"
  end

  test "renders the no-newline marker as a note rather than a code line", %{diff: diff} do
    notes = diff |> file("notes.txt") |> all_lines() |> Enum.filter(&(&1.kind == :note))

    assert length(notes) == 2
    assert Enum.all?(notes, &(&1.text == "No newline at end of file"))
    assert Enum.all?(notes, &is_nil(&1.html))
    assert Enum.all?(notes, &(is_nil(&1.old) and is_nil(&1.new)))
  end

  test "leaves binary files without hunks instead of failing", %{diff: diff} do
    binary = file(diff, "image.bin")

    assert binary.hunks == []
    assert binary.status == :modified
  end

  describe "errors" do
    test "reports an unknown revision", %{repo: repo} do
      assert {:error, message} = Diff.load(repo, "HEAD~1", "does-not-exist")
      assert message =~ "unknown revision"
    end

    test "reports a path that is not a repository" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "tackle_web_not_a_repo_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:error, message} = Diff.load(dir, "HEAD~1", "HEAD")
      assert message =~ "not a git repository"
    end
  end

  defp paths(diff), do: diff.files |> Enum.map(& &1.path) |> Enum.sort()

  defp file(diff, path), do: Enum.find(diff.files, &(&1.path == path))

  defp all_lines(file), do: Enum.flat_map(file.hunks, & &1.lines)

  # Comparing the rendered line back to its source proves the highlighter
  # neither dropped nor duplicated characters while wrapping them in spans.
  defp code_text(html) do
    html
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end
end
