defmodule Tackle.CLI.SubagentViewTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias ExRatatui.Widgets.Clear
  alias Tackle.CLI.Keybinds

  alias Tackle.CLI.TUI.{
    Browser,
    Conversation,
    RuntimeEvents,
    State,
    SubagentTranscript,
    SubagentView,
    Subagents,
    View,
    Viewport
  }

  alias Tackle.CLI.Widgets.Input
  alias Tackle.Lib.{Event, Message}
  alias Tackle.Lib.State, as: AgentState

  describe "SubagentTranscript" do
    test "projects the child's prompt, reasoning, prose, and tools in order" do
      prompt = Message.user("Map the parser")
      call = %{id: "c1", name: "bash", arguments: %{"command" => "ls"}}

      assistant =
        Message.assistant(
          content: "Listing files",
          thinking: "Plan it",
          tool_calls: [call],
          id_generator: fn -> "a1" end
        )

      transcript =
        [
          Event.message_end(prompt),
          Event.new(:message_start, %{role: :assistant}, id: "a1"),
          Event.new(:message_delta, %{field: :reasoning, delta: "Plan"}, id: "a1"),
          Event.new(:message_delta, %{field: :content, delta: "Listing"}, id: "a1"),
          Event.message_end(assistant),
          Event.new(:tool_start, %{tool_call_id: "c1", name: "bash", arguments: call.arguments}),
          Event.new(:tool_progress, %{tool_call_id: "c1", name: "bash", delta: "lib\n"}),
          Event.new(:tool_end, %{tool_call_id: "c1", name: "bash", result: "lib\ntest\n"}),
          Event.message_end(Message.tool_result("c1", "bash", "lib\ntest\n"))
        ]
        |> Enum.reduce(nil, &SubagentTranscript.apply(&2, &1))

      assert [
               %{kind: :user, content: "Map the parser"},
               %{kind: :thinking, content: "Plan it"},
               %{kind: :assistant, content: "Listing files"},
               %{kind: :tool, id: "c1", name: "bash", status: :completed, result: "lib\ntest\n"}
             ] = transcript.timeline
    end

    test "requested calls appear before they run and cancellation freezes open tools" do
      call = %{id: "c1", name: "read", arguments: %{"path" => "a.ex"}}
      assistant = Message.assistant(tool_calls: [call], id_generator: fn -> "a1" end)

      requested = SubagentTranscript.apply(nil, Event.message_end(assistant))
      assert [%{kind: :tool, id: "c1", status: :requested}] = requested.timeline

      cancelled = SubagentTranscript.apply(requested, Event.new(:turn_cancelled, %{}))
      assert [%{status: :failed, error: "Interrupted"}] = cancelled.timeline
      assert SubagentTranscript.interrupt_open_tools(cancelled) === cancelled
    end

    test "tool failures and loop errors are kept; unknown events change nothing" do
      transcript =
        nil
        |> SubagentTranscript.apply(Event.new(:tool_start, %{tool_call_id: "c1", name: "bash"}))
        |> SubagentTranscript.apply(
          Event.new(:tool_error, %{tool_call_id: "c1", name: "bash", error: "exit 1"})
        )
        |> SubagentTranscript.apply(Event.new(:error, %{error: "provider down"}))

      assert [%{status: :failed, error: "exit 1"}] = transcript.timeline
      assert transcript.error == "provider down"
      assert SubagentTranscript.apply(transcript, Event.new(:usage, %{})) == transcript
      assert SubagentTranscript.apply(transcript, :not_an_event) == transcript
    end
  end

  test "calls without ids are ignored, late progress cannot reopen a card, and output is bounded" do
    huge = String.duplicate("é", 40_000)

    transcript =
      nil
      |> SubagentTranscript.apply(Event.new(:tool_start, %{name: "bash"}))
      |> SubagentTranscript.apply(Event.new(:tool_progress, %{name: "bash", delta: "x"}))

    assert transcript.timeline == []

    transcript =
      transcript
      |> SubagentTranscript.apply(Event.new(:tool_start, %{tool_call_id: "c1", name: "read"}))
      |> SubagentTranscript.apply(
        Event.new(:tool_execution_end, %{
          tool_call_id: "c1",
          name: "read",
          status: :completed,
          result: huge
        })
      )
      |> SubagentTranscript.apply(
        Event.new(:tool_progress, %{tool_call_id: "c1", name: "read", delta: "late"})
      )
      |> SubagentTranscript.apply(Event.message_end(Message.tool_result("c1", "read", "again")))

    assert [%{status: :completed, result: result}] = transcript.timeline
    assert String.valid?(result)
    assert byte_size(result) < byte_size(huge)
    assert result =~ "more bytes not kept by the subagent view"
    refute result =~ "late"
  end

  describe "subagent view" do
    test "the task sidebar opens the full child conversation and follows it live" do
      state = running_child()
      {:noreply, state} = Subagents.focus(state)
      {:noreply, state} = Subagents.handle(:inspect, state)

      assert {:subagent_view, %{run_id: "run-one"}} = state.overlay
      assert texts(state) == ["Inspect the parser", "Looking at files"]

      state =
        progress(
          state,
          Event.new(:tool_start, %{
            tool_call_id: "child-bash",
            name: "bash",
            arguments: %{"command" => "mix compile"}
          })
        )

      kinds = state |> view_entries() |> Enum.map(&{&1.kind, &1.tool_name})
      assert kinds == [{:user, nil}, {:assistant, nil}, {:tool, "bash"}]

      [screen | _] = SubagentView.widgets(state)
      assert {%Clear{}, %{x: 0, y: 0, width: 80, height: 24}} = screen

      terminal = ExRatatui.init_test_terminal(80, 24)
      :ok = ExRatatui.draw(terminal, View.scene(state, nil))
      painted = ExRatatui.get_buffer_content(terminal)
      assert painted =~ "Subagent · scout · test/scout · running"
      assert painted =~ "Inspect the parser"
      assert painted =~ "Looking at files"
      assert painted =~ "mix compile"
      assert painted =~ "Esc back"
      refute painted =~ "What would you like to build?"

      {:noreply, closed} = SubagentView.handle(:close, state)
      assert closed.overlay == nil
    end

    test "Enter on a subagent card in the transcript opens its conversation" do
      state = running_child()
      {:noreply, browsing} = Browser.toggle_focus(state)
      browsing = %{browsing | selected_entry: "tool:one"}

      {:noreply, opened} = Browser.handle(:inspect, browsing)
      assert {:subagent_view, %{run_id: "run-one"}} = opened.overlay
    end

    test "a subagent card without observed history falls back to the inspector" do
      state = start(shell(), "one", "Inspect the parser")
      {:noreply, browsing} = Browser.toggle_focus(state)
      browsing = %{browsing | selected_entry: "tool:one"}

      {:noreply, inspected} = Browser.handle(:inspect, browsing)
      assert {:inspector, %{entry: %{id: "tool:one"}}} = inspected.overlay
    end

    test "the assignment is shown before the child's first message arrives" do
      state =
        shell()
        |> start("one", "Survey the tests")
        |> event(:subagent_started, %{
          tool_call_id: "one",
          run_id: "run-one",
          profile: "scout",
          model: "test/scout",
          status: :running
        })

      {:noreply, state} = SubagentView.open(state, "run-one")
      assert texts(state) == ["Survey the tests"]
    end

    test "scrolling, reasoning, browsing runs, and copying stay inside the view" do
      long = Enum.map_join(1..60, "\n\n", &"paragraph #{&1}")
      state = running_child() |> progress(Event.new(:message_delta, %{delta: long}))

      state =
        progress(
          state,
          Event.new(:message_delta, %{field: :reasoning, delta: "secret plan"}, id: "m2")
        )

      {:noreply, state} = SubagentView.open(state, "run-one")
      {:subagent_view, view} = state.overlay
      assert view.conversation.follow?

      {:noreply, scrolled} = SubagentView.handle({:scroll, "home"}, state)
      {:subagent_view, scrolled_view} = scrolled.overlay
      assert scrolled_view.conversation.scroll_offset == 0
      refute scrolled_view.conversation.follow?

      assert {:noreply, ^scrolled, render?: false} =
               SubagentView.handle({:scroll, "up"}, scrolled)

      {:noreply, expanded} = SubagentView.handle(:toggle_thinking, scrolled)
      {:subagent_view, expanded_view} = expanded.overlay
      assert expanded_view.thinking_expanded?
      refute expanded.thinking_expanded?

      thinking = Enum.find(view_entries(expanded), &(&1.kind == :thinking))
      refute thinking.collapsed?

      other =
        expanded
        |> event(:subagent_started, %{tool_call_id: "two", run_id: "run-two", status: :running})
        |> put_in([Access.key!(:subagents), "run-two", :started_at_ms], 9_999_999_999_999)

      {:noreply, next} = SubagentView.handle({:adjacent, "right"}, other)
      assert {:subagent_view, %{run_id: "run-two"}} = next.overlay
      {:noreply, back} = SubagentView.handle({:adjacent, "left"}, next)
      assert {:subagent_view, %{run_id: "run-one"}} = back.overlay

      copied = %{
        back
        | clipboard_writer: fn text ->
            send(self(), {:copied, text})
            {:ok, :confirmed}
          end
      }

      {:noreply, copied} = SubagentView.handle(:copy_transcript, copied)
      assert_received {:copied, text}
      assert text =~ "Inspect the parser"
      assert {:subagent_view, %{notice: "Copied subagent transcript"}} = copied.overlay
    end

    test "a child that ends abnormally shows its outcome and no running tools" do
      state =
        running_child()
        |> progress(Event.new(:tool_start, %{tool_call_id: "child-bash", name: "bash"}))
        |> event(:subagent_finished, %{run_id: "run-one", status: :timeout})

      {:noreply, state} = SubagentView.open(state, "run-one")
      entries = view_entries(state)
      assert %{kind: :tool, tool_status: :failed} = Enum.find(entries, &(&1.kind == :tool))
      assert %{kind: :error, content: "Subagent timed out"} = List.last(entries)
    end

    test "progress that arrives before subagent_started still resolves the card" do
      state =
        shell()
        |> start("one", "Inspect the parser")
        |> progress(Event.new(:message_delta, %{delta: "early"}))

      assert SubagentView.run_for_task(state, %{id: "one", run_id: nil}) == "run-one"

      {:noreply, browsing} = Browser.toggle_focus(state)
      {:noreply, opened} = Browser.handle(:inspect, %{browsing | selected_entry: "tool:one"})
      assert {:subagent_view, %{run_id: "run-one"}} = opened.overlay
      assert texts(opened) == ["Inspect the parser", "early"]
    end

    test "coalesced streaming catches the open view up on the frame flush" do
      state = running_child()
      {:noreply, state} = SubagentView.open(state, "run-one")
      state = %{state | stream: %{state.stream | coalesce?: true}}

      {:noreply, deferred, opts} =
        RuntimeEvents.handle(
          {:tackle_event, "session", "turn",
           Event.new(:subagent_progress, %{
             run_id: "run-one",
             event: Event.new(:message_delta, %{delta: " and more"})
           })},
          state
        )

      assert opts[:render?] == false
      assert texts(deferred) == ["Inspect the parser", "Looking at files"]

      {:noreply, flushed} =
        RuntimeEvents.handle({:tui_flush_stream, deferred.stream.flush_ref}, deferred)

      assert texts(flushed) == ["Inspect the parser", "Looking at files and more"]
    end

    test "copy notices clear on the next movement and one run cannot step away" do
      state = running_child()
      {:noreply, state} = SubagentView.open(state, "run-one")

      assert {:noreply, ^state, render?: false} = SubagentView.handle({:adjacent, "right"}, state)

      state = %{state | clipboard_writer: fn _text -> {:ok, :confirmed} end}
      {:noreply, copied} = SubagentView.handle(:copy_transcript, state)
      assert {:subagent_view, %{notice: "Copied subagent transcript"}} = copied.overlay

      moved = SubagentView.scroll(copied, -1)
      assert {:subagent_view, %{notice: nil}} = moved.overlay
    end

    test "resizing re-measures the view to the new screen" do
      {:noreply, state} = SubagentView.open(running_child(), "run-one")
      resized = SubagentView.resize(%{state | size: {100, 30}})
      {:subagent_view, view} = resized.overlay
      assert view.conversation.rect == %ExRatatui.Layout.Rect{x: 1, y: 1, width: 98, height: 28}
    end

    test "keys resolve to view intents" do
      assert Keybinds.subagent_view(%Key{code: "esc"}) == :close
      assert Keybinds.subagent_view(%Key{code: "q"}) == :close
      assert Keybinds.subagent_view(%Key{code: "page_down"}) == {:scroll, "page_down"}
      assert Keybinds.subagent_view(%Key{code: "left"}) == {:adjacent, "left"}
      assert Keybinds.subagent_view(%Key{code: "t", modifiers: ["ctrl"]}) == :toggle_thinking
      assert Keybinds.subagent_view(%Key{code: "y"}) == :copy_transcript
      assert Keybinds.subagent_view(%Key{code: "x"}) == :ignore
    end
  end

  defp running_child do
    shell()
    |> start("one", "Inspect the parser")
    |> event(:subagent_started, %{
      tool_call_id: "one",
      run_id: "run-one",
      profile: "scout",
      model: "test/scout",
      status: :running
    })
    |> progress(Event.message_end(Message.user("Inspect the parser")))
    |> progress(Event.new(:message_delta, %{field: :content, delta: "Looking at files"}))
  end

  defp texts(state), do: state |> view_entries() |> Enum.map(& &1.content)

  defp view_entries(%State{overlay: {:subagent_view, view}}),
    do: Conversation.entries(view.conversation)

  defp progress(state, child_event) do
    event(state, :subagent_progress, %{run_id: "run-one", tool_call_id: "one", event: child_event})
  end

  defp start(state, id, prompt),
    do:
      event(state, :tool_start, %{
        tool_call_id: id,
        name: "subagent",
        arguments: %{"profile" => "scout", "prompt" => prompt}
      })

  defp event(state, type, data) do
    case RuntimeEvents.handle({:tackle_event, "session", "turn", Event.new(type, data)}, state) do
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
