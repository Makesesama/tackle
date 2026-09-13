defmodule Tackle.CLI.TUI.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.{Key, Paste, Resize}
  alias Tackle.CLI.{Keybinds, TUI}
  alias Tackle.CLI.TUI.{Diagnostics, Observations, RuntimeEvents, State, Viewport}
  alias Tackle.CLI.Widgets.Input
  alias Tackle.Lib.{Event, Message}
  alias Tackle.Lib.State, as: AgentState

  defp state do
    %State{
      session_id: "session",
      active_turn: %{id: "turn"},
      agent_state: AgentState.new(),
      input: Input.new(),
      conversation: Viewport.new_conversation(80, 24)
    }
    |> Viewport.refresh()
  end

  defp observe(state, event, session \\ "session", turn \\ "turn"),
    do: Observations.observe({:tackle_event, session, turn, event}, state)

  test "observations are bounded, ordered, correlated and payload-free" do
    event =
      Event.new(
        :tool_error,
        %{
          name: String.duplicate("x", 300),
          tool_call_id: "call",
          error: "secret",
          arguments: %{password: "secret"},
          result: "secret",
          raw: "secret",
          status: %{password: "secret"}
        },
        metadata: %{authorization: "secret"}
      )

    state = state()
    assert observe(state, event, "other").observations == state.observations
    assert observe(state, event, "session", "old").observations == state.observations

    state = Enum.reduce(1..503, state, fn _, state -> observe(state, event) end)
    assert length(state.observations.events) == 500
    assert state.observations.dropped == 3
    assert hd(state.observations.events).sequence == 503
    assert List.last(state.observations.events).sequence == 4
    assert hd(state.observations.events).elapsed_ms >= 0
    assert String.length(hd(state.observations.events).data.name) == 200
    assert hd(state.observations.events).data.status == :omitted
    refute inspect(state.observations, limit: :infinity) =~ "secret"

    state = observe(state, Event.new(:message_delta, %{delta: "private text"}))
    assert state.observations.deltas == 1
    assert length(state.observations.events) == 500
    refute Diagnostics.text(state, :events) =~ "private text"
  end

  test "runtime correlates an event that arrives before submit confirmation" do
    state = %{state() | active_turn: nil, pending_operation: %{kind: :submit}}
    event = Event.new(:retry_scheduled, %{attempt: 1, delay_ms: 2000, reason: "secret"})
    message = {:tackle_event, "session", "turn", event}

    {:noreply, projected} = RuntimeEvents.handle(message, state)
    assert projected.active_turn == %{id: "turn"}
    assert projected.deferred_events == []

    assert [%{type: :retry_scheduled, data: %{attempt: 1, delay_ms: 2000}}] =
             projected.observations.events

    refute Diagnostics.text(projected, :events) =~ "secret"

    {:noreply, settled} =
      RuntimeEvents.handle(
        {:tackle_turn_finished, "session", "turn", {:cancelled, projected.agent_state}},
        projected
      )

    assert settled.active_turn == nil
    assert [%{type: :turn_finished, data: %{status: :cancelled}}, _] = settled.observations.events
  end

  test "an early event installs and projects the submitted turn immediately" do
    ref = make_ref()

    pending = %{
      state()
      | active_turn: nil,
        pending_prompt: "go",
        stream: %{state().stream | coalesce?: false},
        pending_operation: %{ref: ref, kind: :submit, raw_draft: "go"}
    }

    event = {:tackle_event, "session", "turn", Event.new(:message_delta, %{delta: "done"})}
    assert {:noreply, live} = RuntimeEvents.handle(event, pending)
    assert live.active_turn == %{id: "turn"}
    assert live.pending_operation.kind == :submit
    assert live.stream.response == "done"
    assert Tackle.CLI.TUI.Conversation.text(live.conversation) =~ "done"

    assert {:noreply, confirmed, commands: []} =
             RuntimeEvents.handle({:tui_operation_result, ref, :submit, {:ok, "turn"}}, live)

    assert confirmed.active_turn == %{id: "turn"}
    assert confirmed.pending_operation == nil
    assert confirmed.stream.response == "done"
  end

  test "an early terminal outcome is not overwritten by submit completion" do
    ref = make_ref()

    agent = %{
      state().agent_state
      | messages: [Message.user("go"), Message.assistant(content: "done")]
    }

    pending = %{
      state()
      | active_turn: nil,
        pending_prompt: "go",
        pending_operation: %{ref: ref, kind: :submit, raw_draft: "go"}
    }

    finished = {:tackle_turn_finished, "session", "turn", {:ok, agent}}
    assert {:noreply, settled} = RuntimeEvents.handle(finished, pending)
    assert settled.active_turn == nil
    assert settled.pending_operation == nil
    assert settled.agent_state.messages == agent.messages

    assert {:noreply, unchanged, render?: false} =
             RuntimeEvents.handle(
               {:tui_operation_result, ref, :submit, {:ok, "turn"}},
               settled
             )

    assert unchanged == settled
  end

  test "failed turns and manual compaction are observed without retaining failure bodies" do
    state = state()

    {:noreply, failed} =
      RuntimeEvents.handle({:tackle_turn_failed, "session", "turn", :failure}, state)

    assert [%{type: :turn_failed}] = failed.observations.events
    assert failed.outcome == :failed

    compacted =
      Observations.observe({:tackle_compaction, "session", Event.new(:compaction_start)}, failed)

    assert [%{type: :compaction_start, turn_id: nil}, _] = compacted.observations.events
  end

  test "pages distinguish projections and exclude opaque state and raw usage" do
    transcript = Message.user("archived text")

    context =
      Message.assistant(
        content: "context summary",
        token_usage: %{input_tokens: 12, raw_secret: "secret"},
        provider_state: %{opaque: "secret"}
      )

    agent = %{
      AgentState.new(system_prompt: "composed instructions")
      | messages: [transcript],
        model_messages: [context],
        context: %{password: "secret"},
        llm_opts: [api_key: "secret"]
    }

    state = %{state() | agent_state: agent}

    assert Diagnostics.text(state, :prompt) =~ "composed instructions"
    assert Diagnostics.text(state, :context) =~ "context summary"
    refute Diagnostics.text(state, :context) =~ "archived text"
    assert Diagnostics.text(state, :context) =~ "input_tokens: 12"

    for page <- [:overview, :prompt, :context, :tools, :events] do
      refute Diagnostics.text(state, page) =~ "secret"
    end

    assert Diagnostics.text(%{state | agent_state: nil}, :overview) =~ "unavailable"
    assert Diagnostics.text(state, :events) =~ "No lifecycle events"
  end

  test "Browse pages work with an empty transcript and preserves draft, focus and resize" do
    state = state()
    :ok = Input.set_value(state.input, "draft")
    assert Keybinds.base(%Key{code: "f8"}, :composer) == :composer
    assert Keybinds.transcript(%Key{code: "d"}) == :ignore

    {:noreply, opened} = TUI.handle_event(%Key{code: "f4"}, state)
    assert opened.overlay == nil
    assert opened.focus == :transcript
    assert opened.browse_page == :overview
    {:noreply, prompt} = TUI.handle_event(%Key{code: "right"}, opened)
    assert prompt.overlay == nil
    assert prompt.browse_page == :prompt
    {:noreply, pasted} = TUI.handle_event(%Paste{content: "ignored"}, prompt)
    assert Input.get_value(pasted.input) == "draft"
    {:noreply, resized} = TUI.handle_event(%Resize{width: 30, height: 8}, pasted)
    assert resized.browse_page == :prompt
    assert resized.browse_content.height == resized.conversation.rect.height

    changed = %{resized | agent_state: %{resized.agent_state | system_prompt: "new prompt"}}
    {:noreply, refreshed} = TUI.handle_event(%Key{code: "r"}, changed)
    assert refreshed.overlay == nil
    assert refreshed.browse_content.text =~ "new prompt"
    test_pid = self()

    refreshed = %{
      refreshed
      | clipboard_writer: fn text ->
          send(test_pid, {:copied, text})
          :ok
        end
    }

    {:noreply, copied} = TUI.handle_event(%Key{code: "y"}, refreshed)
    assert_receive {:copied, text}
    assert text =~ "new prompt"
    {:noreply, closed} = TUI.handle_event(%Key{code: "esc"}, copied)
    assert closed.overlay == nil
    assert closed.focus == :composer
    assert Input.get_value(closed.input) == "draft"
  end

  test "native Browse pages stay frozen during events, scroll independently and reset on exit" do
    state = %{
      state()
      | agent_state: %{AgentState.new() | system_prompt: String.duplicate("line\n", 100)}
    }

    {:noreply, state} = TUI.handle_event(%Key{code: "f4"}, state)
    {:noreply, state} = TUI.handle_event(%Key{code: "tab"}, state)
    assert state.browse_page == :prompt
    native = state.browse_content.native
    transcript_offset = state.conversation.scroll_offset
    {:noreply, state} = TUI.handle_event(%Key{code: "end"}, state)
    assert state.browse_content.offset > 0
    assert state.conversation.scroll_offset == transcript_offset

    {:noreply, state} =
      RuntimeEvents.handle(
        {:tackle_event, "session", "turn", Event.new(:status_change, %{status: :thinking})},
        state
      )

    assert state.browse_content.native == native
    {:noreply, state} = TUI.handle_event(%Key{code: "tab", modifiers: ["shift"]}, state)
    assert state.browse_page == :overview
    {:noreply, state} = TUI.handle_event(%Key{code: "left"}, state)
    assert state.browse_page == :transcript
    {:noreply, state} = TUI.handle_event(%Key{code: "left"}, state)
    assert state.browse_page == :events
    {:noreply, state} = TUI.handle_event(%Key{code: "f4"}, state)
    assert state.focus == :composer
    assert state.browse_content == nil
  end

  test "session reset drops old observations" do
    state = observe(state(), Event.new(:turn_start))
    snapshot = %Tackle.Session.Snapshot{session_id: "replacement", agent_state: AgentState.new()}
    scope = %Tackle.Runtime.Scope{scope_ref: nil, root_agent_ref: nil}
    reset = State.reset(state, scope, snapshot, make_ref())
    assert reset.observations == %Observations{}
  end
end
