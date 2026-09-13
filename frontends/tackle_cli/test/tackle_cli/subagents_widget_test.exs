defmodule Tackle.CLI.SubagentsWidgetTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias ExRatatui.Layout.Rect
  alias Tackle.CLI.Keybinds
  alias Tackle.CLI.TUI.{Layout, RuntimeEvents, State, Viewport}
  alias Tackle.CLI.TUI.Subagents
  alias Tackle.CLI.Widgets.Input
  alias Tackle.CLI.Widgets.Subagents, as: Sidebar
  alias Tackle.Lib.Event
  alias Tackle.Lib.State, as: AgentState

  describe "task list" do
    test "keeps only active subagents in request order and shortens the assignment" do
      widget =
        Sidebar.from_activity([
          task("one", "scout", "Inspect the layout cache and report every row height", 12_000),
          %{name: "bash", status: :running, arguments: %{}, elapsed_ms: 1_000},
          %{
            name: "subagent",
            status: :completed,
            arguments: %{"profile" => "reviewer", "prompt" => "Review"}
          },
          task("two", "worker", "Implement the widget", 65_000)
        ])

      assert widget.tasks == [
               %{
                 id: "one",
                 profile: "scout",
                 model: "test/scout",
                 summary: "Inspect the layout cache and report…",
                 elapsed: "12s"
               },
               %{
                 id: "two",
                 profile: "worker",
                 model: "test/worker",
                 summary: "Implement the widget",
                 elapsed: "1m 5s"
               }
             ]

      assert widget.selected == nil
    end

    test "elapsed time stays compact and no duration is invented" do
      assert elapsed(nil) == nil
      assert elapsed(12_000) == "12s"
      assert elapsed(65_000) == "1m 5s"
      assert elapsed(599_000) == "9m 59s"
    end

    test "a missing profile and prompt still produce a task row" do
      assert [%{profile: "subagent", model: nil, summary: "Working", elapsed: nil}] =
               Sidebar.from_activity([%{name: "subagent", status: :running, id: "one"}]).tasks
    end

    defp elapsed(ms) do
      Sidebar.from_activity([task("one", "scout", "Inspect", ms)]).tasks
      |> hd()
      |> Map.fetch!(:elapsed)
    end

    defp task(id, profile, prompt, ms) do
      %{
        name: "subagent",
        status: :running,
        id: id,
        arguments: %{"profile" => profile, "prompt" => prompt},
        model: "test/#{profile}",
        elapsed_ms: ms
      }
    end
  end

  describe "layout" do
    test "the sidebar opens beside the transcript without consuming vertical space" do
      closed = Layout.regions(90, 24, 1, false, false)
      open = Layout.regions(90, 24, 1, false, true)

      assert closed.sidebar == nil
      assert %Rect{width: 30, height: height} = open.sidebar
      assert open.transcript.width == 60
      assert open.transcript.height == height
      assert open.sidebar.x == open.transcript.x + open.transcript.width
    end

    test "narrow terminals keep a usable transcript and never overlap the sidebar" do
      open = Layout.regions(24, 24, 1, false, true)

      assert open.transcript.width == 6
      assert open.sidebar.width == 18
      assert open.transcript.width + open.sidebar.width == 24
    end
  end

  describe "controls" do
    test "F7 focuses the sidebar and every sidebar chord is bound" do
      key = %Key{code: "f7", modifiers: []}
      assert Keybinds.base(key, :composer) == :subagents
      assert Keybinds.base(key, :transcript) == :subagents
      refute Keybinds.repeatable?(key)

      assert Keybinds.subagents(%Key{code: "up"}) == :previous
      assert Keybinds.subagents(%Key{code: "down"}) == :next
      assert Keybinds.subagents(%Key{code: "enter"}) == :inspect
      assert Keybinds.subagents(%Key{code: "esc"}) == :leave
      assert Keybinds.subagents(%Key{code: "x"}) == :ignore

      assert Keybinds.base(%Key{code: "up", modifiers: []}, :subagents) ==
               {:subagents, :previous}
    end

    test "focus, selection, and details work while a child runs" do
      state = shell() |> start("one", "Inspect") |> start("two", "Implement")

      assert Subagents.active?(state)
      assert Enum.map(Subagents.tasks(state), & &1.id) == ["one", "two"]

      {:noreply, focused} = Subagents.focus(state)
      assert focused.focus == :subagents
      assert focused.subagent_selected == "one"

      {:noreply, moved} = Subagents.handle(:next, focused)
      assert moved.subagent_selected == "two"

      {:noreply, inspected} = Subagents.handle(:inspect, moved)
      assert {:inspector, inspector} = inspected.overlay
      assert inspector.entry.id == "tool:two"

      {:noreply, left} = Subagents.handle(:leave, inspected)
      assert left.focus == :composer
      assert left.subagent_selected == nil
    end

    test "focus without a running child only reports a notice" do
      {:noreply, state} = Subagents.focus(shell())
      assert state.focus == :composer
      assert state.notice == "No active subagents"
    end

    test "the sidebar closes and returns focus when the last child settles" do
      {:noreply, focused} = shell() |> start("one", "Inspect") |> Subagents.focus()

      {:noreply, settled} =
        RuntimeEvents.handle(
          {:tackle_event, "session", "turn",
           Event.new(:tool_execution_end, %{
             tool_call_id: "one",
             name: "subagent",
             status: :completed,
             result: "findings"
           })},
          focused
        )

      refute Subagents.active?(settled)
      assert settled.focus == :composer
      assert settled.subagent_selected == nil
    end

    test "focus stays on the sidebar when one task of two settles" do
      {:noreply, focused} =
        shell() |> start("one", "Inspect") |> start("two", "Implement") |> focus_two()

      {:noreply, settled} =
        RuntimeEvents.handle(
          {:tackle_event, "session", "turn",
           Event.new(:tool_execution_end, %{
             tool_call_id: "two",
             name: "subagent",
             status: :failed,
             error: "timed out"
           })},
          focused
        )

      assert settled.focus == :subagents
      assert settled.subagent_selected == "one"
    end

    defp focus_two(state) do
      {:noreply, focused} = Subagents.focus(state)
      {:noreply, focused} = Subagents.handle(:next, focused)
      {:noreply, focused}
    end
  end

  test "native widget animates each running task" do
    {:noreply, state} = shell() |> start("one", "Inspect") |> Subagents.focus()

    assert [{paragraph, %Rect{width: 24, height: 5}}] =
             ExRatatui.Widget.render(
               Sidebar.from_activity(Subagents.tasks(state), state.subagent_selected, 0),
               %Rect{width: 24, height: 5}
             )

    text = paragraph.text |> Enum.flat_map(& &1.spans) |> Enum.map_join(& &1.content)

    assert text =~ "Tasks"
    assert text =~ "› ⠋ scout"
    assert text =~ "model pending"
    assert text =~ "Inspect"

    assert [{animated, _rect}] =
             ExRatatui.Widget.render(
               Sidebar.from_activity(Subagents.tasks(state), state.subagent_selected, 1),
               %Rect{width: 24, height: 5}
             )

    animated_text = animated.text |> Enum.flat_map(& &1.spans) |> Enum.map_join(& &1.content)
    assert animated_text =~ "› ⠙ scout"
  end

  defp start(state, id, prompt) do
    {:noreply, state} =
      RuntimeEvents.handle(
        {:tackle_event, "session", "turn",
         Event.new(:tool_start, %{
           tool_call_id: id,
           name: "subagent",
           arguments: %{"profile" => "scout", "prompt" => prompt}
         })},
        state
      )

    state
  end

  defp shell do
    Viewport.refresh(%State{
      session_id: "session",
      active_turn: %{id: "turn"},
      input: Input.new(),
      agent_state: %AgentState{},
      conversation: Viewport.new_conversation(80, 24)
    })
  end
end
