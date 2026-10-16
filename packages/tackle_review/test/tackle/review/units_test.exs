defmodule Tackle.Review.UnitsTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.{Change, Diff, Units}
  alias Tackle.Review.Test.GitRepo

  @base String.duplicate("a", 40)
  @head String.duplicate("b", 40)

  defp change(diff_text, opts \\ []) do
    {:ok, diff} = Diff.parse(diff_text)

    %Change{
      cwd: "/repo",
      root: "/repo",
      mode: Keyword.get(opts, :mode, :range),
      base_ref: Keyword.get(opts, :base_ref, "main"),
      base_sha: @base,
      head_sha: Keyword.get(opts, :head_sha, @head),
      diff: diff,
      commits: Keyword.get(opts, :commits, [])
    }
  end

  defp split!(change, opts \\ []) do
    assert {:ok, result} = Units.split(change, opts)
    result
  end

  defp code_units(result), do: Enum.filter(result.units, &(&1.kind == :code))

  # A diff of `path` whose single hunk adds `count` lines after line `after_line`.
  defp added_lines(path, after_line, count, prefix \\ "line") do
    body = Enum.map_join(1..count, "", &"+#{prefix}#{&1}\n")

    """
    diff --git a/#{path} b/#{path}
    --- a/#{path}
    +++ b/#{path}
    @@ -#{after_line},0 +#{after_line + 1},#{count} @@
    #{body}\
    """
  end

  # Commits `old`, writes `new` over it, and loads the change.
  defp git_change(old, new) do
    dir = GitRepo.init()
    GitRepo.write(dir, old)
    GitRepo.commit(dir, "base")
    GitRepo.write(dir, new)
    assert {:ok, change} = Change.load(cwd: dir)
    change
  end

  test "an empty change has no units" do
    assert split!(change("")) == %{units: [], skipped: []}
  end

  test "renders lines with absolute numbers" do
    result =
      split!(
        change("""
        diff --git a/lib/a.ex b/lib/a.ex
        --- a/lib/a.ex
        +++ b/lib/a.ex
        @@ -8,4 +8,4 @@
         eight
        -nine
        +NINE
         ten
         eleven
        \\ No newline at end of file
        """)
      )

    assert [unit] = code_units(result)

    assert unit.rendered == """
           File: lib/a.ex

           [   8] eight
           [-  9] nine
           [+  9] NINE
           [  10] ten
           [  11] eleven
           \\ No newline at end of file
           """

    assert %{id: "lib/a.ex#1", path: "lib/a.ex", status: :modified, changed_lines: 2} = unit
    assert unit.side_ranges == %{old: [8..11], new: [8..11]}
    assert unit.changed_ranges == %{old: [9..9], new: [9..9]}
    assert Enum.count(unit.lines) == 5
  end

  test "skips files not worth a line-by-line review" do
    diff =
      Enum.join([
        added_lines("mix.lock", 0, 1),
        added_lines("assets/package-lock.json", 0, 1),
        added_lines("deps/jason/lib/jason.ex", 0, 1),
        added_lines("priv/static/app.min.js", 0, 1),
        added_lines("generated/api.ex", 0, 1),
        """
        diff --git a/logo.png b/logo.png
        Binary files a/logo.png and b/logo.png differ
        diff --git a/lib/gone.ex b/lib/gone.ex
        deleted file mode 100644
        --- a/lib/gone.ex
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone
        diff --git a/lib/old.ex b/lib/moved.ex
        similarity index 100%
        rename from lib/old.ex
        rename to lib/moved.ex
        """,
        added_lines("lib/kept.ex", 0, 2)
      ])

    result = split!(change(diff), exclude: ["generated/"])

    assert result.skipped == [
             %{path: "mix.lock", reason: :lock_file},
             %{path: "assets/package-lock.json", reason: :lock_file},
             %{path: "deps/jason/lib/jason.ex", reason: :vendored},
             %{path: "priv/static/app.min.js", reason: :generated},
             %{path: "generated/api.ex", reason: :excluded},
             %{path: "logo.png", reason: :binary},
             %{path: "lib/gone.ex", reason: :deleted},
             %{path: "lib/moved.ex", reason: :no_content}
           ]

    assert [%{id: "lib/kept.ex#1", status: :modified}] = code_units(result)
  end

  test "user excludes take precedence over built-in reasons" do
    result = split!(change(added_lines("mix.lock", 0, 1)), exclude: ["mix.lock"])
    assert result.skipped == [%{path: "mix.lock", reason: :excluded}]
  end

  test "rejects invalid exclude globs and numeric options" do
    assert Units.split(change(""), exclude: ["{a"]) ==
             {:error, {:invalid_glob, "{a", "unbalanced {"}}

    assert_raise ArgumentError, ~r/max_changed_lines/, fn ->
      Units.split(change(""), max_changed_lines: 0)
    end
  end

  test "expands hunks to the enclosing function" do
    old = """
    defmodule Shop do
      @moduledoc "A shop."

      def total(items) do
        items
        |> Enum.map(& &1.price)
        |> Enum.sum()
      end

      @doc "Applies a discount."
      def discount(total, percent) do
        rate = percent / 100
        total - total * rate
      end

      def tax(total), do: total * 0.2
    end
    """

    change =
      git_change(%{"lib/shop.ex" => old}, %{
        "lib/shop.ex" =>
          String.replace(old, "rate = percent / 100", "rate = min(percent, 100) / 100")
      })

    assert [unit] = change |> split!() |> code_units()

    # The function with its documentation, not the whole module; as with
    # `git diff -W`, the hunk's own context lines (blank here) stay.
    assert unit.side_ranges == %{old: [9..15], new: [9..15]}

    assert unit.rendered =~ """
           [  10]   @doc "Applies a discount."
           [  11]   def discount(total, percent) do
           [- 12]     rate = percent / 100
           [+ 12]     rate = min(percent, 100) / 100
           [  13]     total - total * rate
           [  14]   end
           """

    refute unit.rendered =~ "defmodule"
    refute unit.rendered =~ "def tax"
  end

  test "falls back to nearby lines when the function is too large" do
    # One function of 100 lines with changes at lines 10 and 90.
    lines = ["int big(void)" | Enum.map(2..100, &"\tctx#{&1};")]
    old = Enum.join(lines, "\n") <> "\n"

    new =
      lines
      |> List.replace_at(9, "\tnew10;")
      |> List.replace_at(89, "\tnew90;")
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    change = git_change(%{"big.c" => old}, %{"big.c" => new})

    assert [unit] = change |> split!() |> code_units()

    assert unit.side_ranges == %{old: [7..13, 87..93], new: [7..13, 87..93]}
    assert unit.changed_ranges == %{old: [10..10, 90..90], new: [10..10, 90..90]}
    assert unit.rendered =~ "[  13] \tctx13;\n...\n[  87] \tctx87;\n"

    # A larger allowance keeps the whole function.
    assert [whole] = change |> split!(min_context: 100) |> code_units()

    assert whole.side_ranges.new == [1..100]
  end

  test "keeps the plain hunks of files without contents" do
    diff = """
    --- a/a.ex
    +++ b/a.ex
    @@ -10,3 +10,3 @@
       def f do
    -    1
    +    2
       end
    """

    assert [unit] = diff |> change() |> split!() |> code_units()
    assert unit.side_ranges.new == [10..12]
  end

  test "splits large pieces into evenly sized units" do
    assert [%{changed_lines: 120}] =
             change(added_lines("lib/big.ex", 0, 120)) |> split!() |> code_units()

    result = split!(change(added_lines("lib/big.ex", 0, 120)), max_changed_lines: 50)

    assert [first, second, third] = code_units(result)

    assert Enum.map([first, second, third], & &1.id) == [
             "lib/big.ex#1",
             "lib/big.ex#2",
             "lib/big.ex#3"
           ]

    assert Enum.map([first, second, third], & &1.changed_lines) == [40, 40, 40]
    assert first.changed_ranges.new == [1..40]
    assert third.changed_ranges.new == [81..120]

    assert [_one, _two] =
             change(added_lines("lib/big.ex", 0, 120))
             |> split!(max_changed_lines: 60)
             |> code_units()
  end

  describe "batch/2" do
    test "groups code units of several files up to the budget, keeping diff order" do
      units = [
        %{id: "change", kind: :change, changed_lines: 500},
        %{id: "a#1", kind: :code, changed_lines: 30},
        %{id: "b#1", kind: :code, changed_lines: 50},
        %{id: "c#1", kind: :code, changed_lines: 30},
        %{id: "d#1", kind: :code, changed_lines: 200},
        %{id: "e#1", kind: :code, changed_lines: 10}
      ]

      assert units |> Units.batch(100) |> Enum.map(fn batch -> Enum.map(batch, & &1.id) end) ==
               [["change"], ["a#1", "b#1"], ["c#1"], ["d#1"], ["e#1"]]

      assert units |> Units.batch(1) |> length() == 6
      assert Units.batch([], 100) == []
    end
  end

  test "validate_options/1 checks sizing options without raising" do
    assert :ok = Units.validate_options(max_changed_lines: 200, min_context: 0)

    assert {:error, {:invalid_option, :max_changed_lines, 0}} =
             Units.validate_options(max_changed_lines: 0)

    assert {:error, {:invalid_option, :context_ratio, "4"}} =
             Units.validate_options(context_ratio: "4")

    assert {:error, {:unknown_options, [:exclude]}} = Units.validate_options(exclude: [])
  end

  test "packs small pieces of one file into a unit up to the cap" do
    diff = """
    --- a/a.ex
    +++ b/a.ex
    @@ -1,0 +2,2 @@
    +a
    +b
    @@ -20,0 +23,2 @@
    +c
    +d
    @@ -40,0 +45,2 @@
    +e
    +f
    """

    assert [unit] = diff |> change() |> split!() |> code_units()
    assert unit.changed_ranges.new == [2..3, 23..24, 45..46]
    assert unit.rendered =~ "[+  3] b\n...\n[+ 23] c\n"

    assert [first, second] = diff |> change() |> split!(max_changed_lines: 4) |> code_units()
    assert first.changed_ranges.new == [2..3, 23..24]
    assert second.changed_ranges.new == [45..46]
  end

  test "units never mix files" do
    diff = added_lines("a.ex", 0, 1) <> added_lines("b.ex", 0, 1)
    assert [%{id: "a.ex#1"}, %{id: "b.ex#1"}] = diff |> change() |> split!() |> code_units()
  end

  test "adds a change-level unit first" do
    diff =
      added_lines("lib/new.ex", 0, 2) <>
        """
        diff --git a/lib/x.ex b/lib/y.ex
        similarity index 90%
        rename from lib/x.ex
        rename to lib/y.ex
        --- a/lib/x.ex
        +++ b/lib/y.ex
        @@ -1 +1 @@
        -a
        +b
        """ <> added_lines("mix.lock", 0, 1)

    commits = [%{sha: String.duplicate("c", 40), subject: "Add things", body: "Why:\nbecause"}]

    assert %{units: [unit | _rest]} =
             change(diff, mode: :branch, head_sha: :worktree, commits: commits) |> split!()

    assert %{id: "change", kind: :change, path: nil, changed_lines: 5, lines: []} = unit

    assert unit.rendered == """
           Change: the current branch against main (merge base aaaaaaaaaaaa), including uncommitted changes
           Files changed: 3 (+4 -1)

           Commits (newest first):
           - cccccccccccc Add things
               Why:
               because

           Files:
           M lib/new.ex (+2 -0)
           R lib/y.ex (from lib/x.ex) (+1 -1)
           M mix.lock (+1 -0)

           Not reviewed line by line:
           - mix.lock: lock file
           """
  end

  test "describes staged changes and ranges" do
    diff = added_lines("a.ex", 0, 1)

    staged = change(diff, mode: :staged, base_ref: nil, head_sha: :index) |> split!()
    assert hd(staged.units).rendered =~ "Change: staged changes against HEAD (aaaaaaaaaaaa)\n"

    range = change(diff) |> split!()
    assert hd(range.units).rendered =~ "Change: main (aaaaaaaaaaaa) to bbbbbbbbbbbb\n"

    worktree = change(diff, head_sha: :worktree, base_ref: "HEAD~2") |> split!()
    assert hd(worktree.units).rendered =~ "Change: HEAD~2 (aaaaaaaaaaaa) to the working tree\n"
  end

  test "works on a change loaded from Git" do
    dir = GitRepo.init()
    body = Enum.map_join(1..30, "", &"\tx#{&1} = #{&1};\n")

    GitRepo.write(dir, %{
      "small.c" => "int small(void)\n{\n\tint a = 1;\n\treturn a;\n}\n",
      "big.c" => "int big(void)\n{\n" <> body <> "\treturn 0;\n}\n",
      "Cargo.lock" => "v1\n"
    })

    GitRepo.commit(dir, "base")

    GitRepo.write(dir, %{
      "small.c" => "int small(void)\n{\n\tint a = 2;\n\treturn a;\n}\n",
      "big.c" =>
        "int big(void)\n{\n" <> String.replace(body, "x30 = 30", "x30 = 31") <> "\treturn 0;\n}\n",
      "Cargo.lock" => "v2\n"
    })

    assert {:ok, change} = Change.load(cwd: dir)
    assert {:ok, %{units: [change_unit | units], skipped: skipped}} = Units.split(change)

    assert change_unit.kind == :change
    assert skipped == [%{path: "Cargo.lock", reason: :lock_file}]
    assert [big, small] = units

    # The small function is shown whole; the big one only around the change.
    assert small.side_ranges.new == [1..5]
    assert small.rendered =~ "[  1] int small(void)\n"
    assert big.side_ranges.new == [29..34]
    assert big.changed_ranges == %{old: [32..32], new: [32..32]}
  end
end
