defmodule Tackle.CLI.SubagentProgressTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.{Conversation, MessageView, RuntimeEvents, State, Viewport}
  alias Tackle.CLI.Widgets.Input
  alias Tackle.Lib.{Event, Message}
  alias Tackle.Lib.State, as: AgentState

  test "parallel scouts keep assignments, independent clocks, and stable order" do
    state = shell()
    state = start(state, "one", "Inspect first") |> start("two", "Inspect second")
    assert state.activity == "running subagent · scout"
    assert Enum.map(cards(state), & &1.id) == ["tool:one", "tool:two"]

    # Move local observation times backwards instead of sleeping.
    state = age(state, "one", 65_000) |> age("two", 10_000)
    {:noreply, ticked} = RuntimeEvents.handle({:tui_spinner_tick}, state)
    [one, two] = cards(ticked)
    assert one.tool_elapsed_ms >= 65_000
    assert two.tool_elapsed_ms >= 10_000
    assert one.tool_arguments["prompt"] == "Inspect first"
    assert two.tool_arguments["prompt"] == "Inspect second"

    completed =
      event(ticked, :tool_execution_end, %{
        tool_call_id: "two",
        name: "subagent",
        status: :completed,
        result: "second findings"
      })

    assert completed.activity == "completed subagent · scout"
    [one, two] = cards(completed)
    assert one.tool_status == :running
    assert two.tool_status == :completed
    duration = two.tool_elapsed_ms

    # Ordered settlement must not restart the clock or discard the assignment.
    settled =
      event(completed, :tool_end, %{
        tool_call_id: "two",
        name: "subagent",
        result: "second findings"
      })

    {:noreply, ticked} = RuntimeEvents.handle({:tui_spinner_tick}, age(settled, "one", 70_000))
    [one, two] = cards(ticked)
    assert one.tool_elapsed_ms >= 70_000
    assert two.tool_elapsed_ms == duration
    assert two.tool_arguments["prompt"] == "Inspect second"
    assert MessageView.full_text(two) == "second findings"

    failed =
      event(ticked, :tool_error, %{
        tool_call_id: "one",
        name: "subagent",
        error: "subagent timed out"
      })

    [one, two] = cards(failed)
    assert one.tool_status == :failed
    assert one.tool_output == "subagent timed out"
    assert two.tool_status == :completed
  end

  test "subagent start metadata adds the resolved model to the live card" do
    state = start(shell(), "one", "Inspect")

    with_model =
      event(state, :subagent_started, %{
        tool_call_id: "one",
        run_id: "run-one",
        profile: "scout",
        model: "openai-codex/gpt-5.5",
        status: :running
      })

    [card] = cards(with_model)
    assert card.model == "openai-codex/gpt-5.5"

    rendered =
      card
      |> MessageView.render_entry(100)
      |> Enum.flat_map(fn {widget, _height} -> widget.text end)
      |> Enum.flat_map(& &1.spans)
      |> Enum.map_join(& &1.content)

    assert rendered =~ "openai-codex/gpt-5.5"
  end

  test "clock refresh preserves the reading anchor and only changes live entries" do
    state = shell()
    messages = Enum.map(1..30, &Message.user("message #{&1}"))
    state = Viewport.refresh(%{state | agent_state: %{state.agent_state | messages: messages}})
    state = state |> start("one", "Inspect") |> Viewport.scroll_to(:start)
    anchor = state.conversation.anchor
    settled = state.conversation.sections.settled
    {:noreply, ticked} = RuntimeEvents.handle({:tui_spinner_tick}, age(state, "one", 2_000))
    assert ticked.conversation.anchor == anchor
    assert ticked.conversation.sections.settled == settled
    refute ticked.conversation.follow?
  end

  test "foreign events are ignored and a completion without a start has no invented duration" do
    state = shell()
    foreign = {:tackle_event, "other", "turn", Event.new(:tool_start, %{name: "subagent"})}
    assert {:noreply, ^state, render?: false} = RuntimeEvents.handle(foreign, state)

    state =
      event(state, :tool_error, %{tool_call_id: "missing", name: "subagent", error: "rejected"})

    [entry] = cards(state)
    assert entry.tool_elapsed_ms == nil
    assert entry.tool_status == :failed
  end

  test "turn cancellation clears live clocks and never leaves a running card" do
    state = start(shell(), "one", "Inspect")

    {:noreply, cancelled} =
      RuntimeEvents.handle(
        {:tackle_turn_finished, "session", "turn", {:cancelled, state.agent_state}},
        state
      )

    assert cancelled.outcome == :cancelled
    assert cancelled.tool_activity == []
    assert cards(cancelled) == []

    assert {:noreply, ^cancelled, render?: false} =
             RuntimeEvents.handle({:tui_spinner_tick}, cancelled)
  end

  defp cards(state),
    do: state.conversation |> Conversation.entries() |> Enum.filter(&(&1.kind == :tool))

  defp age(state, id, ms) do
    tools =
      Enum.map(state.tool_activity, fn tool ->
        if tool.id == id,
          do: Map.put(tool, :started_at_ms, System.monotonic_time(:millisecond) - ms),
          else: tool
      end)

    %{state | tool_activity: tools}
  end

  defp start(state, id, prompt),
    do:
      event(state, :tool_start, %{
        tool_call_id: id,
        name: "subagent",
        arguments: %{"profile" => "scout", "prompt" => prompt}
      })

  defp event(state, type, data) do
    {:noreply, state} =
      RuntimeEvents.handle({:tackle_event, "session", "turn", Event.new(type, data)}, state)

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
