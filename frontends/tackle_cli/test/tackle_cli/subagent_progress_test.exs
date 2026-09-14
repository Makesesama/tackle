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

  test "streamed tool input previews a write before execution starts" do
    state = shell()

    state =
      event(state, :message_delta, %{
        field: :tool_input,
        tool_call_id: "write-one",
        tool_name: "write",
        delta: ~s({"path":"lib/demo.ex","content":"hel)
      })

    [partial] = cards(state)
    assert partial.tool_status == :preparing
    assert partial.tool_arguments =~ ~s("path":"lib/demo.ex")

    state =
      event(state, :message_delta, %{
        field: :tool_input,
        tool_call_id: "write-one",
        tool_name: "write",
        delta: ~s(lo"})
      })

    [complete] = cards(state)
    rendered = render_text(complete)
    assert rendered =~ "lib/demo.ex"
    assert rendered =~ "preparing"
    assert rendered =~ "hello"
  end

  test "streamed tool input keeps a bounded valid UTF-8 presentation buffer" do
    state =
      event(shell(), :message_delta, %{
        field: :tool_input,
        tool_call_id: "write-large",
        tool_name: "write",
        delta: ~s({"path":"large.ex","content":") <> String.duplicate("界", 30_000)
      })

    [entry] = cards(state)
    assert byte_size(entry.tool_arguments) <= 50 * 1_024
    assert String.valid?(entry.tool_arguments)
    assert String.starts_with?(entry.tool_arguments, ~s({"path":"large.ex"))
    assert render_text(entry) =~ "large.ex"
  end

  test "a provider retry discards its provisional tool input card" do
    state = event(shell(), :message_start, %{role: :assistant}, id: "assistant-one")

    state =
      event(
        state,
        :message_delta,
        %{
          field: :tool_input,
          tool_call_id: "write-one",
          tool_name: "write",
          delta: ~s({"path":"retry.ex","content":"partial)
        },
        id: "assistant-one"
      )

    assert [%{tool_status: :preparing}] = cards(state)

    retried = event(state, :retry_scheduled, %{attempt: 1}, id: "assistant-one")
    assert retried.tool_activity == []
    assert cards(retried) == []
  end

  test "bash progress replaces the live tail with the canonical settlement" do
    state =
      event(shell(), :tool_start, %{
        tool_call_id: "bash-one",
        name: "bash",
        arguments: %{"command" => "mix test"}
      })

    state =
      state
      |> event(:tool_progress, %{tool_call_id: "bash-one", name: "bash", delta: "first\n"})
      |> event(:tool_progress, %{tool_call_id: "bash-one", name: "bash", delta: "second\n"})

    [running] = cards(state)
    assert running.tool_status == :running
    assert running.tool_output == "first\nsecond\n"
    assert render_text(running) =~ "second"

    settled =
      event(state, :tool_execution_end, %{
        tool_call_id: "bash-one",
        name: "bash",
        status: :completed,
        result: "canonical output"
      })

    [completed] = cards(settled)
    assert completed.tool_status == :completed
    assert completed.tool_output == "canonical output"
    refute completed.tool_output =~ "first"
  end

  test "child events update the matching subagent card and sidebar task" do
    state =
      shell()
      |> start("one", "Inspect")
      |> event(:subagent_started, %{
        tool_call_id: "one",
        run_id: "run-one",
        profile: "scout",
        model: "test/scout",
        status: :running
      })

    state =
      event(state, :subagent_progress, %{
        run_id: "run-one",
        tool_call_id: "one",
        event: Event.new(:message_delta, %{field: :content, delta: "Inspecting"})
      })

    state =
      event(state, :subagent_progress, %{
        run_id: "run-one",
        tool_call_id: "one",
        event:
          Event.new(:tool_start, %{
            tool_call_id: "child-bash",
            name: "bash",
            arguments: %{"command" => "mix compile"}
          })
      })

    assert [%{subagent_work: work}] = Tackle.CLI.TUI.Subagents.tasks(state)
    assert work =~ "Running bash"
    assert work =~ "mix compile"
    assert render_text(hd(cards(state))) =~ "Now: Running bash"

    state =
      event(state, :subagent_progress, %{
        run_id: "run-one",
        event:
          Event.new(:tool_progress, %{
            tool_call_id: "child-bash",
            name: "bash",
            delta: "compiled 42 files\n"
          })
      })

    assert [
             %{
               subagent_work: "compiled 42 files",
               subagent_output: "Inspecting\ncompiled 42 files\n"
             }
           ] = Tackle.CLI.TUI.Subagents.tasks(state)

    assert render_text(hd(cards(state))) =~ "compiled 42 files"
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

  test "an automatic background-notice turn is adopted before its events" do
    state = %{shell() | active_turn: nil, activity: nil}

    assert {:noreply, started} =
             RuntimeEvents.handle(
               {:tackle_turn_started, "session", "notice-turn", :background_notice},
               state
             )

    assert started.active_turn == %{
             id: "notice-turn",
             operation: :continue,
             cancellation_requested?: false
           }

    assert started.activity == "processing subagent notice"

    assert {:noreply, progressed} =
             RuntimeEvents.handle(
               {:tackle_event, "session", "notice-turn",
                Event.new(:status_change, %{status: :responding})},
               started
             )

    assert progressed.activity == "responding"

    assert {:noreply, settled} =
             RuntimeEvents.handle(
               {:tackle_turn_finished, "session", "notice-turn", {:ok, started.agent_state}},
               started
             )

    assert settled.active_turn == nil
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

  defp render_text(entry) do
    entry
    |> MessageView.render_entry(100)
    |> Enum.flat_map(fn {widget, _height} -> widget.text end)
    |> Enum.flat_map(& &1.spans)
    |> Enum.map_join(& &1.content)
  end

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

  defp event(state, type, data, opts \\ []) do
    case RuntimeEvents.handle(
           {:tackle_event, "session", "turn", Event.new(type, data, opts)},
           state
         ) do
      {:noreply, state} -> state
      {:noreply, state, _opts} -> state
    end
  end

  defp shell do
    state = %State{
      session_id: "session",
      active_turn: %{id: "turn"},
      input: Input.new(),
      agent_state: %AgentState{},
      conversation: Viewport.new_conversation(80, 24)
    }

    Viewport.refresh(%{state | stream: %{state.stream | coalesce?: false}})
  end
end
