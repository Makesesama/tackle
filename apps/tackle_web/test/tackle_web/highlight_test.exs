defmodule Tackle.Web.HighlightTest do
  use ExUnit.Case, async: true

  alias Tackle.Web.Highlight

  setup_all do
    # Wasmtime cannot allocate executable memory on some CI hosts. In that
    # case highlighting is optional and diff rows use escaped plain text.
    highlighted? =
      Highlight.lines("defmodule Example do\nend\n", "lib/example.ex")
      |> Map.get(1, "")
      |> String.contains?(~s[style="color:])

    %{highlighted?: highlighted?}
  end

  test "keys fragments by the file's own line numbers" do
    html =
      ~s[<div class="l-line" data-line="1">one\n</div>] <>
        ~s[<div class="l-line" data-line="2">two\n</div>] <>
        ~s[<div class="l-line" data-line="3">three\n</div>]

    assert Highlight.split_lines(html) == %{1 => "one", 2 => "two", 3 => "three"}
  end

  test "wraps tokens of a known language in styled spans", %{highlighted?: highlighted?} do
    lines = Highlight.lines("defmodule Example do\nend\n", "lib/example.ex")

    if highlighted? do
      assert lines[1] =~ ~s[style="color:]
      assert lines[1] =~ "defmodule"
    else
      assert lines == %{}
    end
  end

  test "takes a path so the grammar can be inferred from its extension", %{
    highlighted?: highlighted?
  } do
    lines = Highlight.lines("defmodule Example do\nend\n", "lib/example.ex")

    if highlighted? do
      assert lines[1] =~ ~s[style="color:]
    else
      assert lines == %{}
    end
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
