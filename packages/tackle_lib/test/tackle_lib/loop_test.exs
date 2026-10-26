defmodule Tackle.Lib.LoopTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.LLM.Response
  alias Tackle.Lib.Loop
  alias Tackle.Lib.Message
  alias Tackle.Lib.Messages
  alias Tackle.Lib.State
  alias Tackle.Lib.TestLLM
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Policy
  alias Tackle.Lib.Usage

  defmodule FirstTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "first"

    @impl true
    def description, do: "First ordered test tool."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(_args, %{test_pid: test_pid}) do
      send(test_pid, {:tool_execute, :first})
      {:ok, %{ok: true}}
    end
  end

  defmodule NoCallAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      send(Process.get(:test_pid), :llm_called)
      {:ok, %{data: %{"content" => "should not happen"}, usage: nil, model: "test/model"}}
    end
  end

  defmodule TestAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      {:ok,
       %{
         data: %{"content" => "done"},
         usage: %{prompt_tokens: 5, completion_tokens: 4},
         model: "test/model"
       }}
    end

    @impl true
    def stream(schema, opts, event_callback) do
      event_callback.(%{type: :text_delta, text: "do"})
      event_callback.(%{type: :text_delta, text: "ne"})
      generate(schema, opts)
    end
  end

  # Captures the structured opts[:messages] array so tests can assert that
  # provider context contains only persisted conversation messages.
  defmodule MessagesCapturingAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, opts) do
      send(Process.get(:test_pid), {:messages, Keyword.get(opts, :messages)})

      {:ok,
       %{
         data: %{"content" => "done"},
         usage: nil,
         model: "test/model"
       }}
    end
  end

  # Native tool-calling protocol: the final answer arrives as plain `content`
  # (no JSON envelope), and reasoning as `thinking`.
  defmodule NativeContentAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, opts) do
      send(Process.get(:test_pid), {:llm_opts, opts})

      {:ok,
       %{
         data: %{"content" => "Here is your plain answer.", "thinking" => "reasoned"},
         usage: nil,
         model: "test/model"
       }}
    end
  end

  # Native tool-calling protocol: first turn calls a tool natively, second turn
  # answers with plain content.
  defmodule NativeToolThenContentAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      case Process.get(:call_count, 0) do
        0 ->
          Process.put(:call_count, 1)

          {:ok,
           %{
             data: %{
               "tool_calls" => [%{"id" => "c1", "name" => "first", "arguments" => %{}}]
             },
             usage: nil,
             model: "test/model"
           }}

        _ ->
          {:ok, %{data: %{"content" => "Done after tool."}, usage: nil, model: "test/model"}}
      end
    end
  end

  defmodule TenToolCallsThenContentAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      call_count = Process.get(:call_count, 0)

      if call_count < 10 do
        Process.put(:call_count, call_count + 1)

        {:ok,
         %{
           data: %{
             "tool_calls" => [
               %{"id" => "call_#{call_count}", "name" => "first", "arguments" => %{}}
             ]
           },
           usage: nil,
           model: "test/model"
         }}
      else
        {:ok, %{data: %{"content" => "Done after ten tools."}, usage: nil, model: "test/model"}}
      end
    end
  end

  defmodule PermanentFailureAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      send(Process.get(:test_pid), :retry_call)
      {:error, {:http_error, 401, "unauthorized"}}
    end
  end

  # Captures opts[:messages] (the structured array) on every call, then drives a
  # tool-call turn followed by a content turn so the second call's array carries
  # the assistant tool-call turn and the linked tool result.
  defmodule StructuredMessagesCapturingAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, opts) do
      send(Process.get(:test_pid), {:messages, Keyword.get(opts, :messages)})

      case Process.get(:call_count, 0) do
        0 ->
          Process.put(:call_count, 1)

          {:ok,
           %{
             data: %{
               "content" => "I will inspect this first.",
               "thinking" => "Need the tool.",
               "tool_calls" => [%{"id" => "c1", "name" => "first", "arguments" => %{}}]
             },
             usage: nil,
             model: "test/model",
             provider_state: %{
               "provider" => "test",
               "model" => "test/model",
               "opaque" => "continuation"
             }
           }}

        _ ->
          {:ok, %{data: %{"content" => "All done."}, usage: nil, model: "test/model"}}
      end
    end
  end

  describe "run options" do
    defmodule ContextProbeTool do
      @behaviour Tackle.Lib.Tool

      @impl true
      def name, do: "probe"

      @impl true
      def description, do: "Reports the context it receives."

      @impl true
      def parameters_schema, do: []

      @impl true
      def execute(_args, context) do
        send(context.test_pid, {:tool_context, context})
        context.event_callback.(Event.new(:tool_progress, %{delta: "probing"}))
        {:ok, %{ok: true}}
      end
    end

    defmodule ProbeAdapter do
      @behaviour Tackle.Lib.LLM

      @impl true
      def generate(_schema, opts) do
        if Enum.any?(Keyword.fetch!(opts, :messages), &(&1.role == :tool)) do
          {:ok, %{data: %{"content" => "probed"}, usage: nil, model: "test/model"}}
        else
          {:ok,
           %{
             data: %{"tool_calls" => [%{"id" => "p1", "name" => "probe", "arguments" => %{}}]},
             usage: nil,
             model: "test/model"
           }}
        end
      end
    end

    test "unknown options raise before the turn starts" do
      test_pid = self()
      state = State.new(llm: TestLLM.selection(TestAdapter))
      callback = &send(test_pid, {:event, &1})

      for opts <- [
            [bogus: true],
            [event_context: %{}],
            [cancel_signal: Cancellation.new_signal()],
            [extra_hooks: []]
          ] do
        assert_raise ArgumentError, ~r/unknown keys/, fn ->
          Loop.run(state, "hello", [{:event_callback, callback} | opts])
        end

        assert_raise ArgumentError, ~r/unknown keys/, fn ->
          Loop.continue(state, [{:event_callback, callback} | opts])
        end
      end

      refute_received {:event, _event}
    end

    test "a concurrent tool policy without a tool supervisor raises before the turn starts" do
      Process.put(:test_pid, self())
      test_pid = self()
      callback = &send(test_pid, {:event, &1})

      state =
        State.new(
          llm: TestLLM.selection(NoCallAdapter),
          tools: [FirstTool],
          tool_policy: Policy.concurrent()
        )

      assert_raise ArgumentError, ~r/tool_supervisor/, fn ->
        Loop.run(state, "hello", event_callback: callback)
      end

      assert_raise ArgumentError, ~r/tool_supervisor/, fn ->
        Loop.continue(state, event_callback: callback)
      end

      refute_received {:event, _event}
      refute_received :llm_called
    end

    test "tools receive the run's event callback and tool context without the host repeating them" do
      test_pid = self()
      signal = Cancellation.new_signal()

      state =
        State.new(
          llm: TestLLM.selection(ProbeAdapter),
          tools: [ContextProbeTool],
          context: %{test_pid: test_pid, from_state: true, event_callback: :stale}
        )

      callback = &send(test_pid, {:event, &1})

      assert {:ok, final_state} =
               Loop.run(state, "probe",
                 event_callback: callback,
                 tool_context: %{from_run: true, tool_call_id: "overridden"},
                 cancellation_signal: signal
               )

      assert Tackle.Lib.last_answer(final_state) == "probed"
      assert_receive {:tool_context, context}
      assert context.event_callback == callback
      assert context.from_state
      assert context.from_run
      assert context.tool_call_id == "p1"
      assert context.cancellation_signal == Cancellation.for_call(signal, "p1")
      assert_receive {:event, %Event{type: :tool_progress, data: %{delta: "probing"}}}

      # The run's tool context belongs to tool execution; the state keeps its own.
      refute Map.has_key?(final_state.context, :from_run)
      assert final_state.context.event_callback == :stale
    end
  end

  test "sends only persisted messages to the provider" do
    Process.put(:test_pid, self())

    state = State.new(llm: TestLLM.selection(MessagesCapturingAdapter))

    assert {:ok, _state} = Loop.run(state, "hello")

    assert_receive {:messages, [%{role: :user, content: "hello"}]}
  end

  test "native protocol: plain content is treated as the final answer" do
    Process.put(:test_pid, self())
    Process.put(:call_count, 0)

    state = State.new(llm: TestLLM.selection(NativeContentAdapter))

    assert {:ok, state} = Loop.run(state, "hello")
    assert state.status == :completed

    last = List.last(state.messages)
    assert last.role == :assistant
    assert last.content == "Here is your plain answer."
    assert last.thinking == "reasoned"
  end

  defmodule JsonArgumentsAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      case Process.get(:call_count, 0) do
        0 ->
          Process.put(:call_count, 1)

          {:ok,
           %{
             data: %{
               "tool_calls" => [
                 %{
                   "id" => "c1",
                   "function" => %{"name" => "first", "arguments" => ~s({"query":"hi"})}
                 }
               ]
             },
             usage: nil,
             model: "test/model"
           }}

        _ ->
          {:ok, %{data: %{"content" => "done"}, usage: nil, model: "test/model"}}
      end
    end
  end

  defmodule MalformedToolAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      {:ok,
       %{
         data: %{"tool_calls" => Process.get(:bad_tool_calls)},
         usage: nil,
         model: "test/model"
       }}
    end
  end

  test "rejects malformed provider tool calls without crashing the loop" do
    for calls <- [[nil], [%{"function" => "not a map"}], [%{"arguments" => %{}}]] do
      Process.put(:bad_tool_calls, calls)

      assert {:error, state} =
               Loop.run(
                 State.new(
                   llm: TestLLM.selection(MalformedToolAdapter),
                   tools: [FirstTool],
                   context: %{test_pid: self()}
                 ),
                 "hello"
               )

      assert state.status == :error
      assert state.error =~ "Invalid provider tool calls"
      refute_receive {:tool_execute, :first}
    end
  end

  # Answers with the calls in `:bad_tool_calls` first, then reports the
  # provider messages of the next request and answers "done".
  defmodule BadArgumentsAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, opts) do
      case Process.get(:bad_tool_calls) do
        nil ->
          send(Process.get(:test_pid), {:messages, Keyword.fetch!(opts, :messages)})
          {:ok, %{data: %{"content" => "done"}, usage: nil, model: "test/model"}}

        calls ->
          Process.delete(:bad_tool_calls)
          {:ok, %{data: %{"tool_calls" => calls}, usage: nil, model: "test/model"}}
      end
    end
  end

  test "settles calls with unusable arguments as tool errors the model sees and continues" do
    Process.put(:test_pid, self())

    Process.put(:bad_tool_calls, [
      %{"id" => "ok", "name" => "first", "arguments" => %{}},
      %{"id" => "bad_json", "name" => "first", "arguments" => "{"},
      %{"id" => "not_object", "name" => "first", "arguments" => "[]"},
      %{"id" => "list", "name" => "first", "arguments" => [1]},
      %{"id" => "empty", "name" => "first", "arguments" => ""}
    ])

    assert {:ok, state} =
             Loop.run(
               State.new(
                 llm: TestLLM.selection(BadArgumentsAdapter),
                 tools: [FirstTool],
                 context: %{test_pid: self()}
               ),
               "hello"
             )

    assert state.status == :completed

    # Only the calls with usable arguments ran: "ok" and "empty" ("" is no arguments).
    assert_received {:tool_execute, :first}
    assert_received {:tool_execute, :first}
    refute_received {:tool_execute, :first}

    results =
      for %Message{role: :tool, tool_call_id: id, content: content} <- state.messages,
          do: {id, content}

    assert [
             {"ok", ~s({"ok":true})},
             {"bad_json", "Error: Invalid tool arguments: arguments are not valid JSON"},
             {"not_object", "Error: Invalid tool arguments: arguments must be a JSON object"},
             {"list", "Error: Invalid tool arguments: arguments must be a JSON object"},
             {"empty", ~s({"ok":true})}
           ] = results

    # The next request carries every call with its result.
    assert_received {:messages, messages}

    assert [%{role: :assistant, tool_calls: calls} | tool_results] = Enum.drop(messages, 1)
    assert Enum.map(calls, & &1.id) == ["ok", "bad_json", "not_object", "list", "empty"]
    assert Enum.map(tool_results, & &1.tool_call_id) == Enum.map(calls, & &1.id)
  end

  test "executes a nested call with decoded JSON arguments" do
    Process.put(:call_count, 0)

    state =
      State.new(
        llm: TestLLM.selection(JsonArgumentsAdapter),
        tools: [FirstTool],
        context: %{test_pid: self()}
      )

    assert {:ok, state} = Loop.run(state, "hello")
    assert_receive {:tool_execute, :first}
    assert state.status == :completed

    assert Enum.any?(state.messages, fn
             %{tool_calls: [%Call{arguments: %{"query" => "hi"}}]} -> true
             _ -> false
           end)
  end

  test "normalizes provider calls with nested function, atom keys and JSON arguments" do
    raw = %{
      id: "call-1",
      function: %{"name" => "first", "arguments" => ~s({"query":"hi"})}
    }

    assert {:ok,
            %Call{
              id: "call-1",
              name: "first",
              arguments: %{"query" => "hi"},
              raw: ^raw
            }} = Call.normalize(raw)

    assert {:ok, %Call{arguments: %{}}} = Call.normalize(%{"name" => "first"})
    assert {:error, :malformed_tool_call} = Call.normalize(%{"arguments" => %{}})

    assert {:ok, %Call{name: "first", arguments: %{}, argument_error: :invalid_json}} =
             Call.normalize(%{"name" => "first", "arguments" => "{"})

    assert {:ok, %Call{name: "first", arguments: %{}, argument_error: :not_an_object}} =
             Call.normalize(%{"name" => "first", "arguments" => "[]"})

    assert {:ok, %Call{arguments: %{}, argument_error: nil}} =
             Call.normalize(%{"name" => "first", "arguments" => " "})

    assert {:ok, %Call{arguments: %{"query" => "hi"}}} =
             Call.normalize(%{"name" => "first", "arguments" => %{"query" => "hi"}})
  end

  test "native protocol: native tool_calls drive tool execution then plain-content answer" do
    Process.put(:test_pid, self())
    Process.put(:call_count, 0)

    test_pid = self()

    state =
      State.new(
        llm: TestLLM.selection(NativeToolThenContentAdapter),
        tools: [FirstTool],
        context: %{test_pid: test_pid}
      )

    assert {:ok, state} = Loop.run(state, "do the thing")
    assert_receive {:tool_execute, :first}
    assert state.status == :completed
    assert List.last(state.messages).content == "Done after tool."
  end

  test "runs beyond ten iterations when no explicit limit is configured" do
    Process.put(:call_count, 0)

    state =
      State.new(
        llm: TestLLM.selection(TenToolCallsThenContentAdapter),
        tools: [FirstTool],
        context: %{test_pid: self()}
      )

    assert {:ok, state} = Loop.run(state, "keep using the tool")
    assert state.max_iterations == :infinity
    assert state.current_iteration == 11
    assert List.last(state.messages).content == "Done after ten tools."
  end

  test "max_iterations bounds each turn, not the whole session" do
    state = State.new(llm: TestLLM.selection(TestAdapter), max_iterations: 1)

    assert {:ok, state} = Loop.run(state, "first")
    assert state.current_iteration == 1

    assert {:ok, state} = Loop.run(state, "second")
    assert state.current_iteration == 1
    assert state.status == :completed
    assert Enum.map(state.messages, & &1.role) == [:user, :assistant, :user, :assistant]
  end

  test "a successful turn after a failed one does not keep the old error" do
    Process.put(:test_pid, self())

    assert {:error, state} =
             Loop.run(State.new(llm: TestLLM.selection(PermanentFailureAdapter)), "first")

    assert state.error =~ "Failed to get response"

    state = %{state | llm: TestLLM.selection(TestAdapter)}

    assert {:ok, state} = Loop.run(state, "second")
    assert state.status == :completed
    assert state.error == nil
  end

  test "passes a structured message array (not a flat blob) with linked tool call/result" do
    Process.put(:test_pid, self())
    Process.put(:call_count, 0)

    test_pid = self()

    state =
      State.new(
        llm: TestLLM.selection(StructuredMessagesCapturingAdapter),
        tools: [FirstTool],
        context: %{test_pid: test_pid}
      )

    assert {:ok, state} = Loop.run(state, "do the thing")

    # The first request contains only the persisted user turn.
    assert_receive {:messages, first_messages}
    assert [%{role: :user, content: "do the thing"}] = first_messages

    # The second request extends that exact prefix with the assistant tool call
    # and linked result. No synthetic instruction is inserted between them.
    assert_receive {:messages, second_messages}
    assert Enum.take(second_messages, Enum.count(first_messages)) == first_messages
    assert [_, _, _] = second_messages

    assistant_call =
      Enum.find(second_messages, fn m ->
        m.role == :assistant and is_list(m[:tool_calls]) and m[:tool_calls] != []
      end)

    assert assistant_call, "expected a structured assistant tool-call turn"
    assert assistant_call.content == "I will inspect this first."

    persisted_call = Enum.find(state.messages, &Message.has_tool_calls?/1)
    assert persisted_call.content == "I will inspect this first."
    assert persisted_call.thinking == "Need the tool."

    assert [%{id: call_id, type: "function", function: %{name: "first"}}] =
             assistant_call.tool_calls

    assert assistant_call.provider_state == %{
             "provider" => "test",
             "model" => "test/model",
             "opaque" => "continuation"
           }

    tool_result = Enum.find(second_messages, &(&1.role == :tool))
    assert tool_result, "expected a structured tool-result message"
    assert tool_result.tool_call_id == call_id
    assert tool_result.name == "first"
  end

  test "emits Tackle.Lib events" do
    test_pid = self()
    state = State.new(llm: TestLLM.selection(TestAdapter))

    assert {:ok, state} =
             Loop.run(state, "hello",
               event_callback: fn event -> send(test_pid, {:event, event}) end
             )

    assert state.status == :completed

    assert_receive {:event, %Event{type: :turn_start}}
    assert_receive {:event, %Event{type: :message_end, data: %{role: :user}}}
    assert_receive {:event, %Event{type: :step_start, data: %{iteration: 1}}}

    assert_receive {:event,
                    %Event{
                      type: :usage,
                      data: %{usage: %Usage{input_tokens: 5, output_tokens: 4}}
                    }}

    assert_receive {:event, %Event{type: :step_end}}
    assert_receive {:event, %Event{type: :message_end, data: %{role: :assistant}}}
    assert_receive {:event, %Event{type: :status_change, data: %{status: :completed}}}
    assert_receive {:event, %Event{type: :turn_end, data: %{status: :completed}}}
  end

  test "host llm_opts override the loop's defaults but not the request" do
    Process.put(:test_pid, self())

    state =
      State.new(
        llm: TestLLM.selection(NativeContentAdapter),
        llm_opts: [temperature: 0.9, model: "other/model", messages: [:bogus]]
      )

    assert {:ok, _state} = Loop.run(state, "hello")

    assert_receive {:llm_opts, opts}
    assert Keyword.get_values(opts, :temperature) == [0.9]
    assert Keyword.get_values(opts, :model) == ["test/model"]
    assert [[%{role: :user, content: "hello"}]] = Keyword.get_values(opts, :messages)
  end

  test "appends incoming messages before the first provider call" do
    Process.put(:test_pid, self())
    Process.put(:incoming_polls, 0)

    callback = fn ->
      polls = Process.get(:incoming_polls, 0)
      Process.put(:incoming_polls, polls + 1)
      if polls == 0, do: {:ok, ["queued first"]}, else: {:ok, []}
    end

    assert {:ok, state} =
             Loop.run(State.new(llm: TestLLM.selection(MessagesCapturingAdapter)), "hello",
               take_incoming_messages: callback
             )

    assert_receive {:messages,
                    [%{role: :user, content: "hello"}, %{role: :user, content: "queued first"}]}

    assert Enum.map(state.messages, &{&1.role, &1.content}) == [
             {:user, "hello"},
             {:user, "queued first"},
             {:assistant, "done"}
           ]
  end

  test "appends incoming messages only after a complete tool batch" do
    Process.put(:test_pid, self())
    Process.put(:call_count, 0)
    Process.put(:incoming_polls, 0)

    callback = fn ->
      polls = Process.get(:incoming_polls, 0)
      Process.put(:incoming_polls, polls + 1)
      if polls == 1, do: {:ok, ["after tools"]}, else: {:ok, []}
    end

    state =
      State.new(
        llm: TestLLM.selection(StructuredMessagesCapturingAdapter),
        tools: [FirstTool],
        context: %{test_pid: self()}
      )

    assert {:ok, _state} = Loop.run(state, "hello", take_incoming_messages: callback)

    assert_receive {:messages, [%{role: :user, content: "hello"}]}
    assert_receive {:tool_execute, :first}
    assert_receive {:messages, messages}
    assert Enum.map(messages, & &1.role) == [:user, :assistant, :tool, :user]
    assert List.last(messages).content == "after tools"
  end

  test "continues the same run when a message arrives at the final response boundary" do
    Process.put(:test_pid, self())
    Process.put(:incoming_polls, 0)

    callback = fn ->
      polls = Process.get(:incoming_polls, 0)
      Process.put(:incoming_polls, polls + 1)
      if polls == 1, do: {:ok, ["follow up"]}, else: {:ok, []}
    end

    assert {:ok, state} =
             Loop.run(State.new(llm: TestLLM.selection(MessagesCapturingAdapter)), "hello",
               take_incoming_messages: callback
             )

    assert_receive {:messages, [%{role: :user, content: "hello"}]}
    assert_receive {:messages, messages}
    assert Enum.map(messages, & &1.role) == [:user, :assistant, :user]
    assert List.last(messages).content == "follow up"
    assert state.current_iteration == 2
  end

  test "reports invalid incoming callback results" do
    Process.put(:test_pid, self())

    assert {:error, state} =
             Loop.run(State.new(llm: TestLLM.selection(NoCallAdapter)), "hello",
               take_incoming_messages: fn -> {:ok, [""]} end
             )

    assert state.status == :error
    assert state.error =~ "invalid_incoming_messages"
    refute_receive :llm_called, 20
  end

  test "does not consume incoming messages after cancellation" do
    Process.put(:test_pid, self())
    signal = Cancellation.new_signal()
    Cancellation.cancel(signal, "stop")

    assert {:cancelled, state} =
             Loop.run(State.new(llm: TestLLM.selection(NoCallAdapter)), "hello",
               cancellation_signal: signal,
               take_incoming_messages: fn ->
                 send(self(), :incoming_polled)
                 {:ok, ["late"]}
               end
             )

    assert Enum.map(state.messages, & &1.content) == []
    refute_receive :incoming_polled, 20
    refute_receive :llm_called, 20
  end

  test "cancels before starting the LLM call" do
    Process.put(:test_pid, self())

    signal = Cancellation.new_signal()
    Cancellation.cancel(signal, "user stopped")

    state = State.new(llm: TestLLM.selection(NoCallAdapter))

    assert {:cancelled, state} =
             Loop.run(state, "hello",
               cancellation_signal: signal,
               event_callback: fn event -> send(self(), {:event, event}) end
             )

    assert state.status == :cancelled
    assert state.error == "user stopped"

    assert_receive {:event, %Event{type: :turn_start}}
    assert_receive {:event, %Event{type: :status_change, data: %{status: :cancelled}}}
    assert_receive {:event, %Event{type: :turn_cancelled, data: %{reason: "user stopped"}}}
    assert_receive {:event, %Event{type: :turn_end, data: %{status: :cancelled}}}
    refute_receive :llm_called, 20
  end

  describe "turn end" do
    defmodule TurnEndHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def before_prompt(_state, %{crash: :before_prompt}), do: raise("prompt hook bug")
      def before_prompt(_state, %{abort: :before_prompt}), do: {:error, :nope}
      def before_prompt(_state, _context), do: :ok

      @impl true
      def after_message(_state, %Message{role: :assistant, tool_calls: [_ | _]}, %{
            fail: :tool_call_message
          }),
          do: {:error, :journal_stalled}

      def after_message(_state, %Message{role: :user, content: "queued a"}, %{
            fail: :queued_message
          }),
          do: {:error, :journal_stalled}

      def after_message(_state, _message, _context), do: :ok

      @impl true
      def before_turn_end(_state, %{crash: :before_turn_end}), do: exit(:gate_down)
      def before_turn_end(_state, _context), do: :ok
    end

    defmodule FirstCallsToolThenAnswersAdapter do
      @behaviour Tackle.Lib.LLM

      @impl true
      def generate(_schema, opts) do
        messages = Keyword.fetch!(opts, :messages)
        send(Process.get(:test_pid), {:provider_messages, messages})

        if Enum.any?(messages, &(&1.role == :tool)) do
          {:ok, %{data: %{"content" => "answered"}, usage: nil, model: "test/model"}}
        else
          {:ok,
           %{
             data: %{"tool_calls" => [%{"id" => "c1", "name" => "first", "arguments" => %{}}]},
             usage: nil,
             model: "test/model"
           }}
        end
      end
    end

    setup do
      Process.put(:test_pid, self())
      :ok
    end

    defp turn_end_hook_state(context, adapter \\ FirstCallsToolThenAnswersAdapter) do
      State.new(
        llm: TestLLM.selection(adapter),
        tools: [FirstTool],
        hooks: [TurnEndHook],
        context: Map.put(context, :test_pid, self())
      )
    end

    defp run_collecting(state, input, opts \\ []) do
      test_pid = self()
      opts = Keyword.put(opts, :event_callback, &send(test_pid, {:event, &1}))
      result = Loop.run(state, input, opts)
      {result, collect_events([])}
    end

    test "tool calls are settled when finalizing their assistant message fails" do
      state = turn_end_hook_state(%{fail: :tool_call_message})

      {{:error, state}, events} = run_collecting(state, "use the tool")

      assert state.error =~ "Hook aborted after message: :journal_stalled"
      assert Messages.unresolved_tool_calls(state.messages) == []
      assert %Message{role: :tool, tool_call_id: "c1"} = List.last(state.messages)
      assert List.last(state.messages).content =~ "aborted"
      refute_received {:tool_execute, :first}

      assert [:tool_error, :error, :status_change, :turn_end] =
               events |> Enum.map(& &1.type) |> Enum.take(-4)
    end

    test "a turn starting from unresolved tool calls settles them before the provider call" do
      state = %{
        State.new(
          llm: TestLLM.selection(FirstCallsToolThenAnswersAdapter),
          tools: [FirstTool],
          context: %{test_pid: self()}
        )
        | messages: [
            Message.user("earlier"),
            Message.assistant(tool_calls: [%Call{id: "old", name: "first", arguments: %{}}])
          ]
      }

      for start <- [&Loop.run(&1, "again"), &Loop.continue/1] do
        assert {:ok, final_state} = start.(state)
        assert_receive {:provider_messages, messages}

        assert [_user, _assistant, %{role: :tool, tool_call_id: "old", content: content} | _] =
                 messages

        assert content =~ "interrupted"
        assert Messages.unresolved_tool_calls(final_state.messages) == []
      end
    end

    test "continue/2 starts a turn like run/3" do
      test_pid = self()

      state = %{
        State.new(llm: TestLLM.selection(TestAdapter))
        | messages: [Message.user("hello")]
      }

      assert {:ok, _state} =
               Loop.continue(state, event_callback: &send(test_pid, {:event, &1}))

      assert [%Event{type: :turn_start} | _] = collect_events([])
    end

    test "an error before the provider call leaves no assistant message" do
      state = turn_end_hook_state(%{abort: :before_prompt})

      {{:error, state}, events} = run_collecting(state, "hello")

      assert Enum.map(state.messages, & &1.role) == [:user]
      assert state.error_reason == :nope

      assert %Event{type: :error, data: %{reason: :nope}} =
               Enum.find(events, &(&1.type == :error))
    end

    test "a crashing hook ends the turn with an error instead of crashing the loop" do
      for {crash, message} <- [
            before_prompt: "prompt hook bug",
            before_turn_end: "(exit) :gate_down"
          ] do
        assert {:error, state} = Loop.run(turn_end_hook_state(%{crash: crash}), "hello")
        assert state.error =~ "TurnEndHook.#{crash}/"
        assert state.error =~ "crashed"
        assert state.error =~ message
      end
    end

    test "a crashing event callback does not stop the turn" do
      assert {:ok, state} =
               Loop.run(State.new(llm: TestLLM.selection(TestAdapter)), "hello",
                 event_callback: fn _event -> raise "observer bug" end
               )

      assert Tackle.Lib.last_answer(state) == "done"
    end

    test "queued messages are kept when finalizing one of them fails" do
      state = turn_end_hook_state(%{fail: :queued_message}, TestAdapter)

      assert {:error, state} =
               Loop.run(state, "hello",
                 take_incoming_messages: fn -> {:ok, ["queued a", "queued b"]} end
               )

      assert state.error == "Hook aborted after message: :journal_stalled"
      assert state.error_reason == :journal_stalled

      assert Enum.map(state.messages, & &1.content) == ["hello", "queued a", "queued b"]
    end
  end

  describe "hook integration" do
    defmodule HookLoggingTool do
      @behaviour Tackle.Lib.Tool

      @impl true
      def name, do: "hook_log"

      @impl true
      def description, do: "Logs hook calls."

      @impl true
      def parameters_schema, do: []

      @impl true
      def execute(_args, %{test_pid: test_pid}) do
        send(test_pid, {:hook_test, :tool_executed})
        {:ok, %{ok: true}}
      end
    end

    defmodule HookTestAdapter do
      @behaviour Tackle.Lib.LLM

      @impl true
      def generate(_schema, _opts) do
        Process.put(:llm_call_count, Process.get(:llm_call_count, 0) + 1)

        if Process.get(:llm_call_count, 0) == 1 do
          {:ok,
           %{
             data: %{
               "thinking" => "need tools",
               "tool_calls" => [
                 %{"id" => "call_hook", "name" => "hook_log", "arguments" => %{}}
               ]
             },
             usage: nil,
             model: "test/model"
           }}
        else
          {:ok,
           %{
             data: %{"thinking" => "done", "content" => "All done"},
             usage: nil,
             model: "test/model"
           }}
        end
      end
    end

    defmodule IntegObserverHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def before_prompt(_state, context) do
        send(Map.get(context, :test_pid, self()), {:hook_fired, :before_prompt})
        :ok
      end

      @impl true
      def after_prompt(_state, %Response{}, context) do
        send(Map.get(context, :test_pid, self()), {:hook_fired, :after_prompt})
        :ok
      end

      @impl true
      def before_tool_call(_state, _call, context) do
        send(Map.get(context, :test_pid, self()), {:hook_fired, :before_tool_call})
        :ok
      end

      @impl true
      def after_tool_call(_state, _result, context) do
        send(Map.get(context, :test_pid, self()), {:hook_fired, :after_tool_call})
        :ok
      end

      @impl true
      def after_turn(_state, context) do
        send(Map.get(context, :test_pid, self()), {:hook_fired, :after_turn})
        :ok
      end
    end

    defmodule TerminalHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def before_prompt(_state, %{abort_prompt: true}), do: {:error, :prompt_rejected}
      def before_prompt(_state, _context), do: :ok

      @impl true
      def after_turn(state, context) do
        send(context.test_pid, {:after_turn, state.status, state.error})
        send(context.test_pid, {:terminal_event, :after_turn})
        {:ok, Map.put(context, :cleaned_up, true)}
      end
    end

    defmodule FailingTerminalHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def after_turn(state, context) do
        send(context.test_pid, {:after_turn_failed, state.status})
        {:error, :teardown_failed}
      end
    end

    test "terminal cleanup runs once after outcome events for success, cancellation, hook and provider failures" do
      signal = Cancellation.new_signal()
      Cancellation.cancel(signal, "stop")

      cases = [
        {:completed, TestAdapter, %{}, []},
        {:cancelled, NoCallAdapter, %{}, [cancellation_signal: signal]},
        {:error, NoCallAdapter, %{abort_prompt: true}, []},
        {:error, PermanentFailureAdapter, %{}, []}
      ]

      for {status, adapter, extra_context, opts} <- cases do
        Process.put(:test_pid, self())

        context = Map.merge(%{test_pid: self()}, extra_context)

        state =
          State.new(llm: TestLLM.selection(adapter), hooks: [TerminalHook], context: context)

        result =
          Loop.run(
            state,
            "hello",
            Keyword.merge(opts,
              event_callback: fn event -> send(self(), {:event, event.type}) end
            )
          )

        outcome = if status == :completed, do: :ok, else: status
        assert {^outcome, final_state} = result
        assert final_state.status == status
        assert final_state.context.cleaned_up

        assert_receive {:after_turn, ^status, error}
        assert (status == :completed and error == nil) or is_binary(error)
        refute_receive {:after_turn, _, _}, 20

        events = collect_terminal_event_types([])
        assert Enum.count(events, &(&1 == :after_turn)) == 1
        assert List.last(events) == :after_turn

        if status == :completed do
          assert Enum.take(events, -2) == [:turn_end, :after_turn]
        else
          if status == :cancelled do
            assert Enum.take(events, -4) ==
                     [:status_change, :turn_cancelled, :turn_end, :after_turn]
          else
            assert :step_start in events
            assert Enum.take(events, -4) == [:error, :status_change, :turn_end, :after_turn]
          end
        end
      end
    end

    test "after_turn failure preserves the outcome" do
      state =
        State.new(
          llm: TestLLM.selection(TestAdapter),
          hooks: [FailingTerminalHook],
          context: %{test_pid: self()}
        )

      assert {:ok, final_state} = Loop.run(state, "hello")
      assert_receive {:after_turn_failed, :completed}
      refute_receive {:after_turn_failed, _}, 20
      assert final_state.context == state.context
    end

    test "continue runs terminal cleanup once" do
      state =
        State.new(
          llm: TestLLM.selection(TestAdapter),
          hooks: [TerminalHook],
          context: %{test_pid: self()}
        )

      assert {:ok, final_state} = Loop.continue(state)
      assert final_state.context.cleaned_up
      assert_receive {:after_turn, :completed, nil}
      refute_receive {:after_turn, _, _}, 20
    end

    defmodule ContextMutatorHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def before_prompt(_state, context) do
        {:ok, Map.put(context, :hook_marker, "mutated_before_prompt")}
      end

      @impl true
      def after_tool_call(_state, _result, context) do
        {:ok, Map.put(context, :hook_marker, "mutated_after_tool")}
      end
    end

    defmodule SettlementOrderHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def after_message(_state, %Message{role: :tool}, context) do
        send(context.test_pid, {:settlement_stage, :after_message})
        :ok
      end

      def after_message(_state, _message, _context), do: :ok

      @impl true
      def after_tool_call(_state, settlement, context) do
        send(context.test_pid, {:settlement_stage, :after_tool_call})
        send(context.test_pid, {:settlement_result, settlement})
        :ok
      end
    end

    defmodule AfterToolMessageAbortHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def after_message(_state, %Message{role: :tool}, _context), do: {:error, :message_failed}
      def after_message(_state, _message, _context), do: :ok
    end

    defmodule AfterToolAbortHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def after_tool_call(_state, _result, _context) do
        {:error, :after_tool_failed}
      end
    end

    test "lifecycle hooks fire in correct order during a turn" do
      Process.put(:llm_call_count, 0)

      state =
        State.new(
          llm: TestLLM.selection(HookTestAdapter),
          tools: [HookLoggingTool],
          hooks: [IntegObserverHook],
          context: %{test_pid: self()}
        )

      assert {:ok, state} = Loop.run(state, "test hooks")
      assert state.status == :completed

      # before_prompt fires at least once (once per LLM call)
      assert_receive {:hook_fired, :before_prompt}
      # after_prompt fires after each LLM response
      assert_receive {:hook_fired, :after_prompt}
      # before_tool_call fires when the tool is dispatched
      assert_receive {:hook_fired, :before_tool_call}
      # after_tool_call fires after the tool settles
      assert_receive {:hook_fired, :after_tool_call}
      # after_turn fires at the very end, once for the whole multi-step turn
      assert_receive {:hook_fired, :after_turn}
      refute_receive {:hook_fired, :after_turn}, 20
    end

    test "context mutator hooks propagate context changes" do
      state =
        State.new(
          llm: TestLLM.selection(TestAdapter),
          hooks: [ContextMutatorHook],
          context: %{original: true}
        )

      assert {:ok, state} = Loop.run(state, "test mutator")
      assert state.status == :completed
      # The before_prompt hook mutated the context, and it survives the turn
      assert state.context.hook_marker == "mutated_before_prompt"
    end

    test "snapshot is captured and used for tool registry resolution" do
      state =
        State.new(
          llm: TestLLM.selection(TestAdapter),
          tools: [FirstTool],
          context: %{}
        )

      assert {:ok, state} = Loop.run(state, "hello")
      assert state.status == :completed
    end

    test "successful and failed tool settlements share message, event, and hook ordering" do
      for {tools, event_type, settlement_type} <- [
            {[HookLoggingTool], :tool_end, Tackle.Lib.Tool.Result},
            {[], :tool_error, Tackle.Lib.Tool.Error}
          ] do
        Process.put(:llm_call_count, 0)

        state =
          State.new(
            llm: TestLLM.selection(HookTestAdapter),
            tools: tools,
            hooks: [SettlementOrderHook],
            context: %{test_pid: self()}
          )

        assert {:ok, _state} =
                 Loop.run(state, "test settlement order",
                   event_callback: fn
                     %Event{type: :message_end, data: %{role: :tool}} ->
                       send(self(), {:settlement_stage, :message_end})

                     %Event{type: ^event_type} ->
                       send(self(), {:settlement_stage, event_type})

                     _event ->
                       :ok
                   end
                 )

        stages =
          for _ <- 1..4 do
            assert_receive {:settlement_stage, stage}
            stage
          end

        assert stages == [:message_end, :after_message, event_type, :after_tool_call]
        assert_receive {:settlement_result, settlement}
        assert is_struct(settlement, settlement_type)
      end
    end

    test "after_tool_call hook errors abort the turn" do
      Process.put(:llm_call_count, 0)

      state =
        State.new(
          llm: TestLLM.selection(HookTestAdapter),
          tools: [HookLoggingTool],
          hooks: [AfterToolAbortHook],
          context: %{test_pid: self()}
        )

      assert {:error, state} = Loop.run(state, "test abort")
      assert state.status == :error
      assert state.error =~ "Hook aborted after tool call"
      assert state.error_reason == :after_tool_failed
    end

    test "after_message aborts both tool settlements before their event and after_tool_call" do
      for {tools, event_type} <- [
            {[HookLoggingTool], :tool_end},
            {[], :tool_error}
          ] do
        Process.put(:llm_call_count, 0)

        state =
          State.new(
            llm: TestLLM.selection(HookTestAdapter),
            tools: tools,
            hooks: [AfterToolMessageAbortHook, SettlementOrderHook],
            context: %{test_pid: self()}
          )

        assert {:error, state} =
                 Loop.run(state, "test message abort",
                   event_callback: fn event -> send(self(), {:event, event}) end
                 )

        assert state.error =~ "Hook aborted after message: :message_failed"
        assert_receive {:event, %Event{type: :message_end, data: %{role: :tool}}}
        refute_receive {:event, %Event{type: ^event_type}}, 20
        refute_receive {:settlement_stage, :after_tool_call}, 20
      end
    end

    test "after_tool_call hook errors abort failed tool settlements too" do
      Process.put(:llm_call_count, 0)

      state =
        State.new(
          llm: TestLLM.selection(HookTestAdapter),
          hooks: [AfterToolAbortHook],
          context: %{test_pid: self()}
        )

      assert {:error, state} =
               Loop.run(state, "test error settlement abort",
                 event_callback: fn event -> send(self(), {:event, event}) end
               )

      assert state.status == :error
      assert state.error =~ "Hook aborted after tool call: :after_tool_failed"
      assert Enum.any?(state.messages, &(&1.role == :tool))
      assert_receive {:event, %Event{type: :tool_error, data: %{name: "hook_log"}}}
    end
  end

  describe "before_turn_end hooks" do
    # Answers `before_turn_end` from `context.gate_plan`: a list of results
    # consumed one per call (`:ok` when empty), or `:always` to keep continuing.
    defmodule GateHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def before_turn_end(state, context) do
        last = List.last(state.messages)
        send(context.test_pid, {:before_turn_end, last.role, last.content})

        case context.gate_plan do
          :always -> {:continue, ["still failing"]}
          [] -> :ok
          [next | rest] -> respond(next, Map.put(context, :gate_plan, rest))
        end
      end

      @impl true
      def after_turn(_state, context) do
        send(context.test_pid, {:gate_after_turn, context.gate_plan})
        :ok
      end

      defp respond(:cancel, context) do
        Cancellation.cancel(context.signal, "stop")
        {:continue, ["too late"], context}
      end

      defp respond({:continue, messages}, context), do: {:continue, messages, context}
      defp respond(other, _context), do: other
    end

    defmodule SecondGateHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def before_turn_end(_state, context) do
        send(context.test_pid, {:second_gate, context.gate_plan})
        {:continue, ["format check failed"]}
      end
    end

    defp turn_end_state(plan, opts \\ []) do
      context = Map.merge(%{test_pid: self(), gate_plan: plan}, Keyword.get(opts, :context, %{}))

      State.new(
        llm: TestLLM.selection(Keyword.get(opts, :adapter, MessagesCapturingAdapter)),
        hooks: Keyword.get(opts, :hooks, [GateHook]),
        tools: Keyword.get(opts, :tools, []),
        max_iterations: Keyword.get(opts, :max_iterations, :infinity),
        context: context
      )
    end

    test "continues the turn with the hook's messages, then completes" do
      Process.put(:test_pid, self())

      state = turn_end_state([{:continue, ["compile failed: undefined function foo/0"]}])

      assert {:ok, state} =
               Loop.run(state, "hello",
                 event_callback: fn event -> send(self(), {:event, event.type}) end
               )

      assert state.status == :completed
      assert state.current_iteration == 2

      assert Enum.map(state.messages, &{&1.role, &1.content}) == [
               {:user, "hello"},
               {:assistant, "done"},
               {:user, "compile failed: undefined function foo/0"},
               {:assistant, "done"}
             ]

      assert_receive {:messages, [%{content: "hello"}]}
      assert_receive {:messages, second_call}
      assert List.last(second_call).content == "compile failed: undefined function foo/0"

      assert_receive {:before_turn_end, :assistant, "done"}
      assert_receive {:before_turn_end, :assistant, "done"}
      refute_receive {:before_turn_end, _, _}, 20

      # The context returned with the messages is kept for later steps.
      assert state.context.gate_plan == []
      assert_receive {:gate_after_turn, []}

      events = collect_terminal_event_types([])
      assert Enum.count(events, &(&1 == :turn_end)) == 1
      assert Enum.take(events, -2) == [:status_change, :turn_end]
    end

    test "completes the turn when the hook returns no messages" do
      Process.put(:test_pid, self())

      assert {:ok, state} = Loop.run(turn_end_state([{:continue, []}]), "hello")
      assert state.status == :completed
      assert state.current_iteration == 1
      assert_receive {:before_turn_end, :assistant, "done"}
      refute_receive {:before_turn_end, _, _}, 20
    end

    test "runs only after a final answer, not after a tool batch" do
      Process.put(:test_pid, self())
      Process.put(:call_count, 0)

      state =
        turn_end_state([], tools: [FirstTool], adapter: StructuredMessagesCapturingAdapter)

      assert {:ok, _state} = Loop.run(state, "hello")
      assert_receive {:tool_execute, :first}
      assert_receive {:before_turn_end, :assistant, "All done."}
      refute_receive {:before_turn_end, _, _}, 20
    end

    test "queued incoming messages are handled before the hooks run" do
      Process.put(:test_pid, self())
      Process.put(:incoming_polls, 0)

      callback = fn ->
        polls = Process.get(:incoming_polls, 0)
        Process.put(:incoming_polls, polls + 1)
        if polls == 1, do: {:ok, ["follow up"]}, else: {:ok, []}
      end

      assert {:ok, state} =
               Loop.run(turn_end_state([]), "hello", take_incoming_messages: callback)

      assert state.current_iteration == 2
      assert_receive {:before_turn_end, :assistant, "done"}
      refute_receive {:before_turn_end, _, _}, 20
    end

    test "messages of several hooks are appended in hook order" do
      Process.put(:test_pid, self())

      # SecondGateHook always continues, so the iteration limit ends the turn.
      state =
        turn_end_state([{:continue, ["compile failed"]}],
          hooks: [GateHook, SecondGateHook],
          max_iterations: 2
        )

      assert {:error, state} = Loop.run(state, "hello")

      # SecondGateHook sees the context returned by GateHook.
      assert_receive {:second_gate, []}

      assert Enum.map(Enum.take(state.messages, 4), &{&1.role, &1.content}) == [
               {:user, "hello"},
               {:assistant, "done"},
               {:user, "compile failed"},
               {:user, "format check failed"}
             ]
    end

    test "max_iterations ends a turn whose hook keeps continuing it" do
      Process.put(:test_pid, self())

      assert {:error, state} = Loop.run(turn_end_state(:always, max_iterations: 3), "hello")
      assert state.status == :error
      assert state.error =~ "maximum iterations"
      assert state.current_iteration == 3
      assert_receive {:gate_after_turn, :always}
    end

    test "an error from the hook aborts the turn" do
      Process.put(:test_pid, self())

      assert {:error, state} = Loop.run(turn_end_state([{:error, :gate_crashed}]), "hello")
      assert state.status == :error
      assert state.error =~ "Hook aborted before turn end"
      assert state.error =~ "gate_crashed"
      assert_receive {:gate_after_turn, [{:error, :gate_crashed}]}
    end

    test "invalid messages abort the turn" do
      Process.put(:test_pid, self())

      assert {:error, state} = Loop.run(turn_end_state([{:continue, [""]}]), "hello")
      assert state.error =~ "invalid messages"
      assert state.current_iteration == 1
    end

    test "cancellation during the hook cancels instead of continuing" do
      Process.put(:test_pid, self())
      signal = Cancellation.new_signal()

      assert {:cancelled, state} =
               Loop.run(turn_end_state([:cancel], context: %{signal: signal}), "hello",
                 cancellation_signal: signal
               )

      assert state.current_iteration == 1
      refute Enum.any?(state.messages, &(&1.content == "too late"))
      assert_receive {:messages, _first_call}
      refute_receive {:messages, _}, 20
    end

    test "is not called when the provider fails" do
      Process.put(:test_pid, self())

      assert {:error, _state} =
               Loop.run(turn_end_state([], adapter: PermanentFailureAdapter), "hello")

      refute_receive {:before_turn_end, _, _}, 20
    end

    defmodule SignalHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def before_prompt(_state, context) do
        send(
          context.test_pid,
          {:signal_in, :before_prompt, Map.get(context, :cancellation_signal)}
        )

        {:ok, Map.put(context, :seen_prompt, true)}
      end

      @impl true
      def before_turn_end(_state, context) do
        send(context.test_pid, {:signal_in, :before_turn_end, context[:cancellation_signal]})
        {:ok, Map.put(context, :seen_turn_end, true)}
      end

      @impl true
      def after_turn(_state, context) do
        send(context.test_pid, {:signal_in, :after_turn, context[:cancellation_signal]})
        :ok
      end
    end

    test "hooks receive the run's cancellation signal without keeping it in the state" do
      Process.put(:test_pid, self())
      signal = Cancellation.new_signal()

      state =
        State.new(
          llm: TestLLM.selection(MessagesCapturingAdapter),
          hooks: [SignalHook],
          context: %{test_pid: self()}
        )

      assert {:ok, state} = Loop.run(state, "hello", cancellation_signal: signal)

      assert_receive {:signal_in, :before_prompt, ^signal}
      assert_receive {:signal_in, :before_turn_end, ^signal}
      assert_receive {:signal_in, :after_turn, nil}
      assert state.context.seen_prompt
      assert state.context.seen_turn_end
      refute Map.has_key?(state.context, :cancellation_signal)
    end

    test "a host's own :cancellation_signal context entry is kept" do
      Process.put(:test_pid, self())

      state =
        State.new(
          llm: TestLLM.selection(MessagesCapturingAdapter),
          hooks: [SignalHook],
          context: %{test_pid: self(), cancellation_signal: :host_value}
        )

      assert {:ok, state} =
               Loop.run(state, "hello", cancellation_signal: Cancellation.new_signal())

      assert_receive {:signal_in, :before_turn_end, :host_value}
      assert state.context.cancellation_signal == :host_value
    end
  end

  defp collect_terminal_event_types(events) do
    receive do
      {:event, type} when is_atom(type) -> collect_terminal_event_types([type | events])
      {:terminal_event, type} -> collect_terminal_event_types([type | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp collect_events(events) do
    receive do
      {:event, %Event{} = event} -> collect_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
