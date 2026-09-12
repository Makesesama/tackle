defmodule Tackle.CLI.TUI.CompactionTest do
  use ExUnit.Case, async: true

  alias Tackle.CLI.TUI.{
    Browser,
    Compaction,
    Conversation,
    MessageView,
    RuntimeEvents,
    State,
    StatusView,
    View,
    Viewport
  }

  alias Tackle.Lib.Compaction, as: LibCompaction
  alias Tackle.Lib.{Event, Message}
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Session.Snapshot

  test "manual progress is visible immediately and completion exposes the summary once" do
    state = shell()
    {:noreply, running, commands: [_]} = Compaction.request(state)
    assert card(running).content == "Compacting context…"
    assert Tackle.CLI.Widgets.Input.get_value(running.input) == "draft"

    record = record()

    snapshot = %Snapshot{
      session_id: "session",
      agent_state: %{state.agent_state | model_messages: [record.summary_message]}
    }

    event = Event.new(:compaction_end, Map.merge(record, %{status: :completed}))
    {:noreply, ended} = RuntimeEvents.handle({:tackle_compaction, "session", event}, running)
    assert card(ended).content =~ "1.2k → 300 est. tokens"

    {:noreply, notified} =
      RuntimeEvents.handle({:tackle_session_compacted, "session", snapshot, record}, ended)

    {:noreply, completed} =
      RuntimeEvents.handle(
        {:tui_operation_result, running.pending_operation.ref, :compact, {:ok, snapshot, record}},
        notified
      )

    assert completed.pending_operation == nil

    assert length(
             Enum.filter(Conversation.entries(completed.conversation), &(&1.kind == :compaction))
           ) == 1

    assert MessageView.source(card(completed)) =~ "background summary"
    assert card(completed).collapsed?
    assert completed.agent_state.messages == state.agent_state.messages
    assert Tackle.CLI.Widgets.Input.get_value(completed.input) == "draft"

    {:noreply, browsing} = Browser.toggle_focus(completed)
    {:noreply, inspecting} = Browser.handle(:inspect, browsing)
    assert {:inspector, %{entry: %{kind: :compaction}}} = inspecting.overlay
  end

  test "manual cards stay between messages and scroll away with the conversation" do
    {:noreply, running, _} = Compaction.request(shell())
    completed = running |> Compaction.completed(record()) |> Viewport.refresh()
    card_id = card(completed).id
    later = Enum.map(1..30, &Message.assistant(content: "later message #{&1}"))

    state =
      %{
        completed
        | agent_state: %{
            completed.agent_state
            | messages: completed.agent_state.messages ++ later
          }
      }
      |> Viewport.refresh()

    assert [user, checkpoint | rest] = Conversation.entries(state.conversation)
    assert user.kind == :user
    assert checkpoint.id == card_id
    assert Enum.map(rest, & &1.content) == Enum.map(later, & &1.content)

    [{_, _}, {%Tackle.CLI.Widgets.Conversation{} = transcript, rect} | _] = View.scene(state, nil)
    assert rect == state.conversation.rect
    assert transcript.state == state.conversation.native

    terminal = ExRatatui.init_test_terminal(elem(state.size, 0), elem(state.size, 1))
    :ok = ExRatatui.draw(terminal, View.scene(state, nil))
    refute ExRatatui.get_buffer_content(terminal) =~ "Context compacted"

    reading = Viewport.scroll_to(state, :start)
    :ok = ExRatatui.draw(terminal, View.scene(reading, nil))
    assert ExRatatui.get_buffer_content(terminal) =~ "Context compacted"
  end

  test "automatic cards keep their place between streamed messages after settlement" do
    state = shell()
    state = %{state | active_turn: %{id: "turn"}, stream: %{state.stream | coalesce?: false}}
    before = Message.assistant(content: "before compaction", id: "before")
    after_message = Message.assistant(content: "after compaction", id: "after")

    {:noreply, state} = turn_event(state, :message_delta, %{delta: before.content})
    {:noreply, state, render?: false} = turn_event(state, :message_end, %{message: before})
    {:noreply, state} = turn_event(state, :compaction_start, %{trigger: :pressure})
    card_id = card(state).id
    {:noreply, state} = turn_event(state, :compaction_end, %{status: :completed})
    {:noreply, state} = turn_event(state, :message_delta, %{delta: after_message.content})
    state = Viewport.refresh(state)

    assert Enum.map(Conversation.entries(state.conversation), & &1.kind) ==
             [:user, :assistant, :compaction, :assistant]

    agent_state = %{
      state.agent_state
      | messages: state.agent_state.messages ++ [before, after_message]
    }

    {:noreply, settled} =
      RuntimeEvents.handle(
        {:tackle_turn_finished, "session", "turn", {:ok, agent_state}},
        state
      )

    assert Enum.map(Conversation.entries(settled.conversation), & &1.content) ==
             ["hello", "before compaction", "Context compacted", "after compaction"]

    assert card(settled).id == card_id
  end

  test "automatic pressure, overflow retries, and failure remain visible outside the status row" do
    state = %{shell() | active_turn: %{id: "turn"}}
    {:noreply, running} = turn_event(state, :compaction_start, %{trigger: :pressure, pass: 1})
    assert card(running).content =~ "context pressure"

    {:noreply, retrying} = turn_event(running, :compaction_retry, %{trigger: :overflow})
    assert card(retrying).content =~ "context overflow"

    {:noreply, tightening} =
      turn_event(retrying, :compaction_start, %{trigger: :overflow, pass: 2})

    assert card(tightening).content =~ "pass 2"

    {:noreply, failed} =
      turn_event(tightening, :compaction_end, %{status: :failed, error: :timeout})

    assert card(failed).content == "Compaction failed: :timeout"

    {:noreply, settled} =
      RuntimeEvents.handle(
        {:tackle_turn_finished, "session", "turn", {:ok, state.agent_state}},
        failed
      )

    assert card(settled).content == "Compaction failed: :timeout"
  end

  test "cancelled compaction is not shown as success" do
    state = %{shell() | active_turn: %{id: "turn"}}
    {:noreply, cancelled} = turn_event(state, :compaction_end, %{status: :cancelled})
    assert card(cancelled).content == "Compaction cancelled"
  end

  test "manual errors retain the draft and render a failure card" do
    {:noreply, state, _} = Compaction.request(shell())

    {:noreply, failed} =
      RuntimeEvents.handle(
        {:tui_operation_result, state.pending_operation.ref, :compact,
         {:error, :nothing_to_compact}},
        state
      )

    assert card(failed).content =~ "Compaction failed"
    assert failed.pending_operation == nil
    assert Tackle.CLI.Widgets.Input.get_value(failed.input) == "draft"
  end

  test "resumed checkpoints expose their summary without inventing token counts" do
    state = shell()
    checkpoint = LibCompaction.checkpoint_message("checkpoint", "background summary")

    state =
      %{state | agent_state: %{state.agent_state | model_messages: [checkpoint]}}
      |> Compaction.restore()
      |> Viewport.refresh()

    assert card(state).content =~ "Restored context checkpoint"
    assert MessageView.source(card(state)) =~ "background summary"
  end

  test "a new completed pass never exposes the previous checkpoint as its summary" do
    state = shell()
    checkpoint = LibCompaction.checkpoint_message("old", "old summary")

    state = %{
      state
      | active_turn: %{id: "turn"},
        agent_state: %{state.agent_state | model_messages: [checkpoint]}
    }

    {:noreply, state} =
      turn_event(state, :compaction_end, %{status: :completed, compaction_id: "new"})

    refute MessageView.source(card(state)) =~ "old summary"
  end

  test "foreign events are ignored and reading anchors survive progress updates" do
    state = shell()
    messages = Enum.map(1..30, &Message.user("message #{&1}"))
    state = Viewport.refresh(%{state | agent_state: %{state.agent_state | messages: messages}})
    state = Viewport.scroll_to(state, :start)
    event = Event.new(:compaction_start, %{trigger: :manual})

    assert {:noreply, ^state, render?: false} =
             RuntimeEvents.handle({:tackle_compaction, "other", event}, state)

    {:noreply, running} = RuntimeEvents.handle({:tackle_compaction, "session", event}, state)
    assert running.conversation.anchor == state.conversation.anchor
    refute running.conversation.follow?
  end

  test "manual compaction hints do not promise cancellation" do
    state = %{shell() | pending_operation: %{kind: :compact}}
    refute StatusView.hints_widget(state, 80).text =~ "Esc cancel"
  end

  defp card(state),
    do:
      state.conversation
      |> Conversation.entries()
      |> Enum.filter(&(&1.kind == :compaction))
      |> List.last()

  defp turn_event(state, type, data),
    do: RuntimeEvents.handle({:tackle_event, "session", "turn", Event.new(type, data)}, state)

  defp record do
    %{
      compaction_id: "checkpoint",
      trigger: :manual,
      tokens_before: 1_200,
      estimated_tokens_after: 300,
      shadowed_message_ids: ["user"],
      summary_message: LibCompaction.checkpoint_message("checkpoint", "background summary")
    }
  end

  defp shell do
    input = Tackle.CLI.Widgets.Input.new()
    :ok = Tackle.CLI.Widgets.Input.set_value(input, "draft")

    Viewport.refresh(%State{
      session_id: "session",
      input: input,
      draft_empty?: false,
      agent_state: %AgentState{messages: [Message.user("hello", id: "user")]},
      conversation: Viewport.new_conversation(80, 24)
    })
  end
end
