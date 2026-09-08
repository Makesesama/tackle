defmodule Tackle.CLI.TUITest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}
  alias ExRatatui.Runtime
  alias ExRatatui.Widgets.{Paragraph, TextInput, WidgetList}
  alias Tackle.CLI.TUI
  alias Tackle.Lib.{Event, Message, State}
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
      def generate(_schema, _opts), do: {:error, :not_used}
    end

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    def child_spec(test_pid) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [test_pid]}, restart: :temporary}
    end

    @impl true
    def init(test_pid) do
      {:ok, llm} = Tackle.Lib.LLM.select([Adapter], "openai-codex/test-model")
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
      {:reply, {:ok, "turn-1"}, state}
    end

    def handle_call(:cancel, _from, state) do
      send(state.test_pid, :cancelled)
      {:reply, :ok, state}
    end

    def handle_call({:reconfigure, opts}, _from, state) do
      send(state.test_pid, {:reconfigured, opts})
      model = Keyword.get(opts, :model, state.agent_state.llm.ref)
      {:ok, llm} = Tackle.Lib.LLM.select([Adapter], model)
      {:ok, llm_opts} = Tackle.Thinking.put_llm_opts(state.agent_state.llm_opts, opts[:thinking])
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
    session = start_supervised!({SessionStub, self()})

    tui =
      start_supervised!(
        {TUI,
         session: session,
         models: ["openai-codex/test-model", "openai-codex/other-model"],
         name: nil,
         test_mode: {80, 20}}
      )

    assert_receive {:subscribed, ^tui}
    %{session: session, tui: tui}
  end

  test "runs as an ExRatatui.App with session and input state", %{tui: tui} do
    server_state = :sys.get_state(tui)

    assert server_state.user_state.agent_state.model == "test-model"
    assert server_state.user_state.agent_state.llm.ref == "openai-codex/test-model"
    assert is_reference(server_state.user_state.input)
    assert function_exported?(TUI, :start_link, 1)
  end

  test "renders the basic session, conversation, prompt, and footer", %{tui: tui} do
    state = :sys.get_state(tui).user_state
    scene = TUI.scene(state, %ExRatatui.Frame{width: 80, height: 20})

    assert [
             {%Paragraph{text: header}, _header_area},
             {%WidgetList{items: conversation}, _conversation_area},
             {%TextInput{}, _input_area},
             {%Paragraph{text: footer}, _footer_area}
           ] = scene

    assert header =~ "openai-codex/test-model"
    assert header =~ "thinking off"
    assert header =~ "ready"

    assert Enum.any?(conversation, fn {%Paragraph{text: text}, _height} ->
             text =~ "Welcome to Tackle"
           end)

    assert footer =~ "Enter send"
    assert footer =~ "F2 model/thinking"
    refute footer =~ "CH"
  end

  test "selects the model and thinking level from the settings popup", %{tui: tui} do
    inject_key(tui, "f2")
    state = :sys.get_state(tui).user_state
    assert state.settings.field == :model

    :ok = Runtime.inject_event(tui, %Paste{content: "hidden prompt"})
    state = :sys.get_state(tui).user_state
    assert ExRatatui.text_input_get_value(state.input) == ""
    assert length(TUI.scene(state, %ExRatatui.Frame{width: 80, height: 20})) == 5

    inject_key(tui, "right")
    inject_key(tui, "down")
    inject_key(tui, "right")
    inject_key(tui, "enter")

    assert_receive {:reconfigured, [model: "openai-codex/other-model", thinking: "minimal"]}

    state = :sys.get_state(tui).user_state
    assert state.settings == nil
    assert state.agent_state.model == "other-model"
    assert state.agent_state.llm.ref == "openai-codex/other-model"
    assert Tackle.Thinking.from_llm_opts(state.agent_state.llm_opts) == "minimal"
    assert header_text(state) =~ "thinking minimal"
  end

  test "shows the latest Pi-compatible cache hit rate in the footer", %{tui: tui} do
    inject_key(tui, "g")
    inject_key(tui, "o")
    inject_key(tui, "enter")
    assert_receive {:submitted, "go"}

    state = :sys.get_state(tui).user_state

    send(
      tui,
      {:tackle_event, state.session_id, "turn-1",
       Event.usage(%{
         input_tokens: 100,
         output_tokens: 10,
         cache_read_tokens: 50,
         cache_write_tokens: 50
       })}
    )

    live_state = :sys.get_state(tui).user_state
    assert footer_text(live_state) =~ "CH25.0%"

    agent_state = %{
      live_state.agent_state
      | messages: [
          Message.assistant(
            content: "done",
            token_usage: %{
              input_tokens: 100,
              output_tokens: 10,
              cache_read_tokens: 50,
              cache_write_tokens: 50
            }
          )
        ],
        status: :completed
    }

    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {:ok, agent_state}})
    settled_state = :sys.get_state(tui).user_state
    assert footer_text(settled_state) =~ "CH25.0%"
  end

  test "submits the current prompt on Enter", %{tui: tui} do
    inject_key(tui, "h")
    inject_key(tui, "i")
    inject_key(tui, "enter")
    _server_state = :sys.get_state(tui)

    assert_receive {:submitted, "hi"}

    state = :sys.get_state(tui).user_state
    assert state.active_turn == %{id: "turn-1"}
    assert state.pending_prompt == "hi"
    assert ExRatatui.text_input_get_value(state.input) == ""
  end

  test "projects streaming text and settles the completed conversation", %{tui: tui} do
    inject_key(tui, "h")
    inject_key(tui, "i")
    inject_key(tui, "enter")
    assert_receive {:submitted, "hi"}

    session_id = :sys.get_state(tui).user_state.session_id
    thinking_event = Event.new(:message_delta, %{field: :reasoning, delta: "Checking"})
    send(tui, {:tackle_event, session_id, "turn-1", thinking_event})

    event = Event.new(:message_delta, %{delta: "Hello"})
    send(tui, {:tackle_event, session_id, "turn-1", event})

    streaming_state = :sys.get_state(tui).user_state
    assert streaming_state.streaming_thinking == "Checking"
    assert streaming_state.streaming_response == "Hello"
    assert conversation_text(streaming_state) =~ "Thinking:\nChecking"

    agent_state = %{
      streaming_state.agent_state
      | messages: [
          Message.user("hi"),
          Message.assistant(thinking: "Checked", content: "Hello")
        ],
        status: :completed
    }

    send(tui, {:tackle_turn_finished, session_id, "turn-1", {:ok, agent_state}})
    settled_state = :sys.get_state(tui).user_state

    assert settled_state.active_turn == nil
    assert settled_state.pending_prompt == nil
    assert settled_state.streaming_thinking == ""
    assert settled_state.streaming_response == ""

    assert [{%WidgetList{items: items}, _area}] =
             TUI.scene(settled_state, %ExRatatui.Frame{width: 80, height: 20})
             |> Enum.filter(fn {widget, _area} ->
               match?(%WidgetList{block: %{title: " Conversation "}}, widget)
             end)

    conversation =
      Enum.map_join(items, "\n", fn {%Paragraph{text: text}, _height} -> text end)

    assert conversation =~ "You:\nhi"
    assert conversation =~ "Thinking:\nChecked"
    assert conversation =~ "Tackle:\nHello"
  end

  test "renders live tool calls with arguments, status, and truncated results", %{tui: tui} do
    inject_key(tui, "g")
    inject_key(tui, "o")
    inject_key(tui, "enter")
    assert_receive {:submitted, "go"}

    session_id = :sys.get_state(tui).user_state.session_id

    send(
      tui,
      {:tackle_event, session_id, "turn-1",
       Event.new(:tool_start, %{
         tool_call_id: "call-1",
         name: "read",
         arguments: %{"path" => "mix.exs"}
       })}
    )

    running_state = :sys.get_state(tui).user_state
    assert running_state.activity == "running read"

    running_conversation = conversation_text(running_state)
    assert running_conversation =~ "● read"
    assert running_conversation =~ ~s("path":"mix.exs")
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

    completed_state = :sys.get_state(tui).user_state
    assert completed_state.activity == "completed read"
    assert [%{id: "call-1", status: :completed}] = completed_state.tool_activity

    completed_conversation = conversation_text(completed_state)
    assert completed_conversation =~ "✓ read"
    assert completed_conversation =~ ~s("path":"mix.exs")
    assert completed_conversation =~ "completed"
    assert completed_conversation =~ "result: output"
    assert completed_conversation =~ "…"
  end

  test "renders failed live tool calls", %{tui: tui} do
    inject_key(tui, "g")
    inject_key(tui, "o")
    inject_key(tui, "enter")
    assert_receive {:submitted, "go"}

    session_id = :sys.get_state(tui).user_state.session_id

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

    failed_state = :sys.get_state(tui).user_state
    assert failed_state.activity == "failed bash"
    assert conversation_text(failed_state) =~ "✗ bash\n  failed\n  error: command exited"
  end

  test "renders settled tool calls and results from conversation history", %{tui: tui} do
    inject_key(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}

    state = :sys.get_state(tui).user_state

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
    state = :sys.get_state(tui).user_state
    conversation = conversation_text(state)

    assert conversation =~ "● read"
    assert conversation =~ ~s("path":"README.md")
    assert conversation =~ "✓ read\n  completed\n  result: project documentation"
    assert conversation =~ "Tackle:\nDone"
  end

  test "auto-follows conversation output beyond the viewport", %{tui: tui} do
    :ok = Runtime.inject_event(tui, %Resize{width: 50, height: 12})
    inject_key(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}
    state = :sys.get_state(tui).user_state

    messages =
      Enum.map(1..20, fn index -> Message.user("older message #{index}") end) ++
        [Message.assistant(content: "LATEST-SENTINEL")]

    agent_state = %{state.agent_state | messages: messages, status: :completed}
    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {:ok, agent_state}})
    state = :sys.get_state(tui).user_state
    terminal = ExRatatui.init_test_terminal(50, 12)

    :ok =
      ExRatatui.draw(
        terminal,
        TUI.scene(state, %ExRatatui.Frame{width: 50, height: 12})
      )

    content = ExRatatui.get_buffer_content(terminal)
    assert content =~ "LATEST-SENTINEL"
    refute content =~ "older message 1"
    assert state.conversation.follow?
    assert length(state.conversation.visible_items) < length(state.conversation.items)

    render_count = Runtime.snapshot(tui).render_count
    inject_key(tui, "page_down")
    assert Runtime.snapshot(tui).render_count == render_count
  end

  test "bounds widgets for one very long agent message", %{tui: tui} do
    :ok = Runtime.inject_event(tui, %Resize{width: 30, height: 16})
    inject_key(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}
    state = :sys.get_state(tui).user_state

    response = Enum.map_join(1..200, "\n", &"response line #{&1}")
    messages = [Message.user("x"), Message.assistant(content: response)]
    agent_state = %{state.agent_state | messages: messages, status: :completed}
    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {:ok, agent_state}})
    state = :sys.get_state(tui).user_state

    assert Enum.all?(state.conversation.items, fn {_widget, height} -> height <= 64 end)
    assert length(state.conversation.visible_items) < length(state.conversation.items)

    terminal = ExRatatui.init_test_terminal(30, 16)
    :ok = ExRatatui.draw(terminal, TUI.scene(state, %ExRatatui.Frame{width: 30, height: 16}))
    content = ExRatatui.get_buffer_content(terminal)
    assert content =~ "response line 200"
    refute content =~ "response line 1\n"
  end

  test "scrolls agent messages and pauses automatic following", %{tui: tui} do
    :ok = Runtime.inject_event(tui, %Resize{width: 50, height: 14})
    inject_key(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}
    state = :sys.get_state(tui).user_state

    messages = Enum.map(1..20, fn index -> Message.user("message #{index}") end)
    agent_state = %{state.agent_state | messages: messages, status: :running}

    snapshot = %Snapshot{
      session_id: state.session_id,
      agent_state: agent_state,
      active_turn: %{id: "turn-1"}
    }

    send(tui, {:tackle_session_reconfigured, state.session_id, snapshot})
    bottom_state = :sys.get_state(tui).user_state
    assert bottom_state.conversation.follow?

    inject_key(tui, "page_up")
    scrolled_state = :sys.get_state(tui).user_state
    assert scrolled_state.conversation.scroll_offset < bottom_state.conversation.scroll_offset
    refute scrolled_state.conversation.follow?

    send(
      tui,
      {:tackle_event, state.session_id, "turn-1",
       Event.new(:message_delta, %{delta: String.duplicate("new output ", 20)})}
    )

    updated_state = :sys.get_state(tui).user_state
    assert updated_state.conversation.scroll_offset == scrolled_state.conversation.scroll_offset
    refute updated_state.conversation.follow?

    :ok = Runtime.inject_event(tui, %Resize{width: 60, height: 16})
    resized_state = :sys.get_state(tui).user_state
    assert resized_state.conversation.scroll_offset == updated_state.conversation.scroll_offset
    refute resized_state.conversation.follow?

    :ok =
      Runtime.inject_event(tui, %Key{
        code: "end",
        modifiers: ["ctrl"],
        kind: "press"
      })

    followed_state = :sys.get_state(tui).user_state
    assert followed_state.conversation.follow?

    :ok =
      Runtime.inject_event(tui, %Mouse{kind: "scroll_up", button: "", x: 10, y: 5})

    mouse_state = :sys.get_state(tui).user_state
    assert mouse_state.conversation.scroll_offset == followed_state.conversation.scroll_offset - 3
    refute mouse_state.conversation.follow?

    :ok =
      Runtime.inject_event(tui, %Key{
        code: "home",
        modifiers: ["ctrl"],
        kind: "press"
      })

    assert :sys.get_state(tui).user_state.conversation.scroll_offset == 0
    inject_key(tui, "page_down")
    assert :sys.get_state(tui).user_state.conversation.scroll_offset > 0

    render_count = Runtime.snapshot(tui).render_count
    :ok = Runtime.inject_event(tui, %Mouse{kind: "scroll_up", button: "", x: 10, y: 1})
    assert Runtime.snapshot(tui).render_count == render_count
  end

  test "measures wide graphemes when wrapping conversation items", %{tui: tui} do
    :ok = Runtime.inject_event(tui, %Resize{width: 12, height: 20})
    inject_key(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}
    state = :sys.get_state(tui).user_state

    messages = [
      Message.user(String.duplicate("界", 8)),
      Message.assistant(content: "LATEST")
    ]

    agent_state = %{state.agent_state | messages: messages, status: :completed}
    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {:ok, agent_state}})
    state = :sys.get_state(tui).user_state

    assert [{_user, 3}, {_spacer, 1}, {_assistant, 2}] = state.conversation.items

    terminal = ExRatatui.init_test_terminal(12, 20)
    :ok = ExRatatui.draw(terminal, TUI.scene(state, %ExRatatui.Frame{width: 12, height: 20}))
    assert ExRatatui.get_buffer_content(terminal) =~ "LATEST"
  end

  test "measures emoji and combining graphemes when wrapping", %{tui: tui} do
    :ok = Runtime.inject_event(tui, %Resize{width: 12, height: 30})
    inject_key(tui, "x")
    inject_key(tui, "enter")
    assert_receive {:submitted, "x"}
    state = :sys.get_state(tui).user_state

    messages = [
      Message.user(String.duplicate("⌚", 8)),
      Message.user(String.duplicate("❤️", 8)),
      Message.user(String.duplicate("é", 12))
    ]

    agent_state = %{state.agent_state | messages: messages, status: :completed}
    send(tui, {:tackle_turn_finished, state.session_id, "turn-1", {:ok, agent_state}})
    state = :sys.get_state(tui).user_state

    assert [{_watch, 3}, {_spacer_one, 1}, {_heart, 3}, {_spacer_two, 1}, {_accent, 3}] =
             state.conversation.items
  end

  test "returns an error when the session terminates abnormally" do
    {:ok, session} = SessionStub.start_link(self())
    Process.unlink(session)

    task =
      Task.async(fn ->
        TUI.start(session: session, test_mode: {40, 10})
      end)

    assert_receive {:subscribed, tui}
    _snapshot = Runtime.snapshot(tui)
    Process.exit(session, :kill)

    assert {:error, {:session_down, :killed}} = Task.await(task)
    refute Process.alive?(tui)
  end

  test "treats an App shutdown as a clean exit", %{session: session} do
    task = Task.async(fn -> TUI.start(session: session, test_mode: {40, 10}) end)

    assert_receive {:subscribed, tui}
    _snapshot = Runtime.snapshot(tui)
    GenServer.stop(tui, :shutdown)

    assert Task.await(task) == :ok
  end

  test "stops the App when the process calling start dies", %{session: session} do
    caller = spawn(fn -> TUI.start(session: session, test_mode: {40, 10}) end)

    assert_receive {:subscribed, tui}
    _snapshot = Runtime.snapshot(tui)
    ref = Process.monitor(tui)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^ref, :process, ^tui, :shutdown}
  end

  test "Esc cancels an active turn and exits when idle", %{tui: tui} do
    inject_key(tui, "h")
    inject_key(tui, "enter")
    assert_receive {:submitted, "h"}

    inject_key(tui, "esc")
    assert_receive :cancelled
    assert Process.alive?(tui)

    state = :sys.get_state(tui).user_state

    send(
      tui,
      {:tackle_turn_finished, state.session_id, "turn-1", {:cancelled, state.agent_state}}
    )

    _server_state = :sys.get_state(tui)

    ref = Process.monitor(tui)
    inject_key(tui, "esc")
    assert_receive {:DOWN, ^ref, :process, ^tui, :normal}
  end

  defp header_text(state) do
    TUI.scene(state, %ExRatatui.Frame{width: 120, height: 30})
    |> hd()
    |> elem(0)
    |> Map.fetch!(:text)
  end

  defp footer_text(state) do
    TUI.scene(state, %ExRatatui.Frame{width: 120, height: 30})
    |> List.last()
    |> elem(0)
    |> Map.fetch!(:text)
  end

  defp conversation_text(state) do
    TUI.scene(state, %ExRatatui.Frame{width: 120, height: 30})
    |> Enum.find_value(fn
      {%WidgetList{items: items}, _area} ->
        Enum.map_join(items, "\n", fn {%Paragraph{text: text}, _height} -> text end)

      _widget ->
        nil
    end)
  end

  defp inject_key(tui, code) do
    :ok = Runtime.inject_event(tui, %Key{code: code, kind: "press"})
  end
end
