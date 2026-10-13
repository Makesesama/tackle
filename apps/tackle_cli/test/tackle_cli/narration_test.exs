defmodule Tackle.CLI.NarrationTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias Tackle.CLI.Output.Progress
  alias Tackle.CLI.TUI.{RuntimeEvents, State, Subagents, Viewport, WorkflowView}
  alias Tackle.CLI.Widgets.Input
  alias Tackle.CLI.Widgets.Subagents, as: Sidebar
  alias Tackle.Lib.Event
  alias Tackle.Lib.State, as: AgentState

  describe "subagent rows" do
    test "a narration replaces the live work of its running row" do
      state = shell() |> start("one", "Inspect") |> started("one", "run-one")
      state = deliver(state, child_tool("run-one", "one", "lib/session.ex"))

      assert [%{subagent_work: "Running read · read  lib/session.ex"} = task] =
               Subagents.tasks(state)

      assert [%{work: "Running read · read  lib/session.ex", narrated?: false}] =
               sidebar(state).tasks

      refute Map.has_key?(task, :narration)

      state = deliver(state, narration("run-one", "one", "  reading the\nsession  tests "))

      assert [%{narration: "reading the session tests"}] = Subagents.tasks(state)
      assert state.subagents["run-one"].narration == "reading the session tests"

      assert [%{work: "reading the session tests", narrated?: true}] = sidebar(state).tasks
      assert rendered(state) =~ "reading the session tests"

      # Live work keeps updating underneath.
      state = deliver(state, child_tool("run-one", "one", "lib/other.ex"))
      assert [%{subagent_work: "Running read · read  lib/other.ex"}] = Subagents.tasks(state)
      assert [%{work: "reading the session tests"}] = sidebar(state).tasks
    end

    test "a finished run drops its narration and late narration does not revive it" do
      state =
        shell()
        |> start("one", "Inspect")
        |> started("one", "run-one")
        |> deliver(narration("run-one", "one", "reading"))

      state =
        deliver(
          state,
          Event.new(:subagent_finished, %{run_id: "run-one", tool_call_id: "one", status: :ok})
        )

      refute Map.has_key?(state.subagents["run-one"], :narration)
      refute Enum.any?(state.tool_activity, &Map.has_key?(&1, :narration))

      assert {:noreply, ^state, render?: false} =
               RuntimeEvents.handle(
                 {:tackle_event, "session", nil, narration("run-one", "one", "late")},
                 state
               )
    end

    test "background rows tracked after their turn settled are narrated too" do
      state = shell() |> start("one", "Inspect") |> started("one", "run-one")

      state =
        state
        |> deliver(
          Event.new(:tool_execution_end, %{
            tool_call_id: "one",
            name: "subagent",
            status: :completed,
            result: "Started background subagent run-one."
          }),
          "turn"
        )
        |> handle({:tackle_turn_finished, "session", "turn", {:ok, %AgentState{}}})

      state = deliver(state, narration("run-one", "one", "still reading"))

      assert [%{run_id: "run-one", narration: "still reading"}] = Subagents.tasks(state)
      assert [%{work: "still reading", narrated?: true}] = sidebar(state).tasks
    end

    test "narration for other sessions, unknown runs, or with a turn id is ignored" do
      state = shell() |> start("one", "Inspect") |> started("one", "run-one")

      for message <- [
            {:tackle_event, "other", nil, narration("run-one", "one", "x")},
            {:tackle_event, "session", nil, narration("run-two", "two", "x")},
            {:tackle_event, "session", nil, narration("run-one", "one", "   ")},
            {:tackle_event, "session", "turn", narration("run-one", "one", "x")}
          ] do
        assert {:noreply, ignored, render?: false} = RuntimeEvents.handle(message, state)
        refute Map.has_key?(ignored.subagents["run-one"], :narration)
      end
    end

    test "narration never stands in for the first event of a pending submit" do
      state = %{shell() | active_turn: nil, pending_operation: %{kind: :submit}}

      {:noreply, state, render?: false} =
        RuntimeEvents.handle(
          {:tackle_event, "session", nil, narration("run-one", "one", "x")},
          state
        )

      assert state.active_turn == nil
    end
  end

  describe "workflow nodes" do
    test "a narration naming a run_workflow call lands on its run node" do
      state =
        shell()
        |> deliver(
          Event.new(:tool_start, %{
            tool_call_id: "wf",
            name: "run_workflow",
            arguments: %{"script" => "return 1"}
          }),
          "turn"
        )
        |> deliver(
          Event.new(:workflow_progress, %{
            kind: :run_started,
            tool_call_id: "wf",
            run_id: "wf-run",
            profile: "scout",
            prompt: "Map the code"
          }),
          "turn"
        )

      state = deliver(state, narration("wf-run", "wf", "mapping the session code"))

      [tool] = Enum.filter(state.tool_activity, &(&1.name == "run_workflow"))
      assert tool.workflow.runs["wf-run"].narration == "mapping the session code"
      assert state.subagents == %{}

      rows = WorkflowView.rows(tool.workflow, 80, :preview)
      text = Enum.map_join(rows, "\n", fn row -> Enum.map_join(row.spans, & &1.content) end)
      assert text =~ "Map the code · mapping the session code"
    end
  end

  test "plain progress output ignores narration" do
    assert Progress.event_label(narration("run-one", "one", "reading")) == nil
  end

  defp sidebar(state), do: Sidebar.from_activity(Subagents.tasks(state), nil, 0)

  defp rendered(state) do
    [{paragraph, _rect}] =
      ExRatatui.Widget.render(sidebar(state), %Rect{width: 40, height: 6})

    paragraph.text |> Enum.flat_map(& &1.spans) |> Enum.map_join(& &1.content)
  end

  defp narration(run_id, tool_call_id, text) do
    Event.new(:narration, %{
      run_id: run_id,
      tool_call_id: tool_call_id,
      text: text,
      auxiliary: true
    })
  end

  defp child_tool(run_id, tool_call_id, path) do
    Event.new(:subagent_progress, %{
      run_id: run_id,
      tool_call_id: tool_call_id,
      profile: "scout",
      background: false,
      event:
        Event.new(:tool_start, %{
          tool_call_id: "c-" <> path,
          name: "read",
          arguments: %{"path" => path}
        })
    })
  end

  defp start(state, id, prompt) do
    deliver(
      state,
      Event.new(:tool_start, %{
        tool_call_id: id,
        name: "subagent",
        arguments: %{"profile" => "scout", "prompt" => prompt}
      }),
      "turn"
    )
  end

  defp started(state, id, run_id) do
    deliver(
      state,
      Event.new(:subagent_started, %{
        tool_call_id: id,
        run_id: run_id,
        profile: "scout",
        model: "test/scout",
        status: :running
      }),
      "turn"
    )
  end

  defp deliver(state, event, turn_id \\ nil),
    do: handle(state, {:tackle_event, "session", turn_id, event})

  defp handle(state, message) do
    case RuntimeEvents.handle(message, state) do
      {:noreply, state} -> state
      {:noreply, state, _opts} -> state
    end
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
