defmodule Tackle.CLI.TUI.ThemeRenderingTest do
  use ExUnit.Case, async: false

  alias ExRatatui.{CellSession, Style}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.WidgetList
  alias Tackle.CLI.Native
  alias Tackle.CLI.TUI.{MessageView, Theme}
  alias Tackle.CLI.Widgets.Conversation

  setup do
    previous = System.get_env("TACKLE_THEME")

    on_exit(fn ->
      if previous,
        do: System.put_env("TACKLE_THEME", previous),
        else: System.delete_env("TACKLE_THEME")
    end)

    :ok
  end

  test "native user prompts pair foreground with background in either mode" do
    for mode <- [:light, :dark] do
      System.put_env("TACKLE_THEME", Atom.to_string(mode))
      surface = Theme.style(:user_surface)
      entry = %MessageView{kind: :user, content: "hello\nwrapped prompt"}
      rows = entry |> Conversation.cell(10) |> paint_native(10)

      assert Enum.any?(List.flatten(rows), &String.contains?(elem(&1, 0), "hello"))

      assert Enum.all?(List.flatten(rows), fn {_text, fg, bg, _under, _modifiers} ->
               fg != nil and bg == elem(Conversation.style(surface), 1)
             end)
    end
  end

  test "paragraph prompts and errors use matching surface text including padding" do
    for mode <- [:light, :dark], kind <- [:user, :error] do
      System.put_env("TACKLE_THEME", Atom.to_string(mode))
      entry = %MessageView{kind: kind, content: "hello"}
      items = MessageView.render_entry(entry, 20)
      heights = Enum.map(items, &elem(&1, 1))
      surface = Theme.style(if(kind == :user, do: :user_surface, else: :error_surface))
      session = CellSession.new(20, Enum.sum(heights))
      on_exit(fn -> CellSession.close(session) end)

      :ok =
        CellSession.draw(session, [
          {%WidgetList{items: items}, %Rect{width: 20, height: Enum.sum(heights)}}
        ])

      %{cells: cells} = CellSession.take_cells(session)
      assert Enum.all?(cells, &(&1.bg == surface.bg))
      assert Enum.find(cells, &(&1.symbol == "h")).fg == surface.fg
      assert List.last(cells).fg == surface.fg
    end
  end

  test "code palette changes invalidate cached snippets and use light highlighting" do
    entry = %MessageView{kind: :assistant, content: "```elixir\nIO.puts(:ok)\n```"}
    System.put_env("TACKLE_THEME", "dark")
    {dark, cache} = Conversation.cached_cell(entry, 30, %{})
    dark_rows = paint_native(dark, 30)

    System.put_env("TACKLE_THEME", "light")
    {light, _cache} = Conversation.cached_cell(entry, 30, cache)
    refute dark == light
    light_rows = paint_native(light, 30)
    refute light_rows == dark_rows
    surface = Conversation.style(Theme.style(:code_surface))

    assert Enum.all?(List.flatten(light_rows), &(elem(&1, 2) == elem(surface, 1)))

    [line] = ExRatatui.CodeBlock.highlight("IO.puts(:ok)", "elixir", :base16_ocean_light)

    token_fg =
      line.spans
      |> hd()
      |> Map.fetch!(:style)
      |> Theme.code_style()
      |> Conversation.style()
      |> elem(0)

    assert Enum.find(List.flatten(light_rows), &(elem(&1, 0) == "IO")) |> elem(1) == token_fg
  end

  test "light code tokens stay dark enough after their backgrounds are removed" do
    System.put_env("TACKLE_THEME", "light")
    source = "```elixir\n# comment\nIO.puts(\"hello\")\nfn -> :ok end\n```"

    rows =
      %MessageView{kind: :assistant, content: source} |> Conversation.cell(40) |> paint_native(40)

    for {text, {r, g, b}, _bg, _under, _modifiers} <- List.flatten(rows),
        String.trim(text) != "" do
      assert max(max(r, g), b) <= 96
    end

    # Error scopes can supply bright foregrounds paired with dark backgrounds.
    # The normalization must not leave white text on the light surface.
    assert Theme.code_style(%Style{fg: {:rgb, 255, 255, 255}, bg: {:rgb, 255, 0, 0}}) ==
             %Style{fg: {:rgb, 96, 96, 96}}
  end

  defp paint_native(items, width) do
    {scene, height} = Conversation.assemble(items, width)

    {:ok, rows} =
      Native.conversation_render(scene, width, height, 0, [], Conversation.style(%Style{}))

    rows
  end
end
