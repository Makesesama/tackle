defmodule Tackle.Review.GlobTest do
  use ExUnit.Case, async: true

  alias Tackle.Review.Glob

  defp matches?(pattern, path) do
    assert {:ok, glob} = Glob.compile(pattern)
    Glob.match?(glob, path)
  end

  test "patterns with a slash match from the repository root" do
    assert matches?("lib/**/*.ex", "lib/a.ex")
    assert matches?("lib/**/*.ex", "lib/deep/er/a.ex")
    refute matches?("lib/**/*.ex", "apps/x/lib/a.ex")
    refute matches?("lib/*.ex", "lib/deep/a.ex")
    assert matches?("/mix.exs", "mix.exs")
    refute matches?("/mix.exs", "apps/x/mix.exs")
    assert matches?("**/test/*.exs", "apps/x/test/a.exs")
    assert matches?("**/test/*.exs", "test/a.exs")
  end

  test "patterns without a slash match file names at any depth" do
    assert matches?("*.lock", "mix.lock")
    assert matches?("*.lock", "assets/yarn.lock")
    refute matches?("*.lock", "lock.ex")
    assert matches?("go.sum", "svc/go.sum")
  end

  test "trailing slashes match everything below a directory" do
    assert matches?("deps/", "deps/jason/lib/jason.ex")
    assert matches?("deps/", "apps/web/deps/x.ex")
    refute matches?("deps/", "lib/deps.ex")
    assert matches?("lib/**", "lib/a/b.ex")
  end

  test "supports ?, classes, negated classes, and alternatives" do
    assert matches?("a?.ex", "ab.ex")
    refute matches?("a?.ex", "a/.ex")
    assert matches?("[ab].ex", "b.ex")
    refute matches?("[ab].ex", "c.ex")
    assert matches?("[a-c].ex", "b.ex")
    assert matches?("[!ab].ex", "c.ex")
    refute matches?("[!ab].ex", "a.ex")
    assert matches?("*.{ex,exs}", "lib/a.exs")
    refute matches?("*.{ex,exs}", "lib/a.eex")
  end

  test "escapes regular expression characters" do
    assert matches?("a+b(1).ex", "a+b(1).ex")
    refute matches?("a.ex", "abex")
  end

  test "rejects invalid patterns" do
    assert Glob.compile("") == {:error, "pattern is empty"}
    assert Glob.compile("{a,b") == {:error, "unbalanced {"}
    assert Glob.compile("a}") == {:error, "unbalanced }"}
    assert Glob.compile("[ab") == {:error, "unterminated ["}

    assert Glob.compile_all(["*.ex", "{x"]) == {:error, {:invalid_glob, "{x", "unbalanced {"}}
  end

  test "match?/2 accepts a list of globs" do
    assert {:ok, globs} = Glob.compile_all(["*.lock", "deps/"])
    assert Glob.match?(globs, "deps/a.ex")
    refute Glob.match?(globs, "lib/a.ex")
    refute Glob.match?([], "lib/a.ex")
  end
end
