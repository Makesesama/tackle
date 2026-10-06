defmodule Tackle.CLI.TUI.HighlightTest do
  use ExUnit.Case, async: false

  alias ExRatatui.Style
  alias Tackle.CLI.Test.{ErrorLumis, FakeLumis, RaisingLumis, ReflowingLumis}
  alias Tackle.CLI.TUI.{Highlight, MessageView, ToolView}
  alias Tackle.Lib.{Message, State}

  setup do
    previous_theme = System.get_env("TACKLE_THEME")
    previous = Application.get_env(:tackle_cli, :highlight)
    previous_backend = Application.get_env(:tackle_cli, :highlight_backend)

    on_exit(fn ->
      if previous_theme,
        do: System.put_env("TACKLE_THEME", previous_theme),
        else: System.delete_env("TACKLE_THEME")

      restore(:highlight, previous)
      restore(:highlight_backend, previous_backend)
    end)

    # The fake paints each palette with its own color; pin one so the
    # assertions below are deterministic regardless of the ambient terminal.
    System.put_env("TACKLE_THEME", "dark")
    Application.put_env(:tackle_cli, :highlight, true)
    Application.put_env(:tackle_cli, :highlight_backend, FakeLumis)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:tackle_cli, key)
  defp restore(key, value), do: Application.put_env(:tackle_cli, key, value)

  describe "parse/1" do
    test "truecolor foregrounds become rgb styles" do
      assert [{"hi", %Style{fg: {:rgb, 10, 20, 30}}}] =
               Highlight.parse("\e[0m\e[38;2;10;20;30mhi\e[0m")
    end

    test "256-color foregrounds become indexed styles" do
      assert [{"hi", %Style{fg: {:indexed, 42}}}] = Highlight.parse("\e[38;5;42mhi\e[0m")
    end

    test "plain text has no styling" do
      assert [{"abc", %Style{fg: nil, modifiers: []}}] = Highlight.parse("abc")
    end

    test "a reset returns to the default style mid-line" do
      assert [{"a", %Style{fg: {:rgb, 1, 2, 3}}}, {"b", %Style{fg: nil}}] =
               Highlight.parse("\e[38;2;1;2;3ma\e[0mb")
    end

    test "bold and italic survive, backgrounds and unknown codes do not" do
      assert [{"x", %Style{fg: nil, modifiers: mods}}] =
               Highlight.parse("\e[1m\e[3m\e[48;2;0;0;0m\e[7mx\e[0m")

      assert Enum.sort(mods) == [:bold, :italic]
    end

    test "an empty escape sequence is a reset" do
      assert [{"x", %Style{fg: nil}}] = Highlight.parse("\e[mx\e[m")
    end

    test "malformed color parameters are ignored, not fatal" do
      assert [{"x", %Style{fg: nil}}] = Highlight.parse("\e[38;2;999;0;0mx\e[0m")
    end
  end

  describe "merge_token_runs/2" do
    test "a boundary in either segmentation becomes a boundary in the result" do
      token = %Style{fg: {:rgb, 1, 2, 3}}

      assert [{"let", false, ^token}, {" ", false, nil}, {"x", true, nil}] =
               ToolView.merge_token_runs([{"let ", false}, {"x", true}], [
                 {"let", token},
                 {" x", nil}
               ])
    end

    test "without token runs the diff runs keep their shape" do
      assert [{"ab", true, nil}] = ToolView.merge_token_runs([{"ab", true}], nil)
    end

    test "a line the highlighter could not cover falls back to unstyled" do
      assert [{"ab", false, nil}] =
               ToolView.merge_token_runs([{"ab", false}], [{"a", %Style{fg: :red}}])
    end
  end

  describe "lines/2" do
    test "returns per-line runs keyed by the source's own line numbers" do
      assert %{
               1 => [{"a", %Style{fg: {:rgb, 1, 2, 3}}}],
               2 => [],
               3 => [{"b", %Style{fg: {:rgb, 1, 2, 3}}}]
             } =
               Highlight.lines("a\n\nb", "lib/foo.ex")
    end

    test "runs without token styling are nil so callers keep their base style" do
      assert %{1 => [{"x ", %Style{fg: {:rgb, 1, 2, 3}}}, {"y", nil}]} =
               Highlight.lines("x y", "lib/foo.ex")
    end

    test "adjacent runs of equal style merge into one span" do
      assert %{1 => [{"ab", %Style{fg: {:rgb, 1, 2, 3}}}]} =
               Highlight.lines("ab", "lib/foo.ex")
    end

    test "an error tuple renders no styling" do
      Application.put_env(:tackle_cli, :highlight_backend, ErrorLumis)
      assert Highlight.lines("a", "lib/foo.ex") == %{}
    end

    test "a raising highlighter renders no styling" do
      Application.put_env(:tackle_cli, :highlight_backend, RaisingLumis)
      assert Highlight.lines("a", "lib/foo.ex") == %{}
    end

    test "a disabled highlighter renders no styling" do
      Application.put_env(:tackle_cli, :highlight, false)
      assert Highlight.lines("a", "lib/foo.ex") == %{}
    end

    test "a reflowed blob loses its line alignment and is dropped" do
      Application.put_env(:tackle_cli, :highlight_backend, ReflowingLumis)
      assert Highlight.lines("a\nb", "lib/foo.ex") == %{}
    end
  end

  describe "tool cards" do
    test "edit previews paint token colors and keep the intraline tint" do
      args = %{
        "path" => "lib/foo.ex",
        "edits" => [%{"oldText" => "let x = 1", "newText" => "let x = 2"}]
      }

      [entry] = settled_edit(args)
      spans = flat_spans(ToolView.render(entry, 80))

      # Unemphasized code carries the token color; the changed token keeps
      # the stronger inline tint so the emphasis survives on the fill.
      assert Enum.any?(spans, &(&1.style.fg == {:rgb, 1, 2, 3}))
      assert Enum.any?(spans, &(&1.style.fg == {:indexed, 217}))
      assert Enum.any?(spans, &(&1.style.fg == {:indexed, 151}))
    end

    test "write previews paint token colors" do
      args = %{"path" => "lib/foo.ex", "content" => "let x = 1"}

      [entry] =
        settled([
          Message.assistant(tool_calls: [%{id: "w1", name: "write", arguments: args}]),
          Message.tool_result("w1", "write", "ok")
        ])

      assert Enum.any?(flat_spans(ToolView.render(entry, 80)), &(&1.style.fg == {:rgb, 1, 2, 3}))
    end

    test "a failing highlighter still renders the diff as plain text" do
      Application.put_env(:tackle_cli, :highlight_backend, ErrorLumis)

      args = %{
        "path" => "lib/foo.ex",
        "edits" => [%{"oldText" => "let x = 1", "newText" => "let x = 2"}]
      }

      [entry] = settled_edit(args)
      text = flat_spans(ToolView.render(entry, 80)) |> Enum.map_join("", & &1.content)

      assert text =~ "let x = 1"
      assert text =~ "let x = 2"
      refute Enum.any?(flat_spans(ToolView.render(entry, 80)), &(&1.style.fg == {:rgb, 1, 2, 3}))
    end
  end

  defp settled_edit(args) do
    settled([
      Message.assistant(tool_calls: [%{id: "e1", name: "edit", arguments: args}]),
      Message.tool_result("e1", "edit", "ok")
    ])
  end

  defp settled(messages) do
    MessageView.section_entries(
      %{agent_state: %State{messages: messages}, thinking_expanded?: false},
      :settled
    )
  end

  defp flat_spans(items) do
    Enum.flat_map(items, fn {widget, _} ->
      Enum.flat_map(widget.text, & &1.spans)
    end)
  end
end
