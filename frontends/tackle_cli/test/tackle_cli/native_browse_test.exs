defmodule Tackle.CLI.Widgets.BrowseTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias Tackle.CLI.Native
  alias Tackle.CLI.TUI.Theme
  alias Tackle.CLI.Widgets.{Browse, Conversation}

  defp styles do
    {Conversation.style(Theme.style(:accent)), Conversation.style(Theme.style(:muted)),
     Conversation.style(Theme.style(:selection_surface))}
  end

  defp paint(resource, page, width, height, offset \\ 0) do
    {:ok, rows} = Native.browse_render(resource, page, width, height, offset, [], styles())
    Enum.map_join(rows, "\n", fn row -> Enum.map_join(row, "", &elem(&1, 0)) end)
  end

  test "native tabs wrap navigation chrome down to the active page on narrow terminals" do
    {wide, _} = Browse.document("body", 100)
    assert paint(wide, 2, 100, 5) =~ "[Prompt]"
    assert paint(wide, 2, 100, 5) =~ "Transcript"
    {narrow, _} = Browse.document("body", 20)
    assert paint(narrow, 5, 20, 5) =~ "< Events > 6/6"
    assert paint(narrow, 5, 20, 1) =~ "body"
    assert paint(narrow, 5, 0, 0) == ""
  end

  test "plain pages preserve indentation, sanitize controls and leave old resources unchanged" do
    source = "  **plain**\n\e[31mred\e[0m\e]52;c;clipboard-secret\a\n界é"
    {old, _} = Browse.document(source, 30)
    {new, _} = Browse.document("replacement", 30)
    text = paint(old, 1, 30, 10)
    assert text =~ "  **plain**"
    assert text =~ "red"
    assert text =~ "界é"
    refute text =~ "clipboard-secret"
    refute text =~ "\e"
    refute text =~ "replacement"
    assert paint(new, 1, 30, 10) =~ "replacement"
    assert source =~ "clipboard-secret"
  end

  test "scrolling and rendering beyond u16 rows retains the full tail" do
    {resource, total} = Browse.document(String.duplicate("line\n", 66_000) <> "tail", 10)
    offset = Browse.scroll(0, total, 5, total)
    assert offset == total - 4
    assert offset > 65_535
    assert paint(resource, 1, 10, 5, offset) =~ "tail"
    assert Browse.scroll(offset, total, 5, -total) == 0
    assert Browse.scroll(offset, total, 30, 0) == total - 29
  end

  test "render validates page, dimensions and style and places a nonzero rect" do
    {resource, _} = Browse.document("content", 20)

    for {page, width, height} <- [{6, 20, 5}, {0, 21, 5}] do
      assert_raise ArgumentError, fn ->
        Native.browse_render(resource, page, width, height, 0, [], styles())
      end
    end

    assert {:error, :invalid_size} =
             Native.browse_render(resource, 0, 1000, 1000, 0, [], styles())

    bad = {nil, nil, nil, 32}

    assert_raise ArgumentError, fn ->
      Native.browse_render(resource, 0, 20, 5, 0, [], {bad, bad, bad})
    end

    rect = %Rect{x: 3, y: 2, width: 20, height: 5}
    assert [{_, ^rect}] = Browse.render(%Browse{state: resource, page: 1}, rect)
  end

  test "transcript resources are reused and selection is painted below the tab row" do
    style = Conversation.style(%ExRatatui.Style{})
    {cell, _} = Native.conversation_rows([{[{"selected", style}], style}], 100)
    {resource, _} = Native.conversation_new([cell], 100)
    {:ok, [tabs, selected | _]} = Native.browse_render(resource, 0, 100, 5, 0, [0], styles())
    assert Enum.any?(tabs, &(elem(&1, 0) =~ "[Transcript]"))
    assert Enum.any?(selected, &(elem(&1, 0) =~ "selected"))
    assert Enum.all?(selected, &(elem(&1, 2) != nil))
  end
end
