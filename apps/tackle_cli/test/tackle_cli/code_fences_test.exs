defmodule Tackle.CLI.TUI.CodeFencesTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.CodeFences

  test "extracts closed and streaming fences without changing surrounding Markdown" do
    assert CodeFences.split("Before\n```elixir\nIO.puts(:ok)\n```\nAfter") == [
             {:markdown, "Before"},
             {:code, "elixir", "IO.puts(:ok)"},
             {:markdown, "After"}
           ]

    assert CodeFences.split("~~~EXS\nIO.puts(:ok)") == [{:code, "elixir", "IO.puts(:ok)"}]
    assert CodeFences.split("```rust\nfn main() {}\n```") == [{:code, "rust", "fn main() {}"}]
    assert CodeFences.split("```sh\necho hi") == [{:code, "sh", "echo hi"}]

    assert CodeFences.split("```python title=example.py\nprint(1)\n```") == [
             {:code, "python", "print(1)"}
           ]

    assert CodeFences.split("```made-up-language\nraw code\n```") == [
             {:code, "made-up-language", "raw code"}
           ]

    assert CodeFences.split("```\nplain\n```") == [{:code, "", "plain"}]
  end

  test "respects fence length and ignores opening fences in non-code blocks" do
    assert CodeFences.split("````elixir\n:ok\n```\n:end\n````") == [
             {:code, "elixir", ":ok\n```\n:end"}
           ]

    assert CodeFences.split("```rust\n```elixir\n:ok\n```\n```") == [
             {:code, "rust", "```elixir\n:ok"}
           ]

    assert CodeFences.split("code `inline`\n  not a fence") == [
             {:markdown, "code `inline`\n  not a fence"}
           ]
  end
end
