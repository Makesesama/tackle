defmodule Tackle.CLI.TUITest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}
  alias ExRatatui.Runtime
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Widgets.List, as: SelectionList
  alias ExRatatui.Widgets.{Markdown, Paragraph, Popup, TextInput, WidgetList}
  alias Tackle.CLI.TUI
  alias Tackle.CLI.TUI.{Conversation, Layout, MessageView, Picker, RuntimeEvents, Theme}
  alias Tackle.Lib.Compaction, as: LibCompaction
  alias Tackle.Lib.{Event, LLM, Message, State}
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.ID
  alias Tackle.Runtime.Scope
  alias Tackle.Session.Snapshot

  defmodule SessionStub do
    use GenServer

    defmodule Adapter do
      @behaviour Tackle.Lib.LLM

      @impl true
      def adapter_id, do: "openai-codex"

      @impl true
      def models, do: ["test-model", "other-model"]

      @impl true
      def model_info("test-model"), do: %{context_window: 1_000, max_output_tokens: 200}
      def model_info("other-model"), do: %{context_window: 2_000, max_output_tokens: 400}

      @impl true
      def generate(_schema, _opts), do: {:error, :not_used}
    end

    def start_link({test_pid, agent_ref}),
      do: GenServer.start_link(__MODULE__, {test_pid, agent_ref})

    def child_spec({test_pid, agent_ref}) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [{test_pid, agent_ref}]},
        restart: :temporary
      }
    end

    @impl true
    def init({test_pid, agent_ref}) do
      {:ok, _pid} = Tackle.Runtime.Registry.register(agent_ref, :agent)
      {:ok, llm} = LLM.select([Adapter], "openai-codex/test-model")
      agent_state = State.new(llm: llm)
      {:ok, %{test_pid: test_pid, subscriber: nil, agent_state: agent_state}}
    end

    @impl true
    def handle_call(:subscribe, {subscriber, _tag}, state) do
      send(state.test_pid, {:subscribed, subscriber})

      snapshot = %Snapshot{
        session_id: state.agent_state.session_id,
        agent_state: state.agent_state,
        active_turn: nil
      }

      {:reply, {:ok, snapshot}, %{state | subscriber: subscriber}}
    end

    def handle_call({:submit, prompt}, _from, state) do
      send(state.test_pid, {:submitted, prompt})

      if String.starts_with?(prompt, "fail") do
        {:reply, {:error, :rejected}, state}
      else
        {:reply, {:ok, "turn-1"}, state}
      end
    end

    def handle_call(:cancel, _from, state) do
      send(state.test_pid, :cancelled)
      {:reply, :ok, state}
    end

    def handle_call({:compact, _opts}, _from, state) do
      send(state.test_pid, :compact_requested)

      checkpoint = LibCompaction.checkpoint_message("ckpt-1", "compacted background")

      agent_state = %{
        state.agent_state
        | model_messages: [checkpoint | state.agent_state.messages]
      }

      snapshot = %Snapshot{
        session_id: agent_state.session_id,
        agent_state: agent_state,
        active_turn: nil
      }

      record = %Tackle.Lib.Compaction.Record{
        compaction_id: "ckpt-1",
        trigger: :manual,
        summary_message: checkpoint,
        shadowed_message_ids: ["u1"],
        first_retained_message_id: nil,
        tokens_before: 1_200,
        estimated_tokens_after: 300,
        created_at: "2026-01-01T00:00:00Z"
      }

      {:reply, {:ok, snapshot, record}, %{state | agent_state: agent_state}}
    end

    def handle_call({:reconfigure, opts}, _from, state) do
      send(state.test_pid, {:reconfigured, opts})
      model = Keyword.get(opts, :model, state.agent_state.llm.ref)
      {:ok, llm} = LLM.select([Adapter], model)

      llm_opts =
        case Keyword.fetch(opts, :thinking) do
          {:ok, level} ->
            {:ok, updated} = Tackle.Thinking.put_llm_opts(state.agent_state.llm_opts, level)
            updated

          :error ->
            state.agent_state.llm_opts
        end

      agent_state = %{state.agent_state | llm: llm, model: llm.model, llm_opts: llm_opts}

      snapshot = %Snapshot{
        session_id: agent_state.session_id,
        agent_state: agent_state,
        active_turn: nil
      }

      if state.subscriber do
        send(state.subscriber, {:tackle_session_reconfigured, snapshot.session_id, snapshot})
      end

      {:reply, {:ok, snapshot}, %{state | agent_state: agent_state}}
    end

    def handle_call(:unsubscribe, {subscriber, _tag}, %{subscriber: subscriber} = state) do
      {:reply, :ok, %{state | subscriber: nil}}
    end

    def handle_call(:unsubscribe, _from, state), do: {:reply, :ok, state}
  end

  setup do
    test_pid = self()
    agent_ref = AgentRef.new!(ID.generate(), ID.generate())
    _session = start_supervised!({SessionStub, {test_pid, agent_ref}})

    tui =
      start_supervised!(
        {TUI,
         agent_ref: agent_ref,
         models: ["openai-codex/test-model", "openai-codex/other-model"],
         clipboard_writer: fn content ->
           send(test_pid, {:copied, content})
           :ok
         end,
         name: nil,
         test_mode: {80, 24}}
      )

    assert_receive {:subscribed, ^tui}
    %{agent_ref: agent_ref, tui: tui}
  end

  # -- layout --------------------------------------------------------------

  describe "responsive layout" do
    test "normal terminals keep header, transcript, status, composer, and hints" do
      regions = Layout.regions(80, 24, 1, false)

      assert regions.header.height == 1
      assert regions.transcript.height > 0
      assert regions.status
      assert regions.hints
      assert regions.reading == nil
      assert regions.composer.height == 3

      assert_regions_within_bounds(regions, 80, 24)
    end

    test "the reading row takes priority and the composer grows by logical lines" do
      one_line = Layout.regions(80, 24, 1, false)
      three_lines = Layout.regions(80, 24, 3, false)
      reading = Layout.regions(80, 24, 1, true)

      assert three_lines.composer.height == 5
      assert three_lines.transcript.height == one_line.transcript.height - 2

      assert reading.reading
      assert reading.transcript.height == one_line.transcript.height - 1
      assert_regions_within_bounds(reading, 80, 24)
    end

    test "composer growth is capped at eight logical lines" do
      assert Layout.composer_lines(40, 1) == 1
      assert Layout.composer_lines(40, 4) == 4
      assert Layout.composer_lines(40, 40) == 8

      regions = Layout.regions(40, 40, 40, false)
      assert regions.composer.height == 10
      assert_regions_within_bounds(regions, 40, 40)
    end

    test "narrow and tiny terminals drop optional rows without leaving the frame" do
      narrow = Layout.regions(30, 8, 1, false)
      assert narrow.transcript.height >= 1
      assert_regions_within_bounds(narrow, 30, 8)

      tiny = Layout.regions(20, 5, 1, false)
      assert tiny.transcript.height == 1
      assert tiny.reading == nil
      assert tiny.status == nil
      assert tiny.hints == nil
      assert_regions_within_bounds(tiny, 20, 5)

      smaller = Layout.regions(10, 2, 1, false)
      assert_regions_within_bounds(smaller, 10, 2)
    end

    test "renders and draws without crashing at tiny sizes", %{tui: tui} do
      inject_resize(tui, 20, 5)
      state = state(tui)

      terminal = ExRatatui.init_test_terminal(20, 5)
      :ok = ExRatatui.draw(terminal, TUI.scene(state, frame(state)))
      assert is_binary(ExRatatui.get_buffer_content(terminal))

      inject_resize(tui, 30, 8)
      state = state(tui)
      terminal = ExRatatui.init_test_terminal(30, 8)
      :ok = ExRatatui.draw(terminal, TUI.scene(state, frame(state)))
      assert is_binary(ExRatatui.get_buffer_content(terminal))
    end

    test "draws every menu and the browser at a small size", %{tui: tui} do
      _state =
        settle_messages(tui, [Message.user("question"), Message.assistant(content: "answer")])

      inject_resize(tui, 30, 8)

      Enum.each([{"f1", "Model"}, {"f2", "Reasoning level"}, {"f3", "Settings"}], fn {key, title} ->
        inject_key(tui, key)
        assert_draws(state(tui), 30, 8, title)
        inject_key(tui, "esc")
      end)

      inject_key(tui, "f4")
      browse = state(tui)
      assert browse.focus == :transcript
      assert_draws(browse, 30, 8, "Browsing")

      inject_key(tui, "enter")
      assert_draws(state(tui), 30, 8)
    end
  end

  # -- shell ---------------------------------------------------------------

  test "runs as an ExRatatui.App with session and multiline composer state", %{tui: tui} do
    state = state(tui)

    assert state.agent_state.model == "test-model"
    assert state.agent_state.llm.ref == "openai-codex/test-model"
    assert is_reference(state.input)
    assert Tackle.CLI.Widgets.Input.get_value(state.input) == ""
    assert state.draft_lines == 1
    assert state.draft_empty?
    assert function_exported?(TUI, :start_link, 1)
  end

  test "renders compact header, border-light transcript, composer, status, and hints", %{tui: tui} do
    state = state(tui)

    assert header_text(state) =~ "openai-codex/test-model"
    assert header_text(state) =~ "thinking off"
    assert header_text(state) =~ "ready"

    assert %WidgetList{} = transcript_widget(state)
    assert conversation_text(state) =~ "Welcome to Tackle"

    assert %Tackle.CLI.Widgets.Input{block: %{title: " Prompt "}} = composer_widget(state)
    assert status_text(state) =~ "ready"
    assert status_text(state) =~ "ctx 0/1k (0.0%)"
    assert hints_text(state) =~ "Enter send"
    assert hints_text(state) =~ "Ctrl+C quit"
    refute status_text(state) =~ "CH"
  end

  test "submits the trimmed draft on Enter and clears the composer", %{tui: tui} do
    inject_paste(tui, "  hi  ")
    inject_key(tui, "enter")

    assert_receive {:submitted, "hi"}
    state = await_state(tui, &is_nil(&1.pending_operation))

    assert state.active_turn == %{id: "turn-1"}
    assert state.pending_prompt == "hi"
    assert draft(tui) == ""
    assert state.draft_lines == 1
  end

  test "keeps the exact multiline draft when submission fails", %{tui: tui} do
    inject_paste(tui, "fail\nsecond line")
    inject_key(tui, "enter")

    assert_receive {:submitted, "fail\nsecond line"}
    state = await_state(tui, &is_nil(&1.pending_operation))

    assert state.active_turn == nil
    assert draft(tui) == "fail\nsecond line"
    assert status_text(state) =~ "failed"
    assert state.error =~ "rejected"
  end

  # -- composer input ------------------------------------------------------

  test "bracketed paste is one edit, never submits, and normalizes line endings", %{tui: tui} do
    inject_paste(tui, "a\r\nb\rc")
    state = state(tui)

    assert draft(tui) == "a\nbc"
    assert state.draft_lines == 2
    assert state.active_turn == nil
    assert regions(state).composer.height == 4
    refute_receive {:submitted, _}, 50
  end

  test "Ctrl+U undoes and Ctrl+R redoes a full multiline paste", %{tui: tui} do
    inject_paste(tui, "one\ntwo\nthree")
    assert draft(tui) == "one\ntwo\nthree"

    inject_key(tui, "u", ["ctrl"])
    assert draft(tui) == ""
    assert state(tui).draft_lines == 1

    inject_key(tui, "r", ["ctrl"])
    assert draft(tui) == "one\ntwo\nthree"
    assert state(tui).draft_lines == 3
  end

  test "handles modified Enter, Ctrl+J, unknown Alt chords, repeats, and releases", %{tui: tui} do
    inject_key(tui, "enter", ["shift"])
    inject_key(tui, "j", ["ctrl"])
    assert draft(tui) == "\n\n"

    inject_key(tui, "g", ["alt"])
    assert draft(tui) == "\n\n"

    inject_key(tui, "a")
    inject_key(tui, "a", [], "repeat")
    assert draft(tui) == "\n\naa"

    inject_key(tui, "x", [], "release")
    assert draft(tui) == "\n\naa"

    inject_key(tui, "c", ["ctrl"], "release")
    assert Process.alive?(tui)
    assert draft(tui) == "\n\naa"
  end

  test "resize alone rewraps and redraws the composer without editing the draft", %{tui: tui} do
    source = String.duplicate("x", 60)
    inject_paste(tui, source)
    assert state(tui).draft_lines == 1
    before_resize = Runtime.snapshot(tui).render_count

    inject_resize(tui, 22, 24)
    narrow = state(tui)
    assert narrow.draft_lines == 4
    assert regions(narrow).composer.height == 6
    assert Runtime.snapshot(tui).render_count > before_resize
    assert draft(tui) == source

    terminal = ExRatatui.init_test_terminal(22, 24)
    :ok = ExRatatui.draw(terminal, TUI.scene(narrow, frame(narrow)))
    assert ExRatatui.get_buffer_content(terminal) =~ String.duplicate("x", 20)

    inject_resize(tui, 80, 24)
    wide = state(tui)
    assert wide.draft_lines == 1
    assert regions(wide).composer.height == 3
    assert draft(tui) == source

    # Resizing is not an edit and must not add an undo entry.
    inject_key(tui, "u", ["ctrl"])
    assert draft(tui) == ""
  end

  test "growing the draft shrinks the transcript instead of the composer", %{tui: tui} do
    state = state(tui)
    initial = regions(state)

    inject_paste(tui, Enum.map_join(1..12, "\n", &"line #{&1}"))
    grown = state(tui)

    assert grown.draft_lines == 12
    assert regions(grown).composer.height == 10
    assert regions(grown).transcript.height == initial.transcript.height - 7
    assert_regions_within_bounds(regions(grown), 80, 24)
  end

  test "keeps drafting while busy without queuing or submitting", %{tui: tui} do
    inject_paste(tui, "first")
    inject_key(tui, "enter")
    assert_receive {:submitted, "first"}

    inject_paste(tui, "second draft")
    inject_key(tui, "enter")

    refute_receive {:submitted, _}, 100
    state = state(tui)

    assert draft(tui) == "second draft"
    assert state.active_turn != nil
    assert status_text(state) =~ "not queued"
    assert composer_widget(state).block.title =~ "not queued"
  end

  # -- settings ------------------------------------------------------------

  test "F1 picks a model from a searchable menu", %{tui: tui} do
    inject_paste(tui, "keep this draft")
    inject_key(tui, "f1")
    state = state(tui)
    assert {:picker, %{kind: :model, picker: picker}} = state.overlay
    assert picker.query == ""
    assert status_text(state) =~ "Menu"

    assert %SelectionList{items: items, selected: 0} = popup_content(state)
    assert Enum.at(items, 0) =~ "✓"
    assert Enum.at(items, 0) =~ "test-model  [openai-codex]"
    assert popup_title(state) =~ "Model"

    inject_key(tui, "down")
    inject_key(tui, "enter")

    assert_receive {:reconfigured, [model: "openai-codex/other-model"]}

    state = state(tui)
    assert state.overlay == nil
    assert state.agent_state.model == "other-model"
    assert header_text(state) =~ "openai-codex/other-model"
    assert status_text(state) =~ "ctx 0/2k (0.0%)"
    assert draft(tui) == "keep this draft"
  end

  test "the model menu ranks a provider-qualified query above a proxy id", %{tui: tui} do
    inject_key(tui, "f1")

    Enum.each(["o", "t", "h", "e", "r"], &inject_key(tui, &1))
    state = state(tui)

    assert {:picker, %{picker: picker}} = state.overlay
    assert picker.query == "other"

    assert %SelectionList{items: ["   other-model  [openai-codex]"], selected: 0} =
             popup_content(state)

    inject_key(tui, "backspace")
    assert {:picker, %{picker: %{query: "othe"}}} = state(tui).overlay

    inject_key(tui, "esc")
    assert state(tui).overlay == nil
  end

  test "F2 picks the reasoning level from a searchable menu", %{tui: tui} do
    inject_key(tui, "f2")
    state = state(tui)

    assert {:picker, %{kind: :thinking}} = state.overlay
    assert popup_title(state) =~ "Reasoning level"

    assert %SelectionList{items: items} = popup_content(state)
    assert hd(items) =~ "off"
    assert hd(items) =~ "No reasoning"

    Enum.each(["m", "i", "n", "i", "m", "a", "l"], &inject_key(tui, &1))
    assert {:picker, %{picker: %{query: "minimal"}}} = state(tui).overlay

    inject_key(tui, "enter")
    assert_receive {:reconfigured, [thinking: "minimal"]}

    state = state(tui)
    assert state.overlay == nil
    assert Tackle.Thinking.from_llm_opts(state.agent_state.llm_opts) == "minimal"
    assert header_text(state) =~ "thinking minimal"
  end

  test "F3 opens the settings menu, which is empty until there is something to configure", %{
    tui: tui
  } do
    inject_key(tui, "f3")
    state = state(tui)

    assert {:picker, %{kind: :settings, picker: %Picker{items: []}}} = state.overlay
    assert popup_title(state) =~ "Settings"
    assert %Paragraph{text: text} = popup_content(state)
    assert text =~ "No settings yet"

    # With no rows there is nothing to apply, so Enter is inert and Esc closes.
    inject_key(tui, "enter")
    assert {:picker, %{kind: :settings}} = state(tui).overlay

    inject_key(tui, "esc")
    assert state(tui).overlay == nil
  end

  test "configuration menus are idle only", %{tui: tui} do
    inject_paste(tui, "work")
    inject_key(tui, "enter")
    assert_receive {:submitted, "work"}

    Enum.each(["f1", "f2", "f3"], fn key ->
      inject_key(tui, key)
      state = state(tui)

      assert state.overlay == nil
      assert state.notice =~ "when idle"
    end)

    refute_receive {:reconfigured, _}, 50
  end

  # -- compaction ------------------------------------------------------------

  test "Ctrl+K compacts when idle and reports the projection shrink", %{tui: tui} do
    inject_key(tui, "k", ["ctrl"])
    assert_receive :compact_requested

    state =
      await_state(tui, &(&1.pending_operation == nil and &1.agent_state.model_messages != nil))

    assert state.notice == nil
    assert conversation_text(state) =~ "Context compacted · 1.2k → 300 est. tokens"
    refute status_text(state) =~ "est. tokens"
    assert status_text(state) =~ "compacted"
  end

  test "compaction is idle only and never runs during a turn", %{tui: tui} do
    inject_paste(tui, "work")
    inject_key(tui, "enter")
    assert_receive {:submitted, "work"}

    _state = await_state(tui, &(&1.active_turn != nil))
    inject_key(tui, "k", ["ctrl"])

    state = state(tui)
    assert state.notice =~ "when idle"
    assert state.pending_operation == nil
    refute_receive :compact_requested, 50
  end

  test "a rejected compaction is reported in the error row", %{tui: tui} do
    state = state(tui)
    ref = make_ref()

    state = %{state | pending_operation: %{ref: ref, kind: :compact}, activity: "compacting"}

    assert {:noreply, failed} =
             RuntimeEvents.handle(
               {:tui_operation_result, ref, :compact, {:error, :turn_in_progress}},
               state
             )

    assert failed.pending_operation == nil
    assert failed.activity == nil
    assert failed.error =~ "turn_in_progress"
  end

  # -- metrics -------------------------------------------------------------

  test "shows preceding-prompt cache reuse and cumulative cost in status", %{tui: tui} do
    inject_paste(tui, "go")
    inject_key(tui, "enter")
    assert_receive {:submitted, "go"}

    state = state(tui)

    first_usage = %{
      input_tokens: 100,
      output_tokens: 10,
      cache_read_tokens: 0,
      cost: 0.16,
      cost_estimated: true,
      currency: "USD"
    }

    second_usage = %{
      input_tokens: 100,
      output_tokens: 10,
      cache_read_tokens: 100,
      cost: 0.84,
      cost_estimated: true,
      currency: "USD"
    }

    send(tui, {:tackle_event, state.session_id, "turn-1", Event.usage(first_usage)})
    send(tui, {:tackle_event, state.session_id, "turn-1", Event.usage(second_usage)})

    live_state = state(tui)
    live_status = status_text(live_state)
    assert live_status =~ "ctx 210/1k (21.0%)"
    assert live_status =~ "in 200"
    assert live_status =~ "out 20"
    assert live_status =~ "CH100.0%"
    assert live_status =~ "~$1.00"

    agent_state = %{
      live_state.agent_state
      | messages: [
          Message.assistant(content: "tool call", token_usage: first_usage),
          Message.assistant(content: "done", token_usage: second_usage)
        ],
        status: :completed
    }

    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {:ok, agent_state}})
    settled_status = status_text(state(tui))

    assert settled_status =~ "ctx 210/1k (21.0%)"
    assert settled_status =~ "in 200"
    assert settled_status =~ "out 20"
    assert settled_status =~ "CH100.0%"
    assert settled_status =~ "~$1.00"
  end

  test "omits context and token statistics when they are unavailable", %{tui: tui} do
    state = state(tui)
    llm = %{state.agent_state.llm | model_info: nil}

    state = %{
      state
      | agent_state: %{state.agent_state | llm: llm},
        metrics: %{state.metrics | latest_usage: nil}
    }

    status = status_text(state)

    refute status =~ "ctx "
    refute status =~ "in "
    refute status =~ "out "
    refute status =~ "$"
  end

  test "drops optional metrics before the working status at narrow widths", %{tui: tui} do
    inject_resize(tui, 22, 12)
    state = state(tui)

    assert status_text(state) =~ "ready"
    refute status_text(state) =~ "ctx "
  end

  # -- streaming and transcript -------------------------------------------

  test "projects streaming text and settles the completed conversation", %{tui: tui} do
    inject_paste(tui, "hi")
    inject_key(tui, "enter")
    assert_receive {:submitted, "hi"}

    session_id = state(tui).session_id
    thinking_event = Event.new(:message_delta, %{field: :reasoning, delta: "Checking"})
    send(tui, {:tackle_event, session_id, "turn-1", thinking_event})

    event = Event.new(:message_delta, %{delta: "Hello"})
    send(tui, {:tackle_event, session_id, "turn-1", event})

    streaming_state = state(tui)
    assert streaming_state.stream.thinking == "Checking"
    assert streaming_state.stream.response == "Hello"
    assert conversation_text(streaming_state) =~ "thought"
    assert conversation_text(streaming_state) =~ "Checking"

    agent_state = %{
      streaming_state.agent_state
      | messages: [
          Message.user("hi"),
          Message.assistant(thinking: "Checked", content: "Hello")
        ],
        status: :completed
    }

    send(tui, {:tackle_turn_finished, session_id, "turn-1", {:ok, agent_state}})
    settled_state = state(tui)

    assert settled_state.active_turn == nil
    assert settled_state.pending_prompt == nil
    assert settled_state.stream.thinking == ""
    assert settled_state.stream.response == ""

    conversation = conversation_text(settled_state)

    assert conversation =~ "› hi"
    assert conversation =~ "hi"
    assert conversation =~ "thought"
    assert conversation =~ "Checked"
    assert conversation =~ "Hello"

    assert Enum.any?(transcript_widget(settled_state).items, fn
             {%Markdown{content: "Hello"}, height} ->
               height == Markdown.measure_height("Hello", settled_state.conversation.width)

             _item ->
               false
           end)
  end

  test "keeps streamed message boundaries and reconciles canonical content", %{tui: tui} do
    inject_paste(tui, "hi")
    inject_key(tui, "enter")
    assert_receive {:submitted, "hi"}

    session_id = state(tui).session_id

    first =
      Message.assistant(
        id: "assistant-1",
        content: "First canonical preamble.",
        thinking: "First canonical thought.",
        tool_calls: [%{id: "call-1", name: "read", arguments: %{}}]
      )

    send(tui, {:tackle_event, session_id, "turn-1", Event.message_start(id: first.id)})

    send(
      tui,
      {:tackle_event, session_id, "turn-1",
       Event.new(
         :message_delta,
         %{field: :reasoning, delta: "First streamed thought."},
         id: first.id
       )}
    )

    send(
      tui,
      {:tackle_event, session_id, "turn-1",
       Event.new(:message_delta, %{delta: "First streamed preamble."}, id: first.id)}
    )

    send(tui, {:tackle_event, session_id, "turn-1", Event.message_end(first)})

    second = Message.assistant(id: "assistant-2", content: "Second canonical preamble.")
    send(tui, {:tackle_event, session_id, "turn-1", Event.message_start(id: second.id)})

    send(
      tui,
      {:tackle_event, session_id, "turn-1",
       Event.new(:message_delta, %{delta: "Second streamed preamble."}, id: second.id)}
    )

    streaming_state = state(tui)

    assert Enum.map(streaming_state.stream.timeline, & &1.content) == [
             "First canonical thought.",
             "First canonical preamble.",
             "Second streamed preamble."
           ]

    assert Enum.map(streaming_state.stream.timeline, & &1.message_id) == [
             "assistant-1",
             "assistant-1",
             "assistant-2"
           ]

    send(tui, {:tackle_event, session_id, "turn-1", Event.message_end(second)})
    reconciled_state = state(tui)

    assert Enum.map(reconciled_state.stream.timeline, & &1.content) == [
             "First canonical thought.",
             "First canonical preamble.",
             "Second canonical preamble."
           ]

    assert reconciled_state.stream.active_message_id == nil

    entry_ids = Enum.map(reconciled_state.conversation.sections[:turn].entries, & &1.id)
    assert length(Enum.uniq(entry_ids)) == 3
  end

  test "ignores stale and uncorrelated runtime events", %{tui: tui} do
    inject_paste(tui, "hi")
    inject_key(tui, "enter")
    assert_receive {:submitted, "hi"}

    state = state(tui)
    delta = Event.new(:message_delta, %{delta: "stale"})

    send(tui, {:tackle_event, "other-session", "turn-1", delta})
    send(tui, {:tackle_event, state.session_id, "other-turn", delta})
    assert state(tui).stream.response == ""

    send(tui, {:tackle_event, state.session_id, "turn-1", delta})
    assert state(tui).stream.response == "stale"

    finish_turn(tui, [Message.user("hi"), Message.assistant(content: "done")])

    send(tui, {:tackle_event, state.session_id, "turn-1", delta})
    assert state(tui).stream.response == ""
    assert conversation_text(state(tui)) =~ "done"
  end

  test "renders settled assistant responses as Markdown with measured height", %{tui: tui} do
    inject_paste(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}
    state = state(tui)

    markdown = "# Done\n\nSome **bold** text with `code`.\n\n- first\n- second"
    agent_state = %{state.agent_state | messages: [Message.assistant(content: markdown)]}

    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {:ok, agent_state}})
    state = state(tui)

    assert Enum.any?(state.conversation.sections[:settled].entries, fn entry ->
             match?(%MessageView{kind: :assistant, content: ^markdown}, entry)
           end)

    assert Enum.any?(state.conversation.items, fn
             {%Markdown{content: ^markdown, style: %{fg: nil}}, height} ->
               height == Markdown.measure_height(markdown, state.conversation.width)

             _item ->
               false
           end)

    refute Enum.any?(state.conversation.items, fn
             {%Paragraph{text: text}, _height} -> plain(text) =~ "**bold**"
             _item -> false
           end)

    terminal = ExRatatui.init_test_terminal(80, 24)
    :ok = ExRatatui.draw(terminal, TUI.scene(state, frame(state)))
    rendered = ExRatatui.get_buffer_content(terminal)
    assert rendered =~ "Done"
    assert rendered =~ "first"
    assert rendered =~ "second"
  end

  test "renders streaming Markdown while a fenced code block is incomplete", %{tui: tui} do
    inject_paste(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}
    state = state(tui)

    markdown = "```elixir\nIO.puts(\"still streaming\")"

    send(
      tui,
      {:tackle_event, state.session_id, "turn-1", Event.new(:message_delta, %{delta: markdown})}
    )

    state = state(tui)

    assert Enum.any?(state.conversation.items, fn
             {%Markdown{content: ^markdown}, height} ->
               height == Markdown.measure_height(markdown, state.conversation.width)

             _item ->
               false
           end)

    terminal = ExRatatui.init_test_terminal(80, 24)
    :ok = ExRatatui.draw(terminal, TUI.scene(state, frame(state)))
    assert ExRatatui.get_buffer_content(terminal) =~ "still streaming"
  end

  test "remeasures Markdown entries after terminal resize", %{tui: tui} do
    inject_paste(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}
    state = state(tui)

    markdown = "A long response with enough words to wrap at a narrow width."
    agent_state = %{state.agent_state | messages: [Message.assistant(content: markdown)]}
    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {:ok, agent_state}})
    wide_state = state(tui)

    [{_wide_markdown, wide_height}] =
      wide_state.conversation.items
      |> Enum.filter(fn
        {%Markdown{}, _height} -> true
        _item -> false
      end)

    inject_resize(tui, 24, 24)
    narrow_state = state(tui)

    assert Enum.any?(narrow_state.conversation.items, fn
             {%Markdown{content: ^markdown}, narrow_height} ->
               narrow_height == Markdown.measure_height(markdown, narrow_state.conversation.width)

             _item ->
               false
           end)

    refute wide_height == Markdown.measure_height(markdown, narrow_state.conversation.width)
  end

  test "keeps long Markdown source intact while bounding visible windows", %{tui: tui} do
    inject_resize(tui, 30, 16)
    inject_paste(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}
    state = state(tui)

    markdown = Enum.map_join(1..200, "\n", &"**response line #{&1}**")
    messages = [Message.user("x"), Message.assistant(content: markdown)]
    agent_state = %{state.agent_state | messages: messages, status: :completed}
    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {:ok, agent_state}})
    state = state(tui)

    markdown_items =
      Enum.filter(state.conversation.items, fn
        {%Markdown{}, _height} -> true
        _item -> false
      end)

    assert markdown_items != []

    assert Enum.uniq(Enum.map(markdown_items, fn {%Markdown{content: content}, _} -> content end)) ==
             [markdown]

    assert Enum.all?(markdown_items, fn {_widget, height} -> height <= 64 end)
    assert length(state.conversation.visible_items) < length(state.conversation.items)
  end

  test "falls back safely when Markdown exceeds the native scroll range" do
    markdown = String.duplicate("x", 65_537)
    entry = %MessageView{kind: :assistant, content: markdown}

    items = MessageView.render_entry(entry, 1)

    assert items != []
    assert Enum.all?(items, fn {%Paragraph{}, height} -> height <= 64 end)
    refute Enum.any?(items, fn {widget, _height} -> match?(%Markdown{}, widget) end)
  end

  test "auto-follows conversation output beyond the viewport", %{tui: tui} do
    inject_resize(tui, 50, 12)
    inject_paste(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}
    state = state(tui)

    messages =
      Enum.map(1..20, fn index -> Message.user("older message #{index}") end) ++
        [Message.assistant(content: "LATEST-SENTINEL")]

    agent_state = %{state.agent_state | messages: messages, status: :completed}
    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {:ok, agent_state}})
    state = state(tui)
    terminal = ExRatatui.init_test_terminal(50, 12)

    :ok = ExRatatui.draw(terminal, TUI.scene(state, frame(state)))

    content = ExRatatui.get_buffer_content(terminal)
    assert content =~ "LATEST-SENTINEL"
    refute content =~ "older message 1\n"
    assert state.conversation.follow?
    assert length(state.conversation.visible_items) < length(state.conversation.items)

    render_count = Runtime.snapshot(tui).render_count
    inject_key(tui, "page_down")
    assert Runtime.snapshot(tui).render_count == render_count
  end

  test "reading position survives streaming and resize until jump to latest", %{tui: tui} do
    inject_resize(tui, 50, 14)
    inject_paste(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}

    state = state(tui)

    messages = Enum.map(1..20, fn index -> Message.user("message #{index}") end)

    snapshot = %Snapshot{
      session_id: state.session_id,
      agent_state: %{state.agent_state | messages: messages, status: :running},
      active_turn: %{id: "turn-1"}
    }

    send(tui, {:tackle_session_reconfigured, state.session_id, snapshot})
    bottom_state = state(tui)
    assert bottom_state.conversation.follow?
    assert reading_text(bottom_state) == nil

    inject_key(tui, "page_up")
    scrolled_state = state(tui)
    assert scrolled_state.conversation.scroll_offset < bottom_state.conversation.scroll_offset
    refute scrolled_state.conversation.follow?
    assert reading_text(scrolled_state) =~ "Reading back"
    anchor = scrolled_state.conversation.anchor
    assert anchor

    send(
      tui,
      {:tackle_event, state.session_id, "turn-1",
       Event.new(:message_delta, %{delta: String.duplicate("new output ", 20)})}
    )

    streamed_state = state(tui)
    assert streamed_state.conversation.scroll_offset == scrolled_state.conversation.scroll_offset
    refute streamed_state.conversation.follow?
    assert streamed_state.conversation.new_output?
    assert streamed_state.conversation.anchor.id == anchor.id
    assert reading_text(streamed_state) =~ "New output"

    assert hd(streamed_state.conversation.visible_items) ==
             hd(scrolled_state.conversation.visible_items)

    inject_resize(tui, 60, 16)
    resized_state = state(tui)
    assert resized_state.conversation.anchor.id == anchor.id
    refute resized_state.conversation.follow?

    assert hd(resized_state.conversation.visible_items) ==
             hd(scrolled_state.conversation.visible_items)

    assert resized_state.conversation.visible_offset == scrolled_state.conversation.visible_offset

    inject_key(tui, "end", ["ctrl"])
    followed_state = state(tui)
    assert followed_state.conversation.follow?
    refute followed_state.conversation.new_output?
    assert reading_text(followed_state) == nil
  end

  test "bounds widgets for one very long agent message", %{tui: tui} do
    inject_resize(tui, 30, 16)
    inject_paste(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}
    state = state(tui)

    response = Enum.map_join(1..200, "\n", &"response line #{&1}")
    messages = [Message.user("x"), Message.assistant(content: response)]
    agent_state = %{state.agent_state | messages: messages, status: :completed}
    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {:ok, agent_state}})
    state = state(tui)

    assert Enum.all?(state.conversation.items, fn {_widget, height} -> height <= 64 end)
    assert length(state.conversation.visible_items) < length(state.conversation.items)

    terminal = ExRatatui.init_test_terminal(30, 16)
    :ok = ExRatatui.draw(terminal, TUI.scene(state, frame(state)))
    content = ExRatatui.get_buffer_content(terminal)
    assert content =~ "line 200"
  end

  test "scrolls agent messages and pauses automatic following", %{tui: tui} do
    inject_resize(tui, 50, 14)
    inject_paste(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}
    state = state(tui)

    messages = Enum.map(1..20, fn index -> Message.user("message #{index}") end)

    snapshot = %Snapshot{
      session_id: state.session_id,
      agent_state: %{state.agent_state | messages: messages, status: :running},
      active_turn: %{id: "turn-1"}
    }

    send(tui, {:tackle_session_reconfigured, state.session_id, snapshot})
    bottom_state = state(tui)
    assert bottom_state.conversation.follow?

    inject_key(tui, "page_up")
    scrolled_state = state(tui)
    assert scrolled_state.conversation.scroll_offset < bottom_state.conversation.scroll_offset
    refute scrolled_state.conversation.follow?

    inject_key(tui, "home", ["ctrl"])
    assert state(tui).conversation.scroll_offset == 0

    render_count = Runtime.snapshot(tui).render_count
    :ok = Runtime.inject_event(tui, %Mouse{kind: "scroll_up", button: "", x: 10, y: 1})
    assert Runtime.snapshot(tui).render_count == render_count

    inject_key(tui, "page_down")
    scrolled_offset = state(tui).conversation.scroll_offset
    assert scrolled_offset > 0

    :ok = Runtime.inject_event(tui, %Mouse{kind: "scroll_up", button: "", x: 10, y: 5})
    assert state(tui).conversation.scroll_offset == scrolled_offset - 3
    refute state(tui).conversation.follow?

    inject_key(tui, "end", ["ctrl"])
    assert state(tui).conversation.follow?
  end

  test "measures wide graphemes when wrapping conversation items", %{tui: tui} do
    inject_resize(tui, 12, 24)
    inject_paste(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}
    state = state(tui)

    messages = [
      Message.user(String.duplicate("界", 8)),
      Message.assistant(content: "LATEST")
    ]

    agent_state = %{state.agent_state | messages: messages, status: :completed}
    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {:ok, agent_state}})
    state = state(tui)

    assert [
             {%Paragraph{}, 2},
             {_spacer, 1},
             {%Markdown{content: "LATEST"}, 1}
           ] = state.conversation.items

    terminal = ExRatatui.init_test_terminal(12, 24)
    :ok = ExRatatui.draw(terminal, TUI.scene(state, frame(state)))
    assert ExRatatui.get_buffer_content(terminal) =~ "LATEST"
  end

  test "measures emoji and combining graphemes when wrapping", %{tui: tui} do
    inject_resize(tui, 12, 30)
    inject_paste(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}
    state = state(tui)

    messages = [
      Message.user(String.duplicate("⌚", 8)),
      Message.user(String.duplicate("❤️", 8)),
      Message.user(String.duplicate("é", 13))
    ]

    agent_state = %{state.agent_state | messages: messages, status: :completed}
    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {:ok, agent_state}})
    state = state(tui)

    assert [{_watch, 2}, {_spacer_one, 1}, {_heart, 2}, {_spacer_two, 1}, {_accent, 2}] =
             state.conversation.items
  end

  # -- tools ---------------------------------------------------------------

  test "renders live tool calls with arguments, status, and bounded results", %{tui: tui} do
    inject_paste(tui, "go")
    inject_key(tui, "enter")
    assert_receive {:submitted, "go"}

    session_id = state(tui).session_id

    send(
      tui,
      {:tackle_event, session_id, "turn-1",
       Event.new(:tool_start, %{
         tool_call_id: "call-1",
         name: "read",
         arguments: %{"path" => "mix.exs"}
       })}
    )

    running_state = state(tui)
    assert running_state.activity == "running read"

    running_conversation = conversation_text(running_state)
    assert running_conversation =~ "● read"
    assert running_conversation =~ "read  mix.exs"
    refute running_conversation =~ "args:"
    assert running_conversation =~ "running"

    send(
      tui,
      {:tackle_event, session_id, "turn-1",
       Event.new(:tool_end, %{
         tool_call_id: "call-1",
         name: "read",
         result: String.duplicate("output ", 100)
       })}
    )

    completed_state = state(tui)
    assert completed_state.activity == "completed read"
    assert [%{id: "call-1", status: :completed}] = completed_state.tool_activity

    completed_conversation = conversation_text(completed_state)
    assert completed_conversation =~ "✓ read"
    assert completed_conversation =~ "read  mix.exs"
    assert completed_conversation =~ "completed"
    assert completed_conversation =~ "▌ output"
    assert completed_conversation =~ "…"
  end

  test "renders failed live tool calls", %{tui: tui} do
    inject_paste(tui, "go")
    inject_key(tui, "enter")
    assert_receive {:submitted, "go"}

    session_id = state(tui).session_id

    send(
      tui,
      {:tackle_event, session_id, "turn-1",
       Event.new(:tool_start, %{tool_call_id: "call-1", name: "bash", arguments: %{}})}
    )

    send(
      tui,
      {:tackle_event, session_id, "turn-1",
       Event.new(:tool_error, %{
         tool_call_id: "call-1",
         name: "bash",
         error: "command exited with status 1"
       })}
    )

    failed_state = state(tui)
    assert failed_state.activity == "failed bash"
    assert conversation_text(failed_state) =~ "✗ bash"
    assert conversation_text(failed_state) =~ "failed"
    assert conversation_text(failed_state) =~ "▌ command exited with status 1"
  end

  test "renders settled tool calls and results with stable ids", %{tui: tui} do
    inject_paste(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}

    state = state(tui)

    messages = [
      Message.user("inspect it"),
      Message.assistant(
        tool_calls: [
          %{id: "call-1", name: "read", arguments: %{"path" => "README.md"}}
        ]
      ),
      Message.tool_result("call-1", "read", "project documentation"),
      Message.assistant(content: "Done")
    ]

    agent_state = %{state.agent_state | messages: messages, status: :completed}
    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {:ok, agent_state}})
    state = state(tui)
    conversation = conversation_text(state)

    refute conversation =~ "● read"
    assert conversation =~ "✓ read  README.md"
    assert conversation =~ "completed"
    assert conversation =~ "▌ project documentation"
    assert Enum.count(Conversation.entries(state.conversation), &(&1.kind == :tool)) == 1
    refute conversation =~ "Tackle:"
    assert conversation =~ "Done"

    assert Enum.any?(Conversation.entries(state.conversation), fn entry ->
             entry.id == "tool:call-1" and entry.tool_output == "project documentation"
           end)
  end

  test "keeps full tool output for the inspector and copy while previewing head and tail", %{
    tui: tui
  } do
    output = Enum.map_join(1..50, "\n", &"line-#{&1}")

    state = settle_tool_output(tui, output)
    inline = conversation_text(state)

    assert inline =~ "line-1"
    assert inline =~ "line-2"
    assert inline =~ "… 46 lines hidden"
    assert inline =~ "line-50"
    refute inline =~ "line-25"

    entry = Enum.find(Conversation.entries(state.conversation), &(&1.id == "tool:call-1"))
    assert MessageView.tool_output(entry) == output

    inject_key(tui, "f4")
    inject_key(tui, "enter")
    inspector_state = state(tui)
    assert {:inspector, inspector} = inspector_state.overlay
    assert inspector.entry.id == "tool:call-1"
    assert popup_title(inspector_state) =~ "read"

    inject_key(tui, "end")
    inspector_state = state(tui)
    assert inspector_text(inspector_state) =~ "line-50"

    inject_key(tui, "y")
    assert_receive {:copied, ^output}
    assert popup_title(state(tui)) =~ "Copied full output"

    inject_key(tui, "esc")
    assert state(tui).overlay == nil
  end

  test "inspector browses tool cards and copies arguments without touching the draft", %{tui: tui} do
    args = %{"path" => "parser.ex", "edits" => [%{"oldText" => "before", "newText" => "after"}]}

    settle_messages(tui, [
      Message.assistant(
        tool_calls: [
          %{id: "read", name: "read", arguments: %{"path" => "parser.ex"}},
          %{id: "edit", name: "edit", arguments: args}
        ]
      ),
      Message.tool_result("read", "read", "source text"),
      Message.tool_result("edit", "edit", "Successfully replaced 1 block(s).")
    ])

    inject_paste(tui, "keep my draft")
    inject_key(tui, "f4")
    inject_key(tui, "enter")
    assert {:inspector, inspector} = state(tui).overlay
    assert inspector.entry.id == "tool:edit"
    assert inspector_text(state(tui)) =~ "Replacement preview"
    inject_key(tui, "a")
    assert_receive {:copied, encoded}
    assert JSON.decode!(encoded) == args
    inject_key(tui, "left")
    assert {:inspector, inspector} = state(tui).overlay
    assert inspector.entry.id == "tool:read"
    inject_key(tui, "y")
    assert_receive {:copied, "source text"}
    inject_key(tui, "right")
    assert {:inspector, inspector} = state(tui).overlay
    assert inspector.entry.id == "tool:edit"
    inject_key(tui, "esc")
    assert Tackle.CLI.Widgets.Input.get_value(state(tui).input) == "keep my draft"
  end

  test "F4 reports when there is nothing to browse", %{tui: tui} do
    inject_key(tui, "f4")
    state = state(tui)

    assert state.focus == :composer
    assert state.selected_entry == nil
    assert state.notice =~ "No messages to browse yet"
  end

  test "the transcript browser selects, copies, and inspects entries without touching the draft",
       %{
         tui: tui
       } do
    output = String.duplicate("tool output ", 100)

    _state =
      settle_messages(tui, [
        Message.user("question"),
        Message.assistant(content: "# Answer\n\nExact **Markdown** source"),
        Message.tool_result("call-1", "read", output)
      ])

    inject_paste(tui, "keep my draft")
    inject_key(tui, "f4")

    state = state(tui)
    assert state.focus == :transcript
    assert state.selected_entry == "tool:call-1"
    assert status_text(state) =~ "Browsing"
    assert status_text(state) =~ "3/3"
    assert hints_text(state) =~ "Esc or F4 back"

    inject_key(tui, "y")
    assert_receive {:copied, ^output}
    assert status_text(state(tui)) =~ "Copied full source"

    # Every entry in the transcript is reachable, and each keeps its own source.
    inject_key(tui, "p")
    inject_key(tui, "y")
    assert_receive {:copied, copied_answer}
    assert copied_answer =~ "Exact **Markdown** source"

    inject_key(tui, "p")
    inject_key(tui, "y")
    assert_receive {:copied, "You:\nquestion"}

    inject_key(tui, "a")
    assert_receive {:copied, full}
    assert full =~ "You:\nquestion"
    assert full =~ output

    # The selection stops at the ends instead of wrapping.
    inject_key(tui, "p")
    inject_key(tui, "y")
    assert_receive {:copied, "You:\nquestion"}

    inject_key(tui, "n")
    inject_key(tui, "enter")
    assert {:inspector, inspector} = state(tui).overlay
    assert inspector.entry.id == "message:1:assistant"

    inject_key(tui, "esc")
    assert state(tui).overlay == nil

    inject_key(tui, "esc")
    state = state(tui)
    assert state.focus == :composer
    assert state.selected_entry == nil
    assert draft(tui) == "keep my draft"
  end

  test "typing and pasting are inert while the transcript holds focus", %{tui: tui} do
    _state =
      settle_messages(tui, [Message.user("question"), Message.assistant(content: "answer")])

    inject_paste(tui, "draft first")
    inject_key(tui, "f4")

    Enum.each(["h", "e", "l", "l", "o", "x", "z"], &inject_key(tui, &1))
    inject_paste(tui, "ignored")

    state = state(tui)
    assert state.focus == :transcript
    assert state.overlay == nil
    assert Tackle.CLI.Widgets.Input.get_value(state.input) == "draft first"
    assert find_widget(state, &match?(%Popup{}, &1)) == nil

    inject_key(tui, "f4")
    state = state(tui)
    assert state.focus == :composer
    assert Tackle.CLI.Widgets.Input.get_value(state.input) == "draft first"
  end

  test "the browser keeps the selection visible in a long transcript", %{tui: tui} do
    messages = Enum.map(1..20, fn n -> Message.user("message-#{n}") end)
    _state = settle_messages(tui, messages)

    inject_key(tui, "f4")
    state = state(tui)
    assert state.selected_entry == "message:19:user"

    Enum.each(1..40, fn _ -> inject_key(tui, "p") end)
    state = state(tui)

    assert state.selected_entry == "message:0:user"
    # The transcript scrolled back to follow the selection rather than leaving it
    # highlighted off-screen.
    assert state.conversation.scroll_offset == 0
    assert state.conversation.follow? == false
  end

  test "the browser re-anchors when the selected entry is replaced by a settled one", %{
    tui: tui
  } do
    inject_paste(tui, "hi")
    inject_key(tui, "enter")
    assert_receive {:submitted, "hi"}

    session_id = state(tui).session_id
    send(tui, {:tackle_event, session_id, "turn-1", Event.new(:message_delta, %{delta: "Hello"})})

    inject_key(tui, "f4")
    assert state(tui).selected_entry == "streaming:response"

    finish_turn(tui, [Message.user("hi"), Message.assistant(content: "Hello")])
    state = state(tui)

    assert state.focus == :transcript
    assert state.selected_entry == "message:1:assistant"
    assert highlighted_ids(state) == ["message:1:assistant"]
  end

  test "the browser keeps the reading chords live", %{tui: tui} do
    _state =
      settle_messages(tui, [
        Message.user("ask"),
        Message.assistant(thinking: "reasoning here", content: "answer")
      ])

    inject_key(tui, "f4")
    inject_key(tui, "t", ["ctrl"])
    state = state(tui)

    assert state.focus == :transcript
    assert state.thinking_expanded?

    inject_key(tui, "f", ["ctrl"])
    state = state(tui)
    assert {:search, _} = state.overlay

    inject_key(tui, "esc")
    state = state(tui)
    assert state.overlay == nil
    assert state.focus == :transcript
  end

  test "the browser highlight follows the selection", %{tui: tui} do
    _state =
      settle_messages(tui, [Message.user("question"), Message.assistant(content: "answer")])

    inject_key(tui, "f4")
    state = state(tui)
    assert state.selected_entry == "message:1:assistant"
    assert highlighted_ids(state) == ["message:1:assistant"]

    inject_key(tui, "p")
    state = state(tui)
    assert state.selected_entry == "message:0:user"
    assert highlighted_ids(state) == ["message:0:user"]

    inject_key(tui, "esc")
    assert highlighted_ids(state(tui)) == []
  end

  # -- reasoning -----------------------------------------------------------

  test "collapses supplied reasoning and reveals it on demand", %{tui: tui} do
    state =
      settle_messages(tui, [
        Message.user("ask"),
        Message.assistant(thinking: "first line\nsecond line\nthird line", content: "answer")
      ])

    collapsed = conversation_text(state)
    assert collapsed =~ "thought"
    assert collapsed =~ "first line"
    assert collapsed =~ "Ctrl+T to reveal"
    refute collapsed =~ "third line"

    inject_key(tui, "t", ["ctrl"])
    expanded = conversation_text(state(tui))

    assert expanded =~ "third line"
    assert expanded =~ "answer"
  end

  # -- search and menus ----------------------------------------------------

  test "searches retained source including hidden tool output and reveals matches", %{tui: tui} do
    _state =
      settle_messages(tui, [
        Message.user("ask"),
        Message.assistant(
          tool_calls: [%{id: "call-9", name: "read", arguments: %{"path" => "secret.txt"}}]
        ),
        Message.tool_result("call-9", "read", "hidden NEEDLE-TOKEN tail")
      ])

    inject_key(tui, "f", ["ctrl"])
    state = state(tui)
    assert {:search, %{query: ""}} = state.overlay

    Enum.each(["n", "e", "e", "d", "l", "e"], &inject_key(tui, &1))

    state = state(tui)
    assert {:search, %{query: "needle"}} = state.overlay
    assert {:search, %{matches: [match]}} = state.overlay
    assert match.id == "tool:call-9"

    refute state.conversation.follow?
    assert conversation_text(state) =~ "NEEDLE-TOKEN"
    assert status_text(state) =~ "Match 1/1"
    assert popup_title(state) =~ "1/1"
    assert %TextInput{} = popup_content(state)

    inject_key(tui, "enter")
    assert state(tui).overlay |> elem(1) |> Map.fetch!(:index) == 0

    inject_key(tui, "esc")
    assert state(tui).overlay == nil
    refute_receive {:submitted, _}
  end

  test "menu search filters the list and preserves the draft", %{tui: tui} do
    inject_paste(tui, "draft survives")
    inject_key(tui, "f2")

    Enum.each(["h", "i", "g", "h"], &inject_key(tui, &1))
    state = state(tui)

    assert {:picker, %{picker: %{query: "high"}}} = state.overlay
    assert status_text(state) =~ "Deep reasoning"

    # A prefix match ranks above the looser one that contains it.
    assert %SelectionList{items: [first | _rest], selected: 0} = popup_content(state)
    assert first =~ "high"
    assert first =~ "Deep reasoning"

    inject_key(tui, "enter")
    assert_receive {:reconfigured, [thinking: "high"]}

    state = state(tui)
    assert state.overlay == nil
    assert header_text(state) =~ "thinking high"
    assert draft(tui) == "draft survives"
  end

  test "menu search reports no matches without changing the selection target", %{tui: tui} do
    inject_key(tui, "f2")

    Enum.each(["z", "z", "z"], &inject_key(tui, &1))
    state = state(tui)

    assert %Paragraph{text: " No options match."} = popup_content(state)

    # Enter on an empty result set is inert rather than selecting nothing.
    inject_key(tui, "enter")
    assert {:picker, _} = state(tui).overlay
    refute_receive {:reconfigured, _}, 50
  end

  # -- cancel and quit -----------------------------------------------------

  test "Esc closes overlays, cancels once, and never exits while idle", %{tui: tui} do
    inject_key(tui, "f1")
    assert state(tui).overlay != nil
    inject_key(tui, "esc")
    assert state(tui).overlay == nil
    assert Process.alive?(tui)

    inject_paste(tui, "h")
    inject_key(tui, "enter")
    assert_receive {:submitted, "h"}

    inject_key(tui, "esc")
    assert_receive :cancelled
    state = await_state(tui, &is_nil(&1.pending_operation))
    assert state.activity == "cancelling"

    inject_key(tui, "esc")
    refute_receive :cancelled, 100
    assert state(tui).notice =~ "already requested"

    finish_turn(tui, [Message.user("h")], :cancelled)
    assert status_text(state(tui)) =~ "cancelled"

    ref = Process.monitor(tui)
    inject_key(tui, "esc")
    refute_receive {:DOWN, ^ref, :process, ^tui, _reason}, 100
    assert state(tui).notice =~ "does not quit"
    Process.demonitor(ref, [:flush])
  end

  test "Ctrl+C quits immediately when idle with an empty draft", %{tui: tui} do
    ref = Process.monitor(tui)
    inject_key(tui, "c", ["ctrl"])
    assert_receive {:DOWN, ^ref, :process, ^tui, :normal}
  end

  test "Ctrl+C confirms before discarding a draft", %{tui: tui} do
    inject_paste(tui, "unsent work")
    ref = Process.monitor(tui)

    inject_key(tui, "c", ["ctrl"])
    state = state(tui)
    assert {:confirm_quit, %{reason: :draft}} = state.overlay

    inject_key(tui, "esc")
    assert state(tui).overlay == nil
    assert draft(tui) == "unsent work"
    refute_receive {:DOWN, ^ref, :process, ^tui, _reason}, 100

    inject_key(tui, "c", ["ctrl"])
    inject_key(tui, "y")
    assert_receive {:DOWN, ^ref, :process, ^tui, :normal}
  end

  test "Ctrl+C confirms before stopping an active turn", %{tui: tui} do
    inject_paste(tui, "work")
    inject_key(tui, "enter")
    assert_receive {:submitted, "work"}

    ref = Process.monitor(tui)
    inject_key(tui, "c", ["ctrl"])
    assert {:confirm_quit, %{reason: :turn}} = state(tui).overlay

    inject_key(tui, "n")
    assert state(tui).overlay == nil
    refute_receive {:DOWN, ^ref, :process, ^tui, _reason}, 100
    Process.demonitor(ref, [:flush])
  end

  # -- lifecycle -----------------------------------------------------------

  test "returns an error when the agent terminates abnormally" do
    test_pid = self()
    agent_ref = AgentRef.new!(ID.generate(), ID.generate())
    {:ok, session} = SessionStub.start_link({test_pid, agent_ref})
    Process.unlink(session)

    task =
      Task.async(fn ->
        TUI.start(agent_ref: agent_ref, test_mode: {40, 10})
      end)

    assert_receive {:subscribed, tui}
    _snapshot = Runtime.snapshot(tui)
    Process.exit(session, :kill)

    assert {:error, {:agent_down, :killed}} = Task.await(task)
    refute Process.alive?(tui)
  end

  test "treats an App shutdown as a clean exit", %{agent_ref: agent_ref} do
    task = Task.async(fn -> TUI.start(agent_ref: agent_ref, test_mode: {40, 10}) end)

    assert_receive {:subscribed, tui}
    session_id = state(tui).session_id
    GenServer.stop(tui, :shutdown)

    assert {:ok, ^session_id} = Task.await(task)
  end

  test "reports the session it was attached to when it exits" do
    test_pid = self()
    first_ref = AgentRef.new!(ID.generate(), ID.generate())
    replacement_ref = AgentRef.new!(ID.generate(), ID.generate())
    {:ok, first} = SessionStub.start_link({test_pid, first_ref})
    Process.unlink(first)
    {:ok, replacement} = SessionStub.start_link({test_pid, replacement_ref})
    Process.unlink(replacement)

    task =
      Task.async(fn ->
        TUI.start(
          agent_ref: first_ref,
          test_mode: {40, 10},
          new_session: fn _overrides ->
            {:ok, %Scope{scope_ref: nil, root_agent_ref: replacement_ref}}
          end
        )
      end)

    assert_receive {:subscribed, tui}
    first_session = state(tui).session_id

    inject_key(tui, "n", ["alt"])
    inject_key(tui, "y")

    replacement_session = await_state(tui, &(&1.session_id != first_session)).session_id
    assert is_binary(replacement_session)

    inject_key(tui, "c", ["ctrl"])

    assert {:ok, ^replacement_session} = Task.await(task)
  end

  test "stops the App when the process calling start dies", %{agent_ref: agent_ref} do
    caller = spawn(fn -> TUI.start(agent_ref: agent_ref, test_mode: {40, 10}) end)

    assert_receive {:subscribed, tui}
    _snapshot = Runtime.snapshot(tui)
    ref = Process.monitor(tui)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^ref, :process, ^tui, :shutdown}
  end

  # -- helpers -------------------------------------------------------------

  defp state(tui), do: :sys.get_state(tui).user_state

  defp await_state(tui, predicate, attempts \\ 400)

  defp await_state(tui, predicate, attempts) when attempts > 0 do
    state = state(tui)

    if predicate.(state) do
      state
    else
      Process.sleep(5)
      await_state(tui, predicate, attempts - 1)
    end
  end

  defp await_state(_tui, _predicate, 0),
    do: flunk("shell state never reached the expected condition")

  defp frame(state) do
    {width, height} = state.size
    %ExRatatui.Frame{width: width, height: height}
  end

  defp widgets(state), do: TUI.scene(state, frame(state))

  defp regions(state) do
    {width, height} = state.size
    Layout.regions(width, height, state.draft_lines, reading?(state.conversation))
  end

  defp reading?(conversation), do: conversation.new_output? or not conversation.follow?

  defp header_text(state) do
    state |> widgets() |> hd() |> elem(0) |> Map.fetch!(:text) |> plain()
  end

  defp transcript_widget(state) do
    find_widget(state, &match?(%WidgetList{}, &1))
  end

  defp composer_widget(state) do
    find_widget(state, &match?(%Tackle.CLI.Widgets.Input{}, &1))
  end

  defp status_text(state) do
    case regions(state).status do
      nil -> nil
      rect -> widget_text_at(state, rect)
    end
  end

  defp hints_text(state) do
    case regions(state).hints do
      nil -> nil
      rect -> widget_text_at(state, rect)
    end
  end

  defp reading_text(state) do
    case regions(state).reading do
      nil -> nil
      rect -> widget_text_at(state, rect)
    end
  end

  defp widget_text_at(state, rect) do
    state
    |> widgets()
    |> Enum.find_value(fn
      {widget, ^rect} -> widget |> Map.get(:text) |> plain()
      _widget -> nil
    end)
  end

  defp find_widget(state, matcher) do
    state
    |> widgets()
    |> Enum.find_value(fn {widget, _rect} -> if matcher.(widget), do: widget end)
  end

  defp popup_title(state) do
    state
    |> find_widget(&match?(%Popup{}, &1))
    |> Map.fetch!(:block)
    |> Map.fetch!(:title)
  end

  defp popup_content(state) do
    state
    |> find_widget(&match?(%Popup{}, &1))
    |> Map.fetch!(:content)
  end

  # The browser highlight is a merge of the selection surface over each widget
  # of the selected entry, so the ids carrying it are the selected ones.
  defp assert_draws(state, width, height, expected \\ nil) do
    terminal = ExRatatui.init_test_terminal(width, height)
    :ok = ExRatatui.draw(terminal, TUI.scene(state, frame(state)))
    content = ExRatatui.get_buffer_content(terminal)
    assert is_binary(content)
    if expected, do: assert(content =~ expected, "expected #{inspect(expected)} in:\n#{content}")
    content
  end

  defp highlighted_ids(state) do
    state.conversation.item_ids
    |> Enum.zip(state.conversation.items)
    |> Enum.flat_map(fn
      {id, {widget, _height}} ->
        if widget |> Map.get(:style, %Style{}) |> Map.get(:bg) == selection_bg(),
          do: [id],
          else: []

      _other ->
        []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp selection_bg, do: Theme.style(:selection_surface).bg

  defp inspector_text(state) do
    {:inspector, inspector} = state.overlay

    inspector.items
    |> Enum.map_join("\n", fn {widget, _height} -> widget |> Map.fetch!(:text) |> plain() end)
  end

  # Flattens a widget's rich text (string, Line, or list of Lines) to plain text.
  defp plain(text) when is_binary(text), do: text
  defp plain(%Line{spans: spans}), do: Enum.map_join(spans, "", & &1.content)
  defp plain(lines) when is_list(lines), do: Enum.map_join(lines, "\n", &plain/1)

  defp conversation_text(state) do
    state
    |> transcript_widget()
    |> Map.fetch!(:items)
    |> Enum.map_join("\n", fn
      {%Paragraph{text: text}, _height} -> plain(text)
      {%Markdown{content: content}, _height} -> content
      {_widget, _height} -> ""
    end)
  end

  defp draft(tui) do
    Tackle.CLI.Widgets.Input.get_value(state(tui).input)
  end

  defp settle_messages(tui, messages) do
    if state(tui).active_turn == nil do
      inject_paste(tui, "seed")
      inject_key(tui, "enter")
      assert_receive {:submitted, "seed"}
    end

    finish_turn(tui, messages)
  end

  defp settle_tool_output(tui, output) do
    inject_paste(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}

    settle_messages(tui, [
      Message.user("x"),
      Message.assistant(tool_calls: [%{id: "call-1", name: "read", arguments: %{}}]),
      Message.tool_result("call-1", "read", output)
    ])
  end

  defp finish_turn(tui, messages, outcome \\ :ok) do
    state = state(tui)
    agent_state = %{state.agent_state | messages: messages, status: :completed}
    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {outcome, agent_state}})
    state(tui)
  end

  defp inject_key(tui, code, modifiers \\ [], kind \\ "press") do
    :ok = Runtime.inject_event(tui, %Key{code: code, modifiers: modifiers, kind: kind})
  end

  defp inject_paste(tui, content) do
    :ok = Runtime.inject_event(tui, %Paste{content: content})
  end

  defp inject_resize(tui, width, height) do
    :ok = Runtime.inject_event(tui, %Resize{width: width, height: height})
  end

  defp assert_regions_within_bounds(regions, width, height) do
    rects =
      [
        regions.header,
        regions.transcript,
        regions.reading,
        regions.status,
        regions.composer,
        regions.hints
      ]
      |> Enum.reject(&is_nil/1)

    Enum.each(rects, fn rect ->
      assert rect.x >= 0 and rect.y >= 0
      assert rect.x + rect.width <= width
      assert rect.y + rect.height <= height
    end)

    rects
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [above, below] -> assert above.y + above.height <= below.y end)
  end
end
