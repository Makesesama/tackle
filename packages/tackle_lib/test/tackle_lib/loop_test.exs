defmodule Tackle.Lib.LoopTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.Loop
  alias Tackle.Lib.State
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

  defmodule SecondTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "second"

    @impl true
    def description, do: "Second ordered test tool."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(_args, %{test_pid: test_pid}) do
      send(test_pid, {:tool_execute, :second})
      {:ok, %{ok: true}}
    end
  end

  defmodule CancelAfterTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "cancel_after"

    @impl true
    def description, do: "Cancels the current run after executing."

    @impl true
    def parameters_schema, do: []

    @impl true
    def execute(_args, %{test_pid: test_pid, cancellation_signal: signal}) do
      send(test_pid, {:tool_execute, :cancel_after})
      Cancellation.cancel(signal, "stop requested")
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

  defmodule CancellingToolAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, opts) do
      send(Process.get(:test_pid), {:llm_opts, opts})

      case Process.get(:call_count, 0) do
        0 ->
          Process.put(:call_count, 1)

          {:ok,
           %{
             data: %{
               "thinking" => "need tools",
               "tool_calls" => [
                 %{"id" => "call_cancel", "name" => "cancel_after", "arguments" => %{}},
                 %{"id" => "call_second", "name" => "second", "arguments" => %{}}
               ]
             },
             usage: nil,
             model: "test/model"
           }}

        _count ->
          {:ok, %{data: %{"content" => "done"}, usage: nil, model: "test/model"}}
      end
    end
  end

  defmodule ToolCallingAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, opts) do
      test_pid = Process.get(:test_pid) || Process.whereis(__MODULE__)
      if is_pid(test_pid), do: send(test_pid, {:llm_opts, opts})

      case Process.get(:call_count, 0) do
        0 ->
          Process.put(:call_count, 1)

          {:ok,
           %{
             data: %{
               "thinking" => "need tools",
               "tool_calls" => [
                 %{"id" => "call_first", "name" => "first", "arguments" => %{}},
                 %{"id" => "call_second", "name" => "second", "arguments" => %{}}
               ]
             },
             usage: nil,
             model: "test/model"
           }}

        _count ->
          {:ok, %{data: %{"content" => "done"}, usage: nil, model: "test/model"}}
      end
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

  setup do
    previous_llm = Application.get_env(:tackle_lib, :llm)
    Application.put_env(:tackle_lib, :llm, TestAdapter)

    on_exit(fn ->
      if previous_llm do
        Application.put_env(:tackle_lib, :llm, previous_llm)
      else
        Application.delete_env(:tackle_lib, :llm)
      end
    end)
  end

  test "sends only persisted messages to the provider" do
    Application.put_env(:tackle_lib, :llm, MessagesCapturingAdapter)
    Process.put(:test_pid, self())

    state = State.new(model: "test/model")

    assert {:ok, _state} = Loop.run(state, "hello")

    assert_receive {:messages, [%{role: :user, content: "hello"}]}
  end

  test "native protocol: plain content is treated as the final answer" do
    Application.put_env(:tackle_lib, :llm, NativeContentAdapter)
    Process.put(:test_pid, self())
    Process.put(:call_count, 0)

    state = State.new(model: "test/model")

    assert {:ok, state} = Loop.run(state, "hello")
    assert state.status == :completed

    last = List.last(state.messages)
    assert last.role == :assistant
    assert last.content == "Here is your plain answer."
    assert last.thinking == "reasoned"
  end

  test "native protocol: native tool_calls drive tool execution then plain-content answer" do
    Application.put_env(:tackle_lib, :llm, NativeToolThenContentAdapter)
    Process.put(:test_pid, self())
    Process.put(:call_count, 0)

    test_pid = self()

    state =
      State.new(model: "test/model", tools: [FirstTool], context: %{test_pid: test_pid})

    assert {:ok, state} = Loop.run(state, "do the thing")
    assert_receive {:tool_execute, :first}
    assert state.status == :completed
    assert List.last(state.messages).content == "Done after tool."
  end

  test "runs beyond ten iterations when no explicit limit is configured" do
    Application.put_env(:tackle_lib, :llm, TenToolCallsThenContentAdapter)
    Process.put(:call_count, 0)

    state =
      State.new(model: "test/model", tools: [FirstTool], context: %{test_pid: self()})

    assert {:ok, state} = Loop.run(state, "keep using the tool")
    assert state.max_iterations == :infinity
    assert state.current_iteration == 11
    assert List.last(state.messages).content == "Done after ten tools."
  end

  test "passes a structured message array (not a flat blob) with linked tool call/result" do
    Application.put_env(:tackle_lib, :llm, StructuredMessagesCapturingAdapter)
    Process.put(:test_pid, self())
    Process.put(:call_count, 0)

    test_pid = self()

    state =
      State.new(model: "test/model", tools: [FirstTool], context: %{test_pid: test_pid})

    assert {:ok, _state} = Loop.run(state, "do the thing")

    # The first request contains only the persisted user turn.
    assert_receive {:messages, first_messages}
    assert [%{role: :user, content: "do the thing"}] = first_messages

    # The second request extends that exact prefix with the assistant tool call
    # and linked result. No synthetic instruction is inserted between them.
    assert_receive {:messages, second_messages}
    assert Enum.take(second_messages, length(first_messages)) == first_messages
    assert length(second_messages) == 3

    assistant_call =
      Enum.find(second_messages, fn m ->
        m.role == :assistant and is_list(m[:tool_calls]) and m[:tool_calls] != []
      end)

    assert assistant_call, "expected a structured assistant tool-call turn"

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
    state = State.new(model: "test/model")

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

  test "can route provider streaming through Tackle.Lib event deltas" do
    test_pid = self()
    state = State.new(model: "test/model")

    assert {:ok, _state} =
             Loop.run(state, "hello",
               llm_stream: true,
               event_callback: fn event -> send(test_pid, {:event, event}) end
             )

    assert_receive {:event, %Event{type: :message_delta, data: %{delta: "do"}}}
    assert_receive {:event, %Event{type: :message_delta, data: %{delta: "ne"}}}
  end

  test "executes multiple tool calls sequentially and strips unsupported tool policy opts" do
    Application.put_env(:tackle_lib, :llm, ToolCallingAdapter)
    Process.put(:test_pid, self())
    Process.put(:call_count, 0)

    state =
      State.new(
        model: "test/model",
        tools: [FirstTool, SecondTool],
        context: %{test_pid: self()},
        llm_opts: [
          tool_choice: "required",
          parallel_tool_calls: true,
          disallowed_tools: ["second"],
          tool_weights: %{"first" => 10},
          receive_timeout: 1_000
        ]
      )

    assert {:ok, state} =
             Loop.run(state, "run both",
               event_callback: fn event -> send(self(), {:event, event}) end
             )

    assert state.status == :completed

    assert_receive {:llm_opts, opts}
    assert Keyword.has_key?(opts, :tools)
    assert Keyword.get(opts, :session_id) == state.session_id
    assert Keyword.get(opts, :receive_timeout) == 1_000
    refute Keyword.has_key?(opts, :tool_choice)
    refute Keyword.has_key?(opts, :parallel_tool_calls)
    refute Keyword.has_key?(opts, :disallowed_tools)
    refute Keyword.has_key?(opts, :tool_weights)

    assert_receive {:event, %Event{type: :tool_start, data: %{name: "first"}}}
    assert_receive {:tool_execute, :first}
    assert_receive {:event, %Event{type: :tool_end, data: %{name: "first"}}}
    assert_receive {:event, %Event{type: :tool_start, data: %{name: "second"}}}
    assert_receive {:tool_execute, :second}
    assert_receive {:event, %Event{type: :tool_end, data: %{name: "second"}}}
  end

  test "emits sanitized tool telemetry with host allowlisted names" do
    Application.put_env(:tackle_lib, :llm, ToolCallingAdapter)
    Process.put(:test_pid, self())
    Process.put(:call_count, 0)
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:tackle, :tool, :execution, :start], [:tackle, :tool, :execution, :stop]],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:tool_telemetry, event, measurements, metadata})
        end,
        nil
      )

    try do
      state =
        State.new(
          model: "test/model",
          tools: [FirstTool, SecondTool],
          context: %{test_pid: self(), telemetry: %{tool_names: ["first"]}}
        )

      assert {:ok, _state} = Loop.run(state, "run both")

      assert_receive {:tool_telemetry, [:tackle, :tool, :execution, :start], _,
                      %{tool_name: "first"} = first_start}

      refute Map.has_key?(first_start, :arguments)

      assert_receive {:tool_telemetry, [:tackle, :tool, :execution, :stop],
                      %{count: 1, duration: _}, %{tool_name: "first", outcome: :success}}

      assert_receive {:tool_telemetry, [:tackle, :tool, :execution, :start], _,
                      %{tool_name: "other"}}

      assert_receive {:tool_telemetry, [:tackle, :tool, :execution, :stop], _,
                      %{tool_name: "other", outcome: :success} = second_stop}

      refute Map.has_key?(second_stop, :result)
    after
      :telemetry.detach(handler_id)
    end
  end

  test "cancels before starting the LLM call" do
    Application.put_env(:tackle_lib, :llm, NoCallAdapter)
    Process.put(:test_pid, self())

    signal = Cancellation.new_signal()
    Cancellation.cancel(signal, "user stopped")

    state = State.new(model: "test/model")

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

  test "cancels between sequential tool calls and exposes the signal to tools and adapters" do
    Application.put_env(:tackle_lib, :llm, CancellingToolAdapter)
    Process.put(:test_pid, self())
    Process.put(:call_count, 0)

    signal = Cancellation.new_signal()

    state =
      State.new(
        model: "test/model",
        tools: [CancelAfterTool, SecondTool],
        context: %{test_pid: self()}
      )

    assert {:cancelled, state} =
             Loop.run(state, "run until cancelled",
               cancellation_signal: signal,
               event_callback: fn event -> send(self(), {:event, event}) end
             )

    assert state.status == :cancelled
    assert state.error == "stop requested"

    assert_receive {:llm_opts, opts}
    assert Keyword.get(opts, :cancellation_signal) == signal

    assert_receive {:event, %Event{type: :tool_start, data: %{name: "cancel_after"}}}
    assert_receive {:tool_execute, :cancel_after}
    assert_receive {:event, %Event{type: :tool_end, data: %{name: "cancel_after"}}}
    assert_receive {:event, %Event{type: :status_change, data: %{status: :cancelled}}}
    assert_receive {:event, %Event{type: :turn_cancelled, data: %{reason: "stop requested"}}}
    refute_receive {:tool_execute, :second}, 20
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
      def after_prompt(_state, _response, context) do
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

    defmodule AfterToolAbortHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def after_tool_call(_state, _result, _context) do
        {:error, :after_tool_failed}
      end
    end

    defmodule ReplacementAdapter do
      @behaviour Tackle.Lib.LLM

      @impl true
      def generate(_schema, _opts) do
        send(Process.get(:test_pid), :replacement_adapter_called)
        {:ok, %{data: %{"content" => "replacement"}, usage: nil, model: "replacement"}}
      end
    end

    defmodule SnapshotAdapter do
      @behaviour Tackle.Lib.LLM

      @impl true
      def generate(_schema, _opts) do
        send(Process.get(:test_pid), :snapshot_adapter_called)
        {:ok, %{data: %{"content" => "snapshot"}, usage: nil, model: "snapshot"}}
      end
    end

    defmodule SwapAdapterConfigHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def before_prompt(_state, context) do
        Application.put_env(:tackle_lib, :llm, ReplacementAdapter)
        send(Map.fetch!(context, :test_pid), :adapter_config_swapped)
        :ok
      end
    end

    test "lifecycle hooks fire in correct order during a turn" do
      Application.put_env(:tackle_lib, :llm, HookTestAdapter)
      Process.put(:llm_call_count, 0)

      state =
        State.new(
          model: "test/model",
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
      # after_turn fires at the very end
      assert_receive {:hook_fired, :after_turn}
    end

    test "context mutator hooks propagate context changes" do
      Application.put_env(:tackle_lib, :llm, TestAdapter)

      state =
        State.new(
          model: "test/model",
          hooks: [ContextMutatorHook],
          context: %{original: true}
        )

      assert {:ok, state} = Loop.run(state, "test mutator")
      assert state.status == :completed
      # The before_prompt hook mutated the context
      # Note: after_turn cleanup clears the snapshot but preserves context
      assert state.context.hook_marker == "mutated_before_prompt"
    end

    test "snapshot is captured and used for tool registry resolution" do
      Application.put_env(:tackle_lib, :llm, TestAdapter)

      state =
        State.new(
          model: "test/model",
          tools: [FirstTool],
          context: %{}
        )

      assert {:ok, state} = Loop.run(state, "hello")
      assert state.snapshot == nil
      assert state.status == :completed
    end

    test "after_tool_call hook errors abort the turn" do
      Application.put_env(:tackle_lib, :llm, HookTestAdapter)
      Process.put(:llm_call_count, 0)

      state =
        State.new(
          model: "test/model",
          tools: [HookLoggingTool],
          hooks: [AfterToolAbortHook],
          context: %{test_pid: self()}
        )

      assert {:error, state} = Loop.run(state, "test abort")
      assert state.status == :error
      assert state.error =~ "Hook aborted after tool call"
      assert state.snapshot == nil
    end

    test "snapshot freezes the LLM adapter for the turn" do
      Application.put_env(:tackle_lib, :llm, SnapshotAdapter)
      Process.put(:test_pid, self())

      state =
        State.new(
          model: "test/model",
          hooks: [SwapAdapterConfigHook],
          context: %{test_pid: self()}
        )

      assert {:ok, state} = Loop.run(state, "test snapshot adapter")
      assert state.status == :completed

      assert_receive :adapter_config_swapped
      assert_receive :snapshot_adapter_called
      refute_receive :replacement_adapter_called, 20
    end
  end
end
