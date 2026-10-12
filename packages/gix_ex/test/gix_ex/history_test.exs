defmodule GixEx.HistoryTest do
  # Compares GixEx with `git diff --histogram` on the recent history of the
  # repository this package lives in. Real changes exercise far more shapes
  # than the fixtures, but depend on the checkout, so the test is opt-in:
  #
  #     mix test --only history
  #
  # GIX_EX_HISTORY_COMMITS sets how many commits are compared (default 200).
  use ExUnit.Case, async: true

  import GixEx.TestRepo

  @moduletag :history
  @moduletag timeout: :infinity

  # Rename detection is off by default: gix scores similarity differently from
  # Git, so a pair close to the 50% threshold can be a rename in one and a
  # deletion plus an addition in the other. `GIX_EX_HISTORY_RENAMES=1` compares
  # with rename detection.
  test "matches git diff for each recent commit" do
    root = File.cwd!() |> git!(["rev-parse", "--show-toplevel"]) |> String.trim()
    count = System.get_env("GIX_EX_HISTORY_COMMITS", "200")

    commits =
      root
      |> git!(["log", "--no-merges", "--format=%H", "--max-count=#{count}", "HEAD"])
      |> String.split("\n", trim: true)
      |> Enum.filter(
        &match?({_, 0}, System.cmd("git", ["rev-parse", "-q", "--verify", "#{&1}^"], cd: root))
      )

    renames = System.get_env("GIX_EX_HISTORY_RENAMES", "0") == "1"
    {:ok, repo} = GixEx.open(root)

    mismatches =
      Enum.flat_map(commits, fn commit ->
        {:ok, files} = GixEx.diff(repo, commit <> "^", commit, renames: renames && 0.5)
        ours = render(files)
        theirs = git_diff(root, [commit <> "^", commit], renames: renames)

        if ours == theirs do
          []
        else
          [{commit, difference(ours, theirs)}]
        end
      end)

    assert mismatches == [],
           "#{length(mismatches)} of #{length(commits)} commits differ:\n\n" <>
             Enum.map_join(mismatches, "\n\n", fn {commit, detail} -> "#{commit}\n#{detail}" end)
  end

  defp difference(ours, theirs) when length(ours) != length(theirs) do
    "files: #{inspect(Enum.map(ours, & &1.paths))}\n   git: #{inspect(Enum.map(theirs, & &1.paths))}"
  end

  defp difference(ours, theirs) do
    ours
    |> Enum.zip(theirs)
    |> Enum.reject(fn {a, b} -> a == b end)
    |> Enum.map_join("\n", fn {a, b} ->
      fields = for key <- [:status, :paths, :counts, :hunks], a[key] != b[key], do: key
      "  #{inspect(b.paths)} differs in #{inspect(fields)}"
    end)
  end
end
