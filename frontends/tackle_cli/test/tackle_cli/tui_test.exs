defmodule Tackle.CLI.TUITest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Key
  alias ExRatatui.Runtime
  alias ExRatatui.Widgets.{Paragraph, TextInput, WidgetList}
  alias Tackle.CLI.TUI
  alias Tackle.Lib.{Event, Message, State}
  alias Tackle.Session.Snapshot

  defmodule SessionStub do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    def child_spec(test_pid) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [test_pid]}, restart: :temporary}
    end

    @impl true
    def init(test_pid) do
      agent_state = State.new(model: "openai-codex/test-model")
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

    def handle_call(:unsubscribe, {subscriber, _tag}, %{subscriber: subscriber} = state) do
      {:reply, :ok, %{state | subscriber: nil}}
    end

    def handle_call(:unsubscribe, _from, state), do: {:reply, :ok, state}
  end

  setup do
    session = start_supervised!({SessionStub, self()})

    tui =
      start_supervised!({TUI, session: session, name: nil, test_mode: {80, 20}})

    assert_receive {:subscribed, ^tui}
    %{session: session, tui: tui}
  end

  test "runs as an ExRatatui.App with session and input state", %{tui: tui} do
    server_state = :sys.get_state(tui)

    assert server_state.user_state.agent_state.model == "openai-codex/test-model"
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
    assert header =~ "ready"

    assert Enum.any?(conversation, fn {%Paragraph{text: text}, _height} ->
             text =~ "Welcome to Tackle"
           end)

    assert footer =~ "Enter send"
    refute footer =~ "CH"
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
    event = Event.new(:message_delta, %{delta: "Hello"})
    send(tui, {:tackle_event, session_id, "turn-1", event})

    streaming_state = :sys.get_state(tui).user_state
    assert streaming_state.streaming_response == "Hello"

    agent_state = %{
      streaming_state.agent_state
      | messages: [Message.user("hi"), Message.assistant(content: "Hello")],
        status: :completed
    }

    send(tui, {:tackle_turn_finished, session_id, "turn-1", {:ok, agent_state}})
    settled_state = :sys.get_state(tui).user_state

    assert settled_state.active_turn == nil
    assert settled_state.pending_prompt == nil
    assert settled_state.streaming_response == ""

    assert [{%WidgetList{items: items}, _area}] =
             TUI.scene(settled_state, %ExRatatui.Frame{width: 80, height: 20})
             |> Enum.filter(fn {widget, _area} ->
               match?(%WidgetList{block: %{title: " Conversation "}}, widget)
             end)

    conversation =
      Enum.map_join(items, "\n", fn {%Paragraph{text: text}, _height} -> text end)

    assert conversation =~ "You:\nhi"
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

    state = %{state | agent_state: %{state.agent_state | messages: messages}}
    conversation = conversation_text(state)

    assert conversation =~ "● read"
    assert conversation =~ ~s("path":"README.md")
    assert conversation =~ "✓ read\n  completed\n  result: project documentation"
    assert conversation =~ "Tackle:\nDone"
  end

  test "auto-follows conversation output beyond the viewport", %{tui: tui} do
    state = :sys.get_state(tui).user_state

    messages =
      Enum.map(1..20, fn index -> Message.user("older message #{index}") end) ++
        [Message.assistant(content: "LATEST-SENTINEL")]

    state = %{state | agent_state: %{state.agent_state | messages: messages}}
    terminal = ExRatatui.init_test_terminal(50, 12)

    :ok =
      ExRatatui.draw(
        terminal,
        TUI.scene(state, %ExRatatui.Frame{width: 50, height: 12})
      )

    content = ExRatatui.get_buffer_content(terminal)
    assert content =~ "LATEST-SENTINEL"
    refute content =~ "older message 1"
  end

  test "measures wide graphemes when wrapping conversation items", %{tui: tui} do
    state = :sys.get_state(tui).user_state

    state = %{
      state
      | agent_state: %{
          state.agent_state
          | messages: [
              Message.user(String.duplicate("界", 8)),
              Message.assistant(content: "LATEST")
            ]
        }
    }

    assert [{%WidgetList{items: [{_user, 3}, {_assistant, 3}]}, _area}] =
             TUI.scene(state, %ExRatatui.Frame{width: 12, height: 10})
             |> Enum.filter(fn {widget, _area} -> match?(%WidgetList{}, widget) end)

    terminal = ExRatatui.init_test_terminal(12, 10)
    :ok = ExRatatui.draw(terminal, TUI.scene(state, %ExRatatui.Frame{width: 12, height: 10}))
    assert ExRatatui.get_buffer_content(terminal) =~ "LATEST"
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
