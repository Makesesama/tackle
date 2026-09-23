defmodule Tackle.CLI.TUI.CodeFencesTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.CodeFences

  test "extracts closed and streaming Elixir fences without changing other Markdown" do
    assert CodeFences.split("Before\n```elixir\nIO.puts(:ok)\n```\nAfter") == [
             {:markdown, "Before"},
             {:elixir, "IO.puts(:ok)"},
             {:markdown, "After"}
           ]

    assert CodeFences.split("~~~EXS\nIO.puts(:ok)") == [{:elixir, "IO.puts(:ok)"}]

    assert CodeFences.split("```rust\nfn main() {}\n```") == [
             {:markdown, "```rust\nfn main() {}\n```"}
           ]
  end

  test "respects fence length and ignores opening fences in non-code blocks" do
    assert CodeFences.split("````elixir\n:ok\n```\n:end\n````") == [
             {:elixir, ":ok\n```\n:end"}
           ]

    assert CodeFences.split("```rust\n```elixir\n:ok\n```\n```") == [
             {:markdown, "```rust\n```elixir\n:ok\n```\n```"}
           ]

    assert CodeFences.split("code `inline`\n  not a fence") == [
             {:markdown, "code `inline`\n  not a fence"}
           ]
  end
end
