defmodule Tackle.CLI.SlashCommandsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ExRatatui.CellSession
  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, List, Paragraph}
  alias Tackle.CLI.{Keybinds, TUI}
  alias Tackle.CLI.TUI.{SlashCommands, Theme, Viewport}
  alias Tackle.CLI.TUI.State, as: TuiState
  alias Tackle.CLI.Widgets.Input
  alias Tackle.Lib.State, as: LibState

  defp base_state(opts) do
    input = Input.new()
    :ok = Input.set_value(input, Keyword.get(opts, :draft, ""))

    state = %TuiState{
      input: input,
      size: {80, 24},
      conversation: Viewport.new_conversation(80, 24),
      agent_state: LibState.new(),
      agent_ref: :agent_ref,
      session_id: "session-1",
      active_turn: Keyword.get(opts, :active_turn),
      new_session: Keyword.get(opts, :new_session),
      resume_session: Keyword.get(opts, :resume_session),
      list_recent_sessions: Keyword.get(opts, :list_recent_sessions),
      usage_timeline_loader: fn _mode, _id -> {:error, :test} end
    }

    Viewport.update_draft(state)
  end

  defp synced(opts) do
    {state, []} = opts |> base_state() |> SlashCommands.sync()
    state
  end

  defp names(commands), do: Enum.map(commands, & &1.name)

  # -- registry -------------------------------------------------------------

  test "find/1 resolves commands by exact name" do
    assert %{name: "resume", action: :resume} = SlashCommands.find("resume")
    assert SlashCommands.find("nope") == nil
  end

  test "commands/1 hides idle-only commands while a turn or operation is active" do
    idle = SlashCommands.commands(base_state([]))
    assert "resume" in names(idle)
    assert "tree" in names(idle)

    running = SlashCommands.commands(base_state(active_turn: %{id: "t"}))
    assert "model" in names(running)
    assert "resume" not in names(running)
    assert "tree" not in names(running)
  end

  test "parse/1 splits a leading command name from its arguments" do
    assert SlashCommands.parse("  /resume  ") == {"resume", ""}
    assert SlashCommands.parse("/model high") == {"model", "high"}
    assert SlashCommands.parse("/tree\n") == {"tree", ""}
    assert SlashCommands.parse("/") == {"", ""}
    assert SlashCommands.parse("hello") == nil
    assert SlashCommands.parse("") == nil
  end

  # -- filtering ------------------------------------------------------------

  test "filter/2 keeps presentation order and ranks exact matches first" do
    commands = SlashCommands.commands(base_state([]))

    assert SlashCommands.filter(commands, "") == commands
    assert names(SlashCommands.filter(commands, "t")) == ["thinking", "tree", "tasks"]
    assert names(SlashCommands.filter(commands, "tree")) == ["tree"]
    assert names(SlashCommands.filter(commands, "MO")) == ["model"]
    assert SlashCommands.filter(commands, "zzz") == []

    synthetic = [%{name: "tree"}, %{name: "treemap"}]
    assert names(SlashCommands.filter(synthetic, "tree")) == ["tree", "treemap"]
  end

  # -- fragment detection ---------------------------------------------------

  test "fragment/2 extracts the leading /name while the caret is inside it" do
    assert SlashCommands.fragment("/res", 4) == "res"
    assert SlashCommands.fragment("/", 1) == ""
    assert SlashCommands.fragment("/mod", 2) == "mod"
    assert SlashCommands.fragment("/model", 0) == "model"
  end

  test "fragment/2 closes once the caret leaves the name" do
    assert SlashCommands.fragment("/model foo", 10) == nil
    assert SlashCommands.fragment("/a\nb", 4) == nil
    assert SlashCommands.fragment("hello /x", 8) == nil
    assert SlashCommands.fragment("no slash", 8) == nil
    assert SlashCommands.fragment("", 0) == nil
  end

  # -- popup synchronization ------------------------------------------------

  test "sync opens the popup for a leading slash and closes it past the name" do
    state = synced(draft: "/re")
    {:slash_commands, popup} = state.overlay

    assert popup.query == "re"
    assert names(popup.matches) == ["resume"]
    assert popup.selected == 0

    :ok = Input.insert_str(state.input, "sume ")
    {state, commands} = SlashCommands.sync(state)

    assert commands == []
    assert state.overlay == nil
  end

  test "sync lists every command for a bare slash" do
    state = synced(draft: "/")
    {:slash_commands, popup} = state.overlay
    assert names(popup.matches) == names(SlashCommands.commands(state))
  end

  test "sync leaves other overlays alone and closes the popup when focus leaves" do
    picker = {:picker, %{kind: :model}}
    state = %{base_state(draft: "/re") | overlay: picker}
    {state, commands} = SlashCommands.sync(state)

    assert commands == []
    assert state.overlay == picker

    state = synced(draft: "/re")
    {state, commands} = SlashCommands.sync(%{state | focus: :transcript})

    assert commands == []
    assert state.overlay == nil
  end

  # -- popup keys -----------------------------------------------------------

  test "Esc dismisses the popup for the current fragment until it is edited" do
    state = synced(draft: "/re")

    {:noreply, state} = SlashCommands.handle(:close, state)
    assert state.overlay == nil
    assert state.slash_commands.dismissed == "re"

    {state, commands} = SlashCommands.sync(state)
    assert commands == []
    assert state.overlay == nil

    :ok = Input.insert_str(state.input, "s")
    {state, commands} = SlashCommands.sync(state)

    assert commands == []
    assert {:slash_commands, %{query: "res"}} = state.overlay
  end

  test "arrows wrap the selection" do
    state = synced(draft: "/t")
    {:slash_commands, %{matches: matches}} = state.overlay
    assert length(matches) == 3

    {:noreply, state} = SlashCommands.handle(:previous, state)
    {:slash_commands, %{selected: 2}} = state.overlay

    {:noreply, state} = SlashCommands.handle(:next, state)
    {:slash_commands, %{selected: 0}} = state.overlay
  end

  test "Tab completes the selected name into the draft and closes the popup" do
    state = synced(draft: "/mod")

    {:noreply, state} = SlashCommands.handle(:complete, state)

    assert Input.get_value(state.input) == "/model "
    assert state.overlay == nil
    assert state.slash_commands.dismissed == nil

    # The caret sits past the completed name, so the popup stays closed.
    {state, commands} = SlashCommands.sync(state)
    assert commands == []
    assert state.overlay == nil
  end

  test "Tab with nothing selected does nothing" do
    state = synced(draft: "/zzz")

    {:noreply, state, render?: false} = SlashCommands.handle(:complete, state)
    assert Input.get_value(state.input) == "/zzz"
  end

  test "Enter runs the selected command and clears the draft" do
    state = synced(draft: "/he")

    {:noreply, state} = SlashCommands.handle(:accept, state)

    assert {:help, _help} = state.overlay
    assert Input.get_value(state.input) == ""
  end

  test "Enter with nothing selected submits the draft like a plain Enter" do
    state = synced(draft: "/zzz")

    {:noreply, state, commands: [%ExRatatui.Command{}]} = SlashCommands.handle(:accept, state)

    assert Input.get_value(state.input) == ""
    assert state.pending_operation.kind == :submit
  end

  test "slash_commands keybinds navigate, complete, run, dismiss, and fall through" do
    assert Keybinds.slash_commands(%Key{code: "up", modifiers: []}) == :previous
    assert Keybinds.slash_commands(%Key{code: "down", modifiers: []}) == :next
    assert Keybinds.slash_commands(%Key{code: "p", modifiers: ["ctrl"]}) == :previous
    assert Keybinds.slash_commands(%Key{code: "n", modifiers: ["ctrl"]}) == :next
    assert Keybinds.slash_commands(%Key{code: "esc", modifiers: []}) == :close
    assert Keybinds.slash_commands(%Key{code: "tab", modifiers: []}) == :complete
    assert Keybinds.slash_commands(%Key{code: "enter", modifiers: []}) == :accept
    assert Keybinds.slash_commands(%Key{code: "l", modifiers: []}) == :composer
    assert Keybinds.slash_commands(%Key{code: "f1", modifiers: []}) == :composer
  end

  # -- dispatch -------------------------------------------------------------

  test "dispatch runs a named command and clears the draft" do
    state = base_state(draft: "/help")

    {:noreply, state} = SlashCommands.dispatch(state, Input.get_value(state.input))

    assert {:help, _help} = state.overlay
    assert Input.get_value(state.input) == ""
  end

  test "dispatch keeps the draft when the command refuses" do
    state = base_state(draft: "/tree")

    {:noreply, state} = SlashCommands.dispatch(state, Input.get_value(state.input))

    assert state.overlay == nil
    assert Input.get_value(state.input) == "/tree"
    assert state.notice =~ "no conversation tree"
  end

  test "dispatch of an idle-only command during a turn keeps the draft" do
    state = base_state(draft: "/resume")
    state = %{state | active_turn: %{id: "turn-1"}}

    {:noreply, state} = SlashCommands.dispatch(state, Input.get_value(state.input))

    assert Input.get_value(state.input) == "/resume"
    assert state.notice == "/resume is available when idle · draft kept"
  end

  test "dispatch carries a command's async commands and reply options" do
    state =
      base_state(
        draft: "/resume",
        resume_session: fn _id -> {:error, :unused} end,
        list_recent_sessions: fn _cursor -> {:ok, %{sessions: [], next_cursor: nil}} end
      )

    {:noreply, state, commands: [%ExRatatui.Command{}]} =
      SlashCommands.dispatch(state, Input.get_value(state.input))

    assert {:resume, _resume} = state.overlay
    assert Input.get_value(state.input) == ""
  end

  test "dispatch returns :prompt for drafts that are not commands" do
    state = base_state(draft: "hello")
    assert SlashCommands.dispatch(state, "hello") == :prompt

    state = base_state(draft: "/unknown thing")
    assert SlashCommands.dispatch(state, "/unknown thing") == :prompt
  end

  test "dispatch of /compact starts compaction and clears the draft" do
    state = base_state(draft: "/compact")

    {:noreply, state, commands: [%ExRatatui.Command{}]} =
      SlashCommands.dispatch(state, Input.get_value(state.input))

    assert state.pending_operation.kind == :compact
    assert Input.get_value(state.input) == ""
  end

  test "dispatch of /new asks for confirmation and clears the draft" do
    state = base_state(draft: "/new", new_session: fn _overrides -> {:error, :unused} end)

    {:noreply, state} = SlashCommands.dispatch(state, Input.get_value(state.input))

    assert {:confirm_new_session, _confirm} = state.overlay
    assert Input.get_value(state.input) == ""
  end

  # -- rendering ------------------------------------------------------------

  test "widgets anchors the popup above the composer with described rows" do
    state = synced(draft: "/t")
    composer = %Rect{x: 2, y: 20, width: 76, height: 3}

    [{_clear, %Rect{}}, {%Block{} = block, rect}, {%List{} = list, inner}] =
      SlashCommands.widgets(state, composer)

    assert rect.x == 2
    assert rect.y + rect.height == composer.y
    assert rect.width == composer.width
    assert block.title =~ "Commands"

    # The popup floats over live transcript rows, so its panel must fill an
    # opaque background or the text behind bleeds through the completion.
    assert block.style == Theme.style(:surface_raised)

    assert Enum.at(list.items, 0) == "/thinking  pick the reasoning level · F2"
    assert length(list.items) == 3
    assert Enum.at(list.items, 1) =~ "jump to an earlier branch"
    assert Enum.at(list.items, 2) =~ "inspect subagent tasks"

    assert inner.x == rect.x + 1
    assert inner.width == rect.width - 2

    # A terminal too short for the popup skips it rather than clipping.
    assert SlashCommands.widgets(state, %Rect{x: 0, y: 2, width: 80, height: 3}) == []
  end

  test "widgets shows a hint when nothing matches" do
    state = synced(draft: "/zzz")
    composer = %Rect{x: 0, y: 20, width: 80, height: 3}

    assert [
             {%ExRatatui.Widgets.Clear{}, %Rect{}},
             {%Block{}, %Rect{}},
             {%ExRatatui.Widgets.Paragraph{text: " No matching command"}, %Rect{}}
           ] =
             SlashCommands.widgets(state, composer)
  end

  test "the popup paints an opaque background over the rows behind it" do
    state = synced(draft: "/t")
    composer = %Rect{x: 0, y: 20, width: 80, height: 3}

    session = CellSession.new(80, 24)
    on_exit(fn -> CellSession.close(session) end)

    # A wall of filler stands in for the transcript behind the popup. It is
    # drawn in the same frame as the popup, like the real scene: a panel's
    # style fill only recolors the cells behind it, so without the clear the
    # filler's symbols would survive between the popup's rows.
    filler = %Paragraph{
      text: Enum.map_join(1..24, "\n", fn _row -> String.duplicate("X", 80) end)
    }

    [{_clear, %Rect{} = rect} | _content] = SlashCommands.widgets(state, composer)

    :ok =
      CellSession.draw(session, [
        {filler, %Rect{x: 0, y: 0, width: 80, height: 24}}
        | SlashCommands.widgets(state, composer)
      ])

    snapshot = CellSession.take_cells(session)

    inside =
      for cell <- snapshot.cells,
          cell.row in rect.y..(rect.y + rect.height - 1),
          cell.col in rect.x..(rect.x + rect.width - 1) do
        cell
      end

    assert length(inside) == rect.width * rect.height

    # Every cell of the rectangle carries a painted background, and none of
    # the filler shows through: without the clear the transcript rows behind
    # would merge with the popup's text.
    assert Enum.all?(inside, &(&1.bg != :reset))
    refute Enum.any?(inside, &(&1.symbol == "X"))
  end

  # -- end-to-end key wiring -------------------------------------------------

  test "typing / opens the popup, filtering narrows it, and Enter runs the command" do
    state = base_state(draft: "") |> Viewport.refresh()

    {:noreply, state} = TUI.handle_event(%Key{code: "/", modifiers: []}, state)
    {:slash_commands, %{query: ""}} = state.overlay

    {:noreply, state} = TUI.handle_event(%Key{code: "h", modifiers: []}, state)
    {:slash_commands, %{query: "h"}} = state.overlay

    # While the popup is open the arrows move its selection, not history.
    {:noreply, state} = TUI.handle_event(%Key{code: "down", modifiers: []}, state)
    {:slash_commands, %{selected: 0}} = state.overlay

    {:noreply, state} = TUI.handle_event(%Key{code: "enter", modifiers: []}, state)
    assert {:help, _help} = state.overlay
    assert Input.get_value(state.input) == ""
  end

  test "Tab completes the selected command through the key path" do
    state = base_state(draft: "") |> Viewport.refresh()

    {:noreply, state} = TUI.handle_event(%Key{code: "/", modifiers: []}, state)
    {:noreply, state} = TUI.handle_event(%Key{code: "m", modifiers: []}, state)
    {:noreply, state} = TUI.handle_event(%Key{code: "o", modifiers: []}, state)

    {:noreply, state} = TUI.handle_event(%Key{code: "tab", modifiers: []}, state)

    assert Input.get_value(state.input) == "/model "
    assert state.overlay == nil
  end

  test "Esc dismisses the popup through the key path without clearing the draft" do
    state = base_state(draft: "/re") |> Viewport.refresh()
    {state, _commands} = SlashCommands.sync(state)

    {:noreply, state} = TUI.handle_event(%Key{code: "esc", modifiers: []}, state)

    assert state.overlay == nil
    assert Input.get_value(state.input) == "/re"
  end

  test "a space after the name hands the keyboard back to the composer" do
    state = base_state(draft: "") |> Viewport.refresh()

    {:noreply, state} = TUI.handle_event(%Key{code: "/", modifiers: []}, state)
    assert {:slash_commands, _popup} = state.overlay

    {:noreply, state} = TUI.handle_event(%Key{code: " ", modifiers: []}, state)
    assert state.overlay == nil

    # Arrows are history again once the popup is closed.
    {:noreply, state, _opts} = TUI.handle_event(%Key{code: "up", modifiers: []}, state)
    assert state.overlay == nil
  end
end
