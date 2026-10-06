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
    previous_highlight = Application.get_env(:tackle_cli, :highlight)
    previous_backend = Application.get_env(:tackle_cli, :highlight_backend)

    on_exit(fn ->
      if previous,
        do: System.put_env("TACKLE_THEME", previous),
        else: System.delete_env("TACKLE_THEME")

      restore(:highlight, previous_highlight)
      restore(:highlight_backend, previous_backend)
    end)

    Application.put_env(:tackle_cli, :highlight, true)
    Application.put_env(:tackle_cli, :highlight_backend, Tackle.CLI.Test.FakeLumis)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:tackle_cli, key)
  defp restore(key, value), do: Application.put_env(:tackle_cli, key, value)

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

    # The fake highlighter paints light tokens with its light color.
    token = Enum.find(List.flatten(light_rows), &(elem(&1, 0) == "IO.puts(:ok)"))
    assert token |> elem(1) == {4, 5, 6}

    assert Enum.find(List.flatten(dark_rows), &(elem(&1, 0) == "IO.puts(:ok)")) |> elem(1) ==
             {1, 2, 3}
  end

  test "code tokens carry the theme's colors on the shared code surface" do
    System.put_env("TACKLE_THEME", "light")
    source = "```elixir\n# comment\nIO.puts(\"hello\")\nfn -> :ok end\n```"

    rows =
      %MessageView{kind: :assistant, content: source}
      |> Conversation.cell(40)
      |> paint_native(40)

    surface = Conversation.style(Theme.style(:code_surface))

    # A single surface paints behind every row; the highlighter supplies only
    # foregrounds, so no token can leave its background on the shell.
    for {_text, _fg, bg, _under, _modifiers} <- List.flatten(rows) do
      assert bg == elem(surface, 1)
    end

    assert Enum.any?(List.flatten(rows), fn {_text, fg, _bg, _u, _m} -> fg == {4, 5, 6} end)
  end

  test "a failing highlighter still renders fenced code as plain text" do
    Application.put_env(:tackle_cli, :highlight_backend, Tackle.CLI.Test.ErrorLumis)
    System.put_env("TACKLE_THEME", "light")
    entry = %MessageView{kind: :assistant, content: "```elixir\nIO.puts(:ok)\n```"}

    rows = entry |> Conversation.cell(40) |> paint_native(40)

    assert Enum.any?(List.flatten(rows), &String.contains?(elem(&1, 0), "IO.puts(:ok)"))
    refute Enum.any?(List.flatten(rows), fn {_text, fg, _bg, _u, _m} -> fg == {4, 5, 6} end)
  end

  defp paint_native(items, width) do
    {scene, height} = Conversation.assemble(items, width)

    {:ok, rows} =
      Native.conversation_render(scene, width, height, 0, [], Conversation.style(%Style{}))

    rows
  end
end
