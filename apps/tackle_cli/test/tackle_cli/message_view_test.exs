defmodule Tackle.CLI.TUI.MessageViewTest do
  use ExUnit.Case, async: true

  alias ExRatatui.CellSession
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.Line
  alias ExRatatui.Widgets.WidgetList
  alias Tackle.CLI.TUI.{Glyph, MessageView}
  alias Tackle.Lib.{Message, State}

  test "the header image encodes the same grid as a transparent PNG" do
    png = Glyph.png()
    assert <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = png
    assert {:ok, image} = ExRatatui.Image.new(png)
    assert ExRatatui.Image.dimensions(image) == {56, 48}
  end

  test "welcome glyph has uniform two-column pixels and a detached square" do
    rows = Glyph.rows()
    assert length(rows) == 6
    assert Enum.all?(rows, fn row -> MessageView.display_width(plain(row)) == 14 end)

    assert Enum.all?(rows, fn row ->
             Enum.all?(row.spans, &(&1.content in ["  ", "██"]))
           end)

    assert Enum.at(rows, 3) |> plain() == "    ████      "
    assert Enum.at(rows, 4) |> plain() == "    ████  ██  "
    assert Enum.at(rows, 5) |> plain() == "    ████      "

    assert Enum.count(
             for row <- rows, span <- row.spans, span.style.fg == {:rgb, 156, 58, 242}, do: span
           ) == 3

    wide = MessageView.render_entry(MessageView.welcome_entry(), 40)
    assert text(wide) =~ "██"
    assert text(wide) =~ "Welcome to Tackle."

    narrow = MessageView.render_entry(MessageView.welcome_entry(), 10)
    refute text(narrow) =~ "██"
    assert text(narrow) =~ "Welcome to"
  end

  test "user prompts paint a full-width surface band with an accent marker" do
    [entry] = settled([Message.user("hello")])
    cells = draw(MessageView.render_entry(entry, 20), 20, 3)

    header = Enum.filter(cells, &(&1.row == 0))
    assert Enum.all?(header, &(&1.bg == {:indexed, 235}))
    assert Enum.any?(header, &(&1.symbol == "›" and &1.fg == {:indexed, 110}))
    assert Enum.any?(header, &(&1.symbol == "h"))
  end

  test "collapsed reasoning is compact and expands on demand" do
    state = %{
      agent_state: %State{
        messages: [Message.assistant(thinking: "first\nsecond\nthird", content: "x")]
      },
      thinking_expanded?: false
    }

    [entry | _rest] = MessageView.section_entries(state, :settled)
    collapsed = text(MessageView.render_entry(entry, 60))

    assert collapsed =~ "thought (3 lines)"
    refute collapsed =~ "·"
    refute collapsed =~ "Ctrl+T to expand"
    refute collapsed =~ "first"
    refute collapsed =~ "second"
    refute collapsed =~ "third"

    [expanded_entry | _rest] =
      MessageView.section_entries(%{state | thinking_expanded?: true}, :settled)

    assert text(MessageView.render_entry(expanded_entry, 40)) =~ "third"

    wrapped = MessageView.render_entry(%{expanded_entry | source: String.duplicate("x", 24)}, 12)
    rows = for {widget, _} <- wrapped, row <- widget.text, do: plain(row)
    assert Enum.take(rows, -3) == ["  xxxxxxxxxx", "  xxxxxxxxxx", "  xxxx"]
    assert MessageView.search_text(entry) =~ "third"
  end

  test "compaction notices do not add decorative markers" do
    entry = %MessageView{kind: :compaction, content: "Context compacted"}
    assert text(MessageView.render_entry(entry, 40)) == "Context compacted"
  end

  test "paint strips terminal controls from every span while copy keeps the source" do
    [entry] = settled([Message.user("safe\e]52;c;evil\a text")])
    items = MessageView.render_entry(entry, 40)

    refute text(items) =~ "evil"
    assert MessageView.source(entry) =~ "evil"
  end

  test "wrapping keeps the row surface and span colors on continuation rows" do
    surface = %ExRatatui.Style{bg: {:indexed, 235}}

    rows = [
      MessageView.row(
        [
          MessageView.span("red ", %ExRatatui.Style{fg: :red}),
          MessageView.span("words", surface)
        ],
        surface
      )
    ]

    wrapped = MessageView.wrap_rows(rows, 6)
    assert [_, _ | _] = wrapped
    assert Enum.all?(wrapped, &(&1.style == surface))
    assert Enum.any?(wrapped, fn line -> Enum.any?(line.spans, &(&1.style.fg == :red)) end)
  end

  defp settled(messages),
    do:
      MessageView.section_entries(
        %{agent_state: %State{messages: messages}, thinking_expanded?: false},
        :settled
      )

  defp draw(items, width, height) do
    session = CellSession.new(width, height)

    :ok =
      CellSession.draw(session, [{%WidgetList{items: items}, %Rect{width: width, height: height}}])

    %{cells: cells} = CellSession.take_cells(session)
    cells
  end

  defp text(items) do
    Enum.map_join(items, "\n", fn {widget, _height} ->
      widget |> Map.fetch!(:text) |> plain()
    end)
  end

  defp plain(text) when is_binary(text), do: text
  defp plain(%Line{spans: spans}), do: Enum.map_join(spans, "", & &1.content)
  defp plain(lines) when is_list(lines), do: Enum.map_join(lines, "\n", &plain/1)
end
