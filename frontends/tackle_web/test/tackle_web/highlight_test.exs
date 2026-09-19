defmodule Tackle.Web.HighlightTest do
  use ExUnit.Case, async: true

  alias Tackle.Web.Highlight

  test "keys fragments by the file's own line numbers" do
    lines = Highlight.lines("one\ntwo\nthree\n", "lib/example.ex")

    assert lines[1] =~ "one"
    assert lines[2] =~ "two"
    assert lines[3] =~ "three"
  end

  test "wraps tokens of a known language in styled spans" do
    lines = Highlight.lines("defmodule Example do\nend\n", "lib/example.ex")

    assert lines[1] =~ ~s[style="color:]
    assert lines[1] =~ "defmodule"
  end

  test "takes a path so the grammar can be inferred from its extension" do
    assert Highlight.lines("defmodule Example do\nend\n", "lib/example.ex")[1] =~
             ~s[style="color:]
  end

  test "escapes HTML when rendering plain text" do
    assert Highlight.plain("<script>alert(1)</script> & more") ==
             "&lt;script&gt;alert(1)&lt;/script&gt; &amp; more"
  end

  test "escapes the ampersand before the angle brackets it introduces" do
    assert Highlight.plain("&lt;") == "&amp;lt;"
  end

  test "does not raise on source that is still incomplete" do
    # A patch can show a half-typed construct. Tree-sitter accepts it, and the
    # review must keep rendering rather than failing on the whole file.
    assert %{} = Highlight.lines("defmodule Unclosed do\n  def x do\n", "lib/unclosed.ex")
  end
end
