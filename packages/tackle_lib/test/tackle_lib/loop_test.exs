defmodule Tackle.Lib.LoopTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.JSON
  alias Tackle.Lib.Loop
  alias Tackle.Lib.Message
  alias Tackle.Lib.Messages
  alias Tackle.Lib.State
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

    # Tools receive their call's child signal; cancelling its parent (the turn
    # signal) cancels the whole run.
    @impl true
    def execute(_args, %{test_pid: test_pid, cancellation_signal: signal}) do
      send(test_pid, {:tool_execute, :cancel_after})
      send(test_pid, {:tool_signal, signal})
      Cancellation.cancel(signal.parent, "stop requested")
      {:ok, %{ok: true}}
    end
  end

  defmodule StoppableTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "stoppable"

    @impl true
    def description, do: "Runs until released or until its call signal is cancelled."

    @impl true
    def parameters_schema do
      [name: [type: :string, required: true]]
    end

    @impl true
    def execute(args, %{test_pid: test_pid, tool_call_id: call_id, cancellation_signal: signal}) do
      name = Map.fetch!(args, "name")
      send(test_pid, {:tool_entered, name, call_id, signal, self()})
      await_release_or_stop(name, signal, 400)
    end

    @impl true
    def model_error(reason) when is_binary(reason), do: reason

    defp await_release_or_stop(name, _signal, 0), do: {:ok, %{name: name, timed_out: true}}

    defp await_release_or_stop(name, signal, attempts) do
      case Cancellation.reason(signal) do
        nil ->
          receive do
            {:release, ^name} -> {:ok, %{name: name}}
          after
            5 -> await_release_or_stop(name, signal, attempts - 1)
          end

        {:watchdog, message} ->
          {:error, message}

        reason ->
          {:error, "stopped: #{inspect(reason)}"}
      end
    end
  end

  defmodule StoppableToolAdapter do
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
                 %{"id" => "c1", "name" => "stoppable", "arguments" => %{"name" => "one"}},
                 %{"id" => "c2", "name" => "stoppable", "arguments" => %{"name" => "two"}}
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

  defmodule CancelBeforeToolHook do
    @behaviour Tackle.Lib.Hook

    @impl true
    def before_tool_call(_state, _call, context) do
      Cancellation.cancel(context.cancellation_signal, "cancelled in hook")
      :ok
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

  defmodule BlockingTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "blocking"

    @impl true
    def description, do: "Blocks until released by the test process."

    @impl true
    def parameters_schema do
      [name: [type: :string, required: true]]
    end

    @impl true
    def execute(args, %{test_pid: test_pid}) do
      name = Map.fetch!(args, "name")
      send(test_pid, {:tool_entered, name, self()})

      receive do
        {:release, ^name} -> {:ok, %{name: name}}
      after
        2_000 -> {:ok, %{name: name, timed_out: true}}
      end
    end
  end

  defmodule CrashingTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "crash"

    @impl true
    def description, do: "Kills its task to exercise crash isolation."

    @impl true
    def parameters_schema, do: []

    # Tool settlement turns raises, throws, and exits into error results, so
    # only a killed task process reaches the batch's crash handling.
    @impl true
    def execute(_args, _context), do: Process.exit(self(), :kill)
  end

  defmodule MisbehavingTool do
    @behaviour Tackle.Lib.Tool

    @impl true
    def name, do: "misbehave"

    @impl true
    def description, do: "Fails in the way named by its argument."

    @impl true
    def parameters_schema, do: [how: [type: :string, required: true]]

    @impl true
    def execute(%{"how" => "exit"}, _context), do: exit(:timeout)
    def execute(%{"how" => "throw"}, _context), do: throw(:oops)
    def execute(%{"how" => "unencodable"}, _context), do: {:ok, %{pair: {1, 2}}}
  end

  defmodule MisbehavingToolAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, opts) do
      if Enum.any?(Keyword.fetch!(opts, :messages), &(&1.role == :tool)) do
        {:ok, %{data: %{"content" => "survived"}, usage: nil, model: "test/model"}}
      else
        calls =
          for how <- ["exit", "throw", "unencodable"] do
            %{"id" => how, "name" => "misbehave", "arguments" => %{"how" => how}}
          end

        {:ok, %{data: %{"tool_calls" => calls}, usage: nil, model: "test/model"}}
      end
    end
  end

  defmodule ParallelToolAdapter do
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
                 %{"id" => "c1", "name" => "blocking", "arguments" => %{"name" => "one"}},
                 %{"id" => "c2", "name" => "blocking", "arguments" => %{"name" => "two"}}
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

  defmodule CrashAndBlockAdapter do
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
                 %{"id" => "bad", "name" => "crash", "arguments" => %{}},
                 %{"id" => "good", "name" => "blocking", "arguments" => %{"name" => "ok"}}
               ]
             },
             usage: nil,
             model: "test/model"
           }}

        _count ->
          {:ok, %{data: %{"content" => "recovered"}, usage: nil, model: "test/model"}}
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
  defmodule RetryThenSuccessAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, opts) do
      call_count = Process.get(:retry_call_count, 0)
      Process.put(:retry_call_count, call_count + 1)
      send(Process.get(:test_pid), {:retry_messages, Keyword.fetch!(opts, :messages)})

      if call_count == 0 do
        {:error, {:request_failed, :timeout}}
      else
        {:ok, %{data: %{"content" => "retried"}, usage: nil, model: "test/model"}}
      end
    end
  end

  defmodule AlwaysTransientAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, _opts) do
      send(Process.get(:test_pid), :retry_call)
      {:error, {:http_error, 503, "unavailable"}}
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

  defmodule CancelDuringRetryAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def generate(_schema, opts) do
      signal = Keyword.fetch!(opts, :cancellation_signal)
      send(Process.get(:test_pid), :retry_call)

      spawn(fn ->
        Process.sleep(20)
        Cancellation.cancel(signal, "cancelled in backoff")
      end)

      {:error, {:request_failed, :timeout}}
    end
  end

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
      state = State.new(model: "test/model")
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

    test "tools receive the run's event callback and tool context without the host repeating them" do
      Application.put_env(:tackle_lib, :llm, ProbeAdapter)
      test_pid = self()
      signal = Cancellation.new_signal()

      state =
        State.new(
          model: "test/model",
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

  test "retries a transient provider failure without duplicating the turn" do
    Application.put_env(:tackle_lib, :llm, RetryThenSuccessAdapter)
    Process.put(:test_pid, self())
    Process.put(:retry_call_count, 0)

    state = State.new(model: "test/model", retry: [base_delay_ms: 0])

    assert {:ok, state} =
             Loop.run(state, "hello",
               event_callback: fn event -> send(self(), {:event, event}) end
             )

    assert state.current_iteration == 1
    assert Enum.map(state.messages, & &1.role) == [:user, :assistant]
    assert List.last(state.messages).content == "retried"
    assert_receive {:retry_messages, [%{role: :user, content: "hello"}]}
    assert_receive {:retry_messages, [%{role: :user, content: "hello"}]}

    assert_receive {:event,
                    %Event{
                      type: :retry_scheduled,
                      data: %{
                        attempt: 1,
                        max_retries: 3,
                        delay_ms: 0,
                        reason: {:request_failed, :timeout}
                      }
                    }}

    assert_receive {:event, %Event{type: :retry_start, data: %{attempt: 1}}}
    assert_receive {:event, %Event{type: :retry_end, data: %{attempt: 1, success?: true}}}
  end

  test "emits one retry end and returns the last error after exhausting retries" do
    Application.put_env(:tackle_lib, :llm, AlwaysTransientAdapter)
    Process.put(:test_pid, self())

    state = State.new(model: "test/model", retry: [max_retries: 2, base_delay_ms: 0])

    assert {:error, state} =
             Loop.run(state, "hello",
               event_callback: fn event -> send(self(), {:event, event}) end
             )

    assert state.current_iteration == 1
    assert Enum.map(state.messages, & &1.role) == [:user]
    assert state.error =~ "503"
    assert_receive :retry_call
    assert_receive :retry_call
    assert_receive :retry_call
    refute_receive :retry_call

    events = collect_events([])

    retry_types =
      events
      |> Enum.filter(&(&1.type in [:retry_scheduled, :retry_start, :retry_end]))
      |> Enum.map(& &1.type)

    assert retry_types == [
             :retry_scheduled,
             :retry_start,
             :retry_scheduled,
             :retry_start,
             :retry_end
           ]

    assert [%Event{data: %{attempt: 2, success?: false}}] =
             Enum.filter(events, &(&1.type == :retry_end))
  end

  test "does not retry a permanent provider failure" do
    Application.put_env(:tackle_lib, :llm, PermanentFailureAdapter)
    Process.put(:test_pid, self())

    assert {:error, _state} = Loop.run(State.new(model: "test/model"), "hello")
    assert_receive :retry_call
    refute_receive :retry_call
  end

  test "cancels cooperatively during provider retry backoff" do
    Application.put_env(:tackle_lib, :llm, CancelDuringRetryAdapter)
    Process.put(:test_pid, self())
    signal = Cancellation.new_signal()

    assert {:cancelled, state} =
             Loop.run(State.new(model: "test/model", retry: [base_delay_ms: 5_000]), "hello",
               cancellation_signal: signal,
               event_callback: fn event -> send(self(), {:event, event}) end
             )

    assert state.status == :cancelled
    assert state.error == "cancelled in backoff"
    assert state.current_iteration == 1
    assert_receive :retry_call
    refute_receive :retry_call
    assert_receive {:event, %Event{type: :retry_scheduled}}
    assert_receive {:event, %Event{type: :retry_end, data: %{success?: false}}}
    assert_receive {:event, %Event{type: :turn_cancelled}}
  end

  test "provider callback gates every automatic retry and can reject dispatch" do
    Application.put_env(:tackle_lib, :llm, AlwaysTransientAdapter)
    Process.put(:test_pid, self())
    Process.put(:gate_count, 0)

    gate = fn ->
      count = Process.get(:gate_count, 0)
      Process.put(:gate_count, count + 1)
      send(self(), {:provider_gate, count + 1})
      :ok
    end

    assert {:error, _state} =
             Loop.run(
               State.new(model: "test/model", retry: [max_retries: 2, base_delay_ms: 0]),
               "hello",
               before_provider_call: gate
             )

    assert_receive {:provider_gate, 1}
    assert_receive {:provider_gate, 2}
    assert_receive {:provider_gate, 3}
    assert Process.get(:gate_count) == 3
    assert_receive :retry_call
    assert_receive :retry_call
    assert_receive :retry_call

    Process.put(:gate_count, 0)

    assert {:error, state} =
             Loop.run(State.new(model: "test/model"), "hello",
               before_provider_call: fn ->
                 send(self(), :provider_rejected)
                 {:error, :storage_paused}
               end
             )

    assert state.error =~ "storage_paused"
    assert_receive :provider_rejected
    refute_receive :retry_call
  end

  test "cancellation while provider gate blocks prevents provider dispatch" do
    Application.put_env(:tackle_lib, :llm, NoCallAdapter)
    Process.put(:test_pid, self())
    signal = Cancellation.new_signal()
    test_pid = self()

    on_exit(fn -> Cancellation.delete(signal) end)

    task =
      Task.async(fn ->
        Process.put(:test_pid, test_pid)

        Loop.run(State.new(model: "test/model"), "hello",
          cancellation_signal: signal,
          before_provider_call: fn ->
            send(test_pid, :provider_gate_entered)
            receive do: (:release_provider_gate -> :ok)
          end
        )
      end)

    assert_receive :provider_gate_entered
    Cancellation.cancel(signal, "cancelled at gate")
    send(task.pid, :release_provider_gate)
    assert {:cancelled, state} = Task.await(task, 2_000)
    assert state.error == "cancelled at gate"
    refute_receive :llm_called
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
    Application.put_env(:tackle_lib, :llm, MalformedToolAdapter)

    for calls <- [
          [nil],
          [%{"function" => "not a map"}],
          [%{"name" => "first", "arguments" => "{"}],
          [%{"name" => "first", "arguments" => "[]"}],
          [%{"name" => "first", "arguments" => [1]}]
        ] do
      Process.put(:bad_tool_calls, calls)

      assert {:error, state} =
               Loop.run(
                 State.new(model: "test/model", tools: [FirstTool], context: %{test_pid: self()}),
                 "hello"
               )

      assert state.status == :error
      assert state.error =~ "Invalid provider tool calls"
      refute_receive {:tool_execute, :first}
    end
  end

  test "executes a nested call with decoded JSON arguments" do
    Application.put_env(:tackle_lib, :llm, JsonArgumentsAdapter)
    Process.put(:call_count, 0)

    state = State.new(model: "test/model", tools: [FirstTool], context: %{test_pid: self()})

    assert {:ok, state} = Loop.run(state, "hello")
    assert_receive {:tool_execute, :first}
    assert state.status == :completed

    assert Enum.any?(state.messages, fn
             %{tool_calls: [%Call{arguments: %{"query" => "hi"}}]} -> true
             _ -> false
           end)
  end

  test "rejects an entire batch if a later call has invalid JSON" do
    Application.put_env(:tackle_lib, :llm, MalformedToolAdapter)

    Process.put(:bad_tool_calls, [
      %{"name" => "first", "arguments" => %{}},
      %{"name" => "first", "arguments" => "{"}
    ])

    assert {:error, state} =
             Loop.run(
               State.new(model: "test/model", tools: [FirstTool], context: %{test_pid: self()}),
               "hello"
             )

    assert state.error =~ "invalid_tool_arguments"
    refute_receive {:tool_execute, :first}
  end

  test "normalizes provider calls with nested function, atom keys and JSON arguments" do
    raw = %{
      id: "call-1",
      function: %{"name" => "first", "arguments" => ~s({"query":"hi"})},
      definition_id: "version-1"
    }

    assert {:ok,
            %Call{
              id: "call-1",
              name: "first",
              arguments: %{"query" => "hi"},
              definition_id: "version-1",
              raw: ^raw
            }} = Call.normalize(raw)

    assert {:ok, %Call{arguments: %{}}} = Call.normalize(%{"name" => "first"})
    assert {:error, :malformed_tool_call} = Call.normalize(%{"arguments" => %{}})

    assert {:error, :invalid_tool_arguments} =
             Call.normalize(%{"name" => "first", "arguments" => "{"})

    assert {:error, :invalid_tool_arguments} =
             Call.normalize(%{"name" => "first", "arguments" => "[]"})

    assert {:ok, %Call{arguments: %{"query" => "hi"}}} =
             Call.normalize(%{"name" => "first", "arguments" => %{"query" => "hi"}})
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

  test "max_iterations bounds each turn, not the whole session" do
    state = State.new(model: "test/model", max_iterations: 1)

    assert {:ok, state} = Loop.run(state, "first")
    assert state.current_iteration == 1

    assert {:ok, state} = Loop.run(state, "second")
    assert state.current_iteration == 1
    assert state.status == :completed
    assert Enum.map(state.messages, & &1.role) == [:user, :assistant, :user, :assistant]
  end

  test "a successful turn after a failed one does not keep the old error" do
    Application.put_env(:tackle_lib, :llm, PermanentFailureAdapter)
    Process.put(:test_pid, self())

    assert {:error, state} = Loop.run(State.new(model: "test/model"), "first")
    assert state.error =~ "Failed to get response"

    Application.put_env(:tackle_lib, :llm, TestAdapter)

    assert {:ok, state} = Loop.run(state, "second")
    assert state.status == :completed
    assert state.error == nil
  end

  test "passes a structured message array (not a flat blob) with linked tool call/result" do
    Application.put_env(:tackle_lib, :llm, StructuredMessagesCapturingAdapter)
    Process.put(:test_pid, self())
    Process.put(:call_count, 0)

    test_pid = self()

    state =
      State.new(model: "test/model", tools: [FirstTool], context: %{test_pid: test_pid})

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

  defmodule UsageStreamingAdapter do
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
      event_callback.(%{type: :text_delta, text: "done"})
      event_callback.(%{type: :usage, usage: %{prompt_tokens: 5, completion_tokens: 4}})
      generate(schema, opts)
    end
  end

  defmodule GenerateOnlyUsageAdapter do
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
  end

  test "streaming reports each response's usage once" do
    for adapter <- [UsageStreamingAdapter, GenerateOnlyUsageAdapter] do
      Application.put_env(:tackle_lib, :llm, adapter)
      test_pid = self()

      assert {:ok, _state} =
               Loop.run(State.new(model: "test/model"), "hello",
                 llm_stream: true,
                 event_callback: fn event -> send(test_pid, {:event, event}) end
               )

      assert_receive {:event, %Event{type: :turn_end}}

      usages =
        for {:event, %Event{type: :usage, data: %{usage: usage}}} <- drain_messages(),
            do: usage

      assert [%Usage{input_tokens: 5, output_tokens: 4}] = usages, inspect(adapter)
    end
  end

  defp drain_messages(acc \\ []) do
    receive do
      message -> drain_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defmodule EmptyResponseAdapter do
    @behaviour Tackle.Lib.LLM

    # Replies from the script in :empty_script, then with empty responses.
    @impl true
    def generate(_schema, _opts) do
      send(Process.get(:test_pid), :llm_call)

      case Process.get(:empty_script, []) do
        [data | rest] ->
          Process.put(:empty_script, rest)
          {:ok, %{data: data, usage: nil, model: "test/model"}}

        [] ->
          {:ok, %{data: %{"thinking" => "hmm"}, usage: nil, model: "test/model"}}
      end
    end
  end

  describe "empty responses" do
    setup do
      Application.put_env(:tackle_lib, :llm, EmptyResponseAdapter)
      Process.put(:test_pid, self())
      :ok
    end

    test "are asked again once as a retry of the same request" do
      Process.put(:empty_script, [%{"thinking" => "hmm"}, %{"content" => "answer"}])
      test_pid = self()

      assert {:ok, state} =
               Loop.run(State.new(model: "test/model"), "hello",
                 event_callback: fn event -> send(test_pid, {:event, event}) end
               )

      assert Enum.map(state.messages, &{&1.role, &1.content}) ==
               [user: "hello", assistant: "answer"]

      assert_receive {:event, %Event{type: :message_start, id: pending_id}}

      assert_receive {:event,
                      %Event{
                        type: :retry_scheduled,
                        id: ^pending_id,
                        data: %{reason: :empty_response}
                      }}

      assert_receive {:event, %Event{type: :retry_end, data: %{success?: true}}}
      assert List.last(state.messages).id == pending_id
      assert_received :llm_call
      assert_received :llm_call
      refute_received :llm_call
    end

    test "end the turn with an error when the model stays empty" do
      assert {:error, state} = Loop.run(State.new(model: "test/model"), "hello")

      assert state.error == "The model returned an empty response"
      assert state.pending_assistant_id == nil
      assert Enum.map(state.messages, & &1.role) == [:user]
      assert_received :llm_call
      assert_received :llm_call
      refute_received :llm_call
    end

    test "after a tool result are bounded too" do
      Process.put(:empty_script, [
        %{"tool_calls" => [%{"id" => "c1", "name" => "first", "arguments" => %{}}]}
      ])

      state = State.new(model: "test/model", tools: [FirstTool], context: %{test_pid: self()})

      assert {:error, state} = Loop.run(state, "use the tool")
      assert state.error == "The model returned an empty response"
      assert Enum.map(state.messages, & &1.role) == [:user, :assistant, :tool]
      assert_received {:tool_execute, :first}

      for _call <- 1..3, do: assert_received(:llm_call)
      refute_received :llm_call
    end

    test "a non-empty response gives a later empty response its own re-ask" do
      Process.put(:empty_script, [
        %{},
        %{"tool_calls" => [%{"id" => "c1", "name" => "first", "arguments" => %{}}]},
        %{},
        %{"content" => "answer"}
      ])

      state = State.new(model: "test/model", tools: [FirstTool], context: %{test_pid: self()})

      assert {:ok, state} = Loop.run(state, "use the tool")
      assert List.last(state.messages).content == "answer"
    end
  end

  test "host llm_opts override the loop's defaults but not the request" do
    Application.put_env(:tackle_lib, :llm, ToolCallingAdapter)
    Process.put(:test_pid, self())
    Process.put(:call_count, 1)

    state =
      State.new(
        model: "test/model",
        llm_opts: [temperature: 0.9, model: "other/model", messages: [:bogus]]
      )

    assert {:ok, _state} = Loop.run(state, "hello")

    assert_receive {:llm_opts, opts}
    assert Keyword.get_values(opts, :temperature) == [0.9]
    assert Keyword.get_values(opts, :model) == ["test/model"]
    assert [[%{role: :user, content: "hello"}]] = Keyword.get_values(opts, :messages)
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

    assert_receive {:event,
                    %Event{type: :tool_execution_end, data: %{name: "first", status: :completed}}}

    assert_receive {:event, %Event{type: :tool_end, data: %{name: "first"}}}
    assert_receive {:event, %Event{type: :tool_start, data: %{name: "second"}}}
    assert_receive {:tool_execute, :second}
    assert_receive {:event, %Event{type: :tool_end, data: %{name: "second"}}}
  end

  test "concurrent policy dispatches a batch in parallel and commits results in call order" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    Application.put_env(:tackle_lib, :llm, ParallelToolAdapter)
    test_pid = self()

    state =
      State.new(
        model: "test/model",
        tools: [BlockingTool],
        tool_policy: Policy.concurrent(),
        context: %{test_pid: test_pid}
      )

    run =
      Task.async(fn ->
        Loop.run(state, "run both",
          tool_supervisor: supervisor,
          event_callback: fn event -> send(test_pid, {:event, event}) end
        )
      end)

    # Both tools enter before either is released, proving parallel dispatch.
    assert_receive {:event, %Event{type: :tool_start, data: %{name: "blocking"}}}
    assert_receive {:event, %Event{type: :tool_start, data: %{name: "blocking"}}}
    assert_receive {:tool_entered, first_name, first_task}
    assert_receive {:tool_entered, second_name, second_task}
    assert MapSet.new([first_name, second_name]) == MapSet.new(["one", "two"])

    tasks = Map.new([{first_name, first_task}, {second_name, second_task}])
    # A later call finishes while the first is still blocked. Progress must not
    # wait for that first call, and settlement must remain in provider order.
    send(tasks["two"], {:release, "two"})

    assert_receive {:event,
                    %Event{
                      type: :tool_execution_end,
                      data: %{tool_call_id: "c2", status: :completed, result: result}
                    }},
                   1_000

    assert JSON.decode!(result) == %{"name" => "two"}
    refute_receive {:event, %Event{type: :tool_end}}, 20
    refute_receive {:event, %Event{type: :message_end, data: %{role: :tool}}}, 20
    assert Process.alive?(tasks["one"])
    send(tasks["one"], {:release, "one"})

    assert {:ok, final_state} = Task.await(run, 5_000)
    assert final_state.status == :completed

    tool_messages = Enum.filter(final_state.messages, &(&1.role == :tool))
    assert Enum.map(tool_messages, & &1.tool_call_id) == ["c1", "c2"]
    assert_receive {:event, %Event{type: :tool_execution_end, data: %{tool_call_id: "c1"}}}
    refute_receive {:event, %Event{type: :tool_execution_end}}, 20
    assert_receive {:event, %Event{type: :tool_end, data: %{tool_call_id: "c1"}}}
    assert_receive {:event, %Event{type: :tool_end, data: %{tool_call_id: "c2"}}}

    assert Enum.map(tool_messages, fn message ->
             message.content |> JSON.decode!() |> Map.fetch!("name")
           end) == ["one", "two"]
  end

  test "concurrent cancellation commits completed results and stops pending tools" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    Application.put_env(:tackle_lib, :llm, ParallelToolAdapter)
    test_pid = self()
    signal = Cancellation.new_signal()

    state =
      State.new(
        model: "test/model",
        tools: [BlockingTool],
        tool_policy: Policy.concurrent(),
        context: %{test_pid: test_pid}
      )

    run =
      Task.async(fn ->
        Loop.run(state, "run both",
          tool_supervisor: supervisor,
          cancellation_signal: signal,
          event_callback: fn event -> send(test_pid, {:event, event}) end
        )
      end)

    try do
      assert_receive {:tool_entered, "one", first_task}, 2_000
      assert_receive {:tool_entered, "two", second_task}, 2_000
      send(second_task, {:release, "two"})

      assert_receive {:event,
                      %Event{
                        type: :tool_execution_end,
                        data: %{tool_call_id: "c2", status: :completed}
                      }},
                     2_000

      Cancellation.cancel(signal, "stop batch")
      assert {:cancelled, final_state} = Task.await(run, 5_000)
      refute Process.alive?(first_task)
      assert final_state.status == :cancelled

      # The unfinished call is settled with a synthetic result so the persisted
      # transcript keeps the call/result pairing providers require.
      tool_messages = Enum.filter(final_state.messages, &(&1.role == :tool))
      assert Enum.map(tool_messages, & &1.tool_call_id) == ["c2", "c1"]

      assert %Message{tool_call_id: "c1", tool_name: "blocking"} =
               interrupted =
               Enum.find(tool_messages, &(&1.tool_call_id == "c1"))

      assert interrupted.content =~ "cancelled before this call completed"

      assert_receive {:event, %Event{type: :tool_end, data: %{tool_call_id: "c2"}}}

      assert_receive {:event,
                      %Event{
                        type: :tool_error,
                        data: %{tool_call_id: "c1", reason: :interrupted}
                      }}

      assert_receive {:event, %Event{type: :turn_cancelled, data: %{reason: "stop batch"}}}

      refute_receive {:event, %Event{type: :tool_execution_end, data: %{tool_call_id: "c1"}}},
                     20
    after
      Cancellation.delete(signal)
    end
  end

  test "concurrent policy converts a crashed tool into an error result" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    Application.put_env(:tackle_lib, :llm, CrashAndBlockAdapter)
    test_pid = self()

    state =
      State.new(
        model: "test/model",
        tools: [CrashingTool, BlockingTool],
        tool_policy: Policy.concurrent(),
        context: %{test_pid: test_pid}
      )

    run =
      Task.async(fn ->
        Loop.run(state, "run both",
          tool_supervisor: supervisor,
          event_callback: fn event -> send(test_pid, {:event, event}) end
        )
      end)

    assert_receive {:event, %Event{type: :tool_start, data: %{name: "crash"}}}
    assert_receive {:event, %Event{type: :tool_start, data: %{name: "blocking"}}}
    assert_receive {:tool_entered, "ok", blocker}

    assert_receive {:event,
                    %Event{
                      type: :tool_execution_end,
                      data: %{tool_call_id: "bad", status: :failed, reason: :execution_error}
                    }},
                   1_000

    refute_receive {:event, %Event{type: :tool_error}}, 20
    send(blocker, {:release, "ok"})

    assert {:ok, final_state} = Task.await(run, 5_000)
    assert final_state.status == :completed

    assert_receive {:event, %Event{type: :tool_error, data: %{name: "crash"}}}
    assert_receive {:event, %Event{type: :tool_end, data: %{name: "blocking"}}}

    tool_messages = Enum.filter(final_state.messages, &(&1.role == :tool))
    assert Enum.map(tool_messages, & &1.tool_call_id) == ["bad", "good"]
  end

  test "concurrent tool tasks do not copy conversation history" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    Application.put_env(:tackle_lib, :llm, ParallelToolAdapter)
    test_pid = self()

    # Use ordinary terms, not a large binary (which the BEAM shares between processes).
    history = for i <- 1..12_000, do: Message.assistant(content: "history #{i}")

    state =
      State.new(
        model: "test/model",
        tools: [BlockingTool],
        tool_policy: Policy.concurrent(),
        context: %{test_pid: test_pid}
      )
      |> Map.put(:messages, history)

    run = Task.async(fn -> Loop.run(state, "run both", tool_supervisor: supervisor) end)

    assert_receive {:tool_entered, first_name, first_task}, 5_000
    assert_receive {:tool_entered, second_name, second_task}, 5_000

    try do
      for task <- [first_task, second_task] do
        :erlang.garbage_collect(task)
        assert {:memory, bytes} = Process.info(task, :memory)
        assert bytes < 500_000, "tool task retained conversation history: #{bytes} bytes"
      end
    after
      send(first_task, {:release, first_name})
      send(second_task, {:release, second_name})
    end

    assert {:ok, %{status: :completed}} = Task.await(run, 5_000)
  end

  test "concurrent preparation errors settle as tool crashes instead of aborting the loop" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    Application.put_env(:tackle_lib, :llm, ParallelToolAdapter)
    test_pid = self()

    state =
      State.new(
        model: "test/model",
        tools: [BlockingTool],
        tool_policy: Policy.concurrent(),
        context: %{test_pid: test_pid}
      )

    assert {:ok, final_state} =
             Loop.run(state, "run both",
               tool_supervisor: supervisor,
               tool_context: nil,
               event_callback: fn event -> send(test_pid, {:event, event}) end
             )

    assert final_state.status == :completed

    assert Enum.map(Enum.filter(final_state.messages, &(&1.role == :tool)), & &1.tool_call_id) ==
             ["c1", "c2"]

    assert_receive {:event, %Event{type: :tool_error, data: %{tool_call_id: "c1"}}}
    assert_receive {:event, %Event{type: :tool_error, data: %{tool_call_id: "c2"}}}
    refute_receive {:tool_entered, _, _}
  end

  test "sequential policy settles tools that exit, throw, or return unencodable data" do
    Application.put_env(:tackle_lib, :llm, MisbehavingToolAdapter)
    test_pid = self()

    state = State.new(model: "test/model", tools: [MisbehavingTool])

    assert {:ok, final_state} =
             Loop.run(state, "misbehave",
               event_callback: fn event -> send(test_pid, {:event, event}) end
             )

    assert List.last(final_state.messages).content == "survived"

    assert [exit, throw, unencodable] = Enum.filter(final_state.messages, &(&1.role == :tool))
    assert {exit.tool_call_id, throw.tool_call_id} == {"exit", "throw"}
    assert exit.content == "Error: The tool failed while completing the request."
    assert throw.content == "Error: The tool failed while completing the request."
    assert unencodable.tool_call_id == "unencodable"

    assert_receive {:event,
                    %Event{
                      type: :tool_error,
                      data: %{tool_call_id: "exit", details: {:exit, :timeout}}
                    }}

    assert_receive {:event,
                    %Event{
                      type: :tool_error,
                      data: %{tool_call_id: "throw", details: {:throw, :oops}}
                    }}

    assert_receive {:event,
                    %Event{
                      type: :tool_error,
                      data: %{tool_call_id: "unencodable", reason: :invalid_output}
                    }}
  end

  test "sequential preparation errors settle as tool crashes instead of crashing the loop" do
    Application.put_env(:tackle_lib, :llm, ParallelToolAdapter)
    test_pid = self()

    state = State.new(model: "test/model", tools: [BlockingTool], context: %{test_pid: test_pid})

    assert {:ok, final_state} =
             Loop.run(state, "run both",
               tool_context: nil,
               event_callback: fn event -> send(test_pid, {:event, event}) end
             )

    assert final_state.status == :completed

    assert Enum.map(Enum.filter(final_state.messages, &(&1.role == :tool)), & &1.tool_call_id) ==
             ["c1", "c2"]

    assert_receive {:event,
                    %Event{
                      type: :tool_error,
                      data: %{tool_call_id: "c1", reason: :execution_error}
                    }}

    refute_receive {:tool_entered, _, _}
  end

  test "concurrent policy without a tool supervisor raises" do
    Application.put_env(:tackle_lib, :llm, ParallelToolAdapter)

    state =
      State.new(
        model: "test/model",
        tools: [BlockingTool],
        tool_policy: Policy.concurrent(),
        context: %{test_pid: self()}
      )

    assert_raise ArgumentError, ~r/tool_supervisor/, fn -> Loop.run(state, "run both") end
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

  test "appends incoming messages before the first provider call" do
    Application.put_env(:tackle_lib, :llm, MessagesCapturingAdapter)
    Process.put(:test_pid, self())
    Process.put(:incoming_polls, 0)

    callback = fn ->
      polls = Process.get(:incoming_polls, 0)
      Process.put(:incoming_polls, polls + 1)
      if polls == 0, do: {:ok, ["queued first"]}, else: {:ok, []}
    end

    assert {:ok, state} =
             Loop.run(State.new(model: "test/model"), "hello", take_incoming_messages: callback)

    assert_receive {:messages,
                    [%{role: :user, content: "hello"}, %{role: :user, content: "queued first"}]}

    assert Enum.map(state.messages, &{&1.role, &1.content}) == [
             {:user, "hello"},
             {:user, "queued first"},
             {:assistant, "done"}
           ]
  end

  test "appends incoming messages only after a complete tool batch" do
    Application.put_env(:tackle_lib, :llm, StructuredMessagesCapturingAdapter)
    Process.put(:test_pid, self())
    Process.put(:call_count, 0)
    Process.put(:incoming_polls, 0)

    callback = fn ->
      polls = Process.get(:incoming_polls, 0)
      Process.put(:incoming_polls, polls + 1)
      if polls == 1, do: {:ok, ["after tools"]}, else: {:ok, []}
    end

    state = State.new(model: "test/model", tools: [FirstTool], context: %{test_pid: self()})
    assert {:ok, _state} = Loop.run(state, "hello", take_incoming_messages: callback)

    assert_receive {:messages, [%{role: :user, content: "hello"}]}
    assert_receive {:tool_execute, :first}
    assert_receive {:messages, messages}
    assert Enum.map(messages, & &1.role) == [:user, :assistant, :tool, :user]
    assert List.last(messages).content == "after tools"
  end

  test "continues the same run when a message arrives at the final response boundary" do
    Application.put_env(:tackle_lib, :llm, MessagesCapturingAdapter)
    Process.put(:test_pid, self())
    Process.put(:incoming_polls, 0)

    callback = fn ->
      polls = Process.get(:incoming_polls, 0)
      Process.put(:incoming_polls, polls + 1)
      if polls == 1, do: {:ok, ["follow up"]}, else: {:ok, []}
    end

    assert {:ok, state} =
             Loop.run(State.new(model: "test/model"), "hello", take_incoming_messages: callback)

    assert_receive {:messages, [%{role: :user, content: "hello"}]}
    assert_receive {:messages, messages}
    assert Enum.map(messages, & &1.role) == [:user, :assistant, :user]
    assert List.last(messages).content == "follow up"
    assert state.current_iteration == 2
  end

  test "reports invalid incoming callback results" do
    Application.put_env(:tackle_lib, :llm, NoCallAdapter)
    Process.put(:test_pid, self())

    assert {:error, state} =
             Loop.run(State.new(model: "test/model"), "hello",
               take_incoming_messages: fn -> {:ok, [""]} end
             )

    assert state.status == :error
    assert state.error =~ "invalid_incoming_messages"
    refute_receive :llm_called, 20
  end

  test "does not consume incoming messages after cancellation" do
    Application.put_env(:tackle_lib, :llm, NoCallAdapter)
    Process.put(:test_pid, self())
    signal = Cancellation.new_signal()
    Cancellation.cancel(signal, "stop")

    assert {:cancelled, state} =
             Loop.run(State.new(model: "test/model"), "hello",
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
    assert_receive {:tool_signal, tool_signal}
    assert tool_signal == Cancellation.for_call(signal, "call_cancel")
    assert_receive {:event, %Event{type: :tool_end, data: %{name: "cancel_after"}}}

    # The never-started second call is settled with a synthetic result so the
    # transcript keeps the call/result pairing providers require on the next
    # request.
    tool_messages = Enum.filter(state.messages, &(&1.role == :tool))
    assert Enum.map(tool_messages, & &1.tool_call_id) == ["call_cancel", "call_second"]

    assert %Message{tool_call_id: "call_second", tool_name: "second"} =
             synthetic =
             Enum.find(tool_messages, &(&1.tool_call_id == "call_second"))

    assert synthetic.content =~ "cancelled before this call completed"

    assert_receive {:event,
                    %Event{
                      type: :tool_error,
                      data: %{tool_call_id: "call_second", reason: :interrupted}
                    }}

    assert_receive {:event, %Event{type: :status_change, data: %{status: :cancelled}}}
    assert_receive {:event, %Event{type: :turn_cancelled, data: %{reason: "stop requested"}}}
    refute_receive {:tool_execute, :second}, 20
  end

  describe "per-call cancellation" do
    setup do
      Application.put_env(:tackle_lib, :llm, StoppableToolAdapter)
      signal = Cancellation.new_signal()
      on_exit(fn -> Cancellation.delete(signal) end)
      %{signal: signal}
    end

    test "cancelling one sequential call stops only that call", %{signal: signal} do
      test_pid = self()

      state =
        State.new(model: "test/model", tools: [StoppableTool], context: %{test_pid: test_pid})

      run =
        Task.async(fn ->
          Loop.run(state, "run both",
            cancellation_signal: signal,
            event_callback: fn event -> send(test_pid, {:event, event}) end
          )
        end)

      assert_receive {:tool_entered, "one", "c1", call_signal, _pid}, 2_000
      assert call_signal == Cancellation.for_call(signal, "c1")
      assert call_signal.parent == signal

      Cancellation.cancel(call_signal, {:watchdog, "stopped by watchdog"})
      refute Cancellation.cancelled?(signal)

      assert_receive {:tool_entered, "two", "c2", second_signal, tool_pid}, 2_000
      refute Cancellation.cancelled?(second_signal)
      send(tool_pid, {:release, "two"})

      assert {:ok, final_state} = Task.await(run, 5_000)
      assert final_state.status == :completed

      assert [first, second] = Enum.filter(final_state.messages, &(&1.role == :tool))
      assert first.tool_call_id == "c1"
      assert first.content =~ "stopped by watchdog"
      assert second.tool_call_id == "c2"
      assert JSON.decode!(second.content) == %{"name" => "two"}

      assert_receive {:event,
                      %Event{type: :tool_error, data: %{tool_call_id: "c1", name: "stoppable"}}}

      # The loop deletes a settled call's cancellation record.
      assert Cancellation.reason(call_signal) == nil
    end

    test "cancelling one concurrent call leaves the rest of the batch running",
         %{signal: signal} do
      {:ok, supervisor} = Task.Supervisor.start_link()
      test_pid = self()

      state =
        State.new(
          model: "test/model",
          tools: [StoppableTool],
          tool_policy: Policy.concurrent(),
          context: %{test_pid: test_pid}
        )

      run =
        Task.async(fn ->
          Loop.run(state, "run both", tool_supervisor: supervisor, cancellation_signal: signal)
        end)

      assert_receive {:tool_entered, "one", "c1", first_signal, first_task}, 2_000
      assert_receive {:tool_entered, "two", "c2", second_signal, _second_task}, 2_000
      assert first_signal == Cancellation.for_call(signal, "c1")
      assert second_signal == Cancellation.for_call(signal, "c2")

      Cancellation.cancel(second_signal, :stop_two)
      refute Cancellation.cancelled?(first_signal)
      send(first_task, {:release, "one"})

      assert {:ok, final_state} = Task.await(run, 5_000)
      assert final_state.status == :completed
      assert [first, second] = Enum.filter(final_state.messages, &(&1.role == :tool))
      assert JSON.decode!(first.content) == %{"name" => "one"}
      assert second.content =~ "stopped: :stop_two"
      assert Cancellation.reason(second_signal) == nil
    end

    test "cancelling the turn signal still stops every call", %{signal: signal} do
      {:ok, supervisor} = Task.Supervisor.start_link()
      test_pid = self()

      state =
        State.new(
          model: "test/model",
          tools: [StoppableTool],
          tool_policy: Policy.concurrent(),
          context: %{test_pid: test_pid}
        )

      run =
        Task.async(fn ->
          Loop.run(state, "run both", tool_supervisor: supervisor, cancellation_signal: signal)
        end)

      assert_receive {:tool_entered, "one", "c1", first_signal, _first_task}, 2_000
      assert_receive {:tool_entered, "two", "c2", second_signal, _second_task}, 2_000

      Cancellation.cancel(signal, "stop turn")
      assert Cancellation.reason(first_signal) == "stop turn"
      assert Cancellation.reason(second_signal) == "stop turn"

      assert {:cancelled, final_state} = Task.await(run, 5_000)
      assert final_state.error == "stop turn"
    end
  end

  test "cancellation during before_tool_call prevents sequential tool dispatch" do
    Application.put_env(:tackle_lib, :llm, CancellingToolAdapter)
    Process.put(:test_pid, self())
    Process.put(:call_count, 0)
    signal = Cancellation.new_signal()

    state =
      State.new(
        model: "test/model",
        tools: [CancelAfterTool, SecondTool],
        hooks: [CancelBeforeToolHook],
        context: %{test_pid: self(), cancellation_signal: signal}
      )

    assert {:cancelled, final_state} =
             Loop.run(state, "tools", cancellation_signal: signal)

    assert final_state.status == :cancelled
    refute_receive {:tool_execute, _}

    assert Enum.map(Enum.filter(final_state.messages, &(&1.role == :tool)), & &1.tool_call_id) ==
             ["call_cancel", "call_second"]
  end

  test "cancellation during concurrent hook preparation prevents the whole batch dispatch" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    Application.put_env(:tackle_lib, :llm, ParallelToolAdapter)
    signal = Cancellation.new_signal()
    test_pid = self()

    state =
      State.new(
        model: "test/model",
        tools: [BlockingTool],
        hooks: [CancelBeforeToolHook],
        tool_policy: Policy.concurrent(),
        context: %{test_pid: test_pid, cancellation_signal: signal}
      )

    assert {:cancelled, final_state} =
             Loop.run(state, "tools", tool_supervisor: supervisor, cancellation_signal: signal)

    assert final_state.status == :cancelled
    refute_receive {:tool_entered, _, _}

    assert Enum.map(Enum.filter(final_state.messages, &(&1.role == :tool)), & &1.tool_call_id) ==
             ["c1", "c2"]
  end

  describe "tool execution gate" do
    defmodule ReadOnlyFirstTool do
      @behaviour Tackle.Lib.Tool

      @impl true
      def name, do: "first"

      @impl true
      def description, do: "Read-only first tool."

      @impl true
      def parameters_schema, do: []

      @impl true
      def effect, do: :read_only

      @impl true
      def execute(_args, %{test_pid: test_pid}) do
        send(test_pid, {:tool_execute, :first})
        {:ok, %{ok: true}}
      end
    end

    defmodule ReadOnlySecondTool do
      @behaviour Tackle.Lib.Tool

      @impl true
      def name, do: "second"

      @impl true
      def description, do: "Read-only second tool."

      @impl true
      def parameters_schema, do: []

      @impl true
      def effect, do: :read_only

      @impl true
      def execute(_args, %{test_pid: test_pid}) do
        send(test_pid, {:tool_execute, :second})
        {:ok, %{ok: true}}
      end
    end

    defmodule RecordToolCallHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def before_tool_call(_state, call, context) do
        send(context.test_pid, {:before_tool_call, call.id})
        :ok
      end
    end

    setup do
      Application.put_env(:tackle_lib, :llm, ToolCallingAdapter)
      Process.put(:call_count, 0)
      test_pid = self()

      gate = fn ->
        send(test_pid, :tool_gate)
        :ok
      end

      {:ok, gate: gate}
    end

    defp gate_state(opts \\ []) do
      State.new(
        Keyword.merge(
          [
            model: "test/model",
            tools: [FirstTool, SecondTool],
            hooks: [RecordToolCallHook],
            context: %{test_pid: self()}
          ],
          opts
        )
      )
    end

    defp drain_gate_trace(acc \\ []) do
      receive do
        {:before_tool_call, id} -> drain_gate_trace([{:hook, id} | acc])
        :tool_gate -> drain_gate_trace([:gate | acc])
        {:tool_execute, name} -> drain_gate_trace([{:tool, name} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "sequential policy passes the gate after each accepted call and before it runs", ctx do
      assert {:ok, _state} = Loop.run(gate_state(), "tools", before_tool_execution: ctx.gate)

      assert drain_gate_trace() == [
               {:hook, "call_first"},
               :gate,
               {:tool, :first},
               {:hook, "call_second"},
               :gate,
               {:tool, :second}
             ]
    end

    test "concurrent policy passes the gate once, after every hook and before any tool", ctx do
      {:ok, supervisor} = Task.Supervisor.start_link()

      assert {:ok, _state} =
               Loop.run(gate_state(tool_policy: Policy.concurrent()), "tools",
                 tool_supervisor: supervisor,
                 before_tool_execution: ctx.gate
               )

      assert [{:hook, "call_first"}, {:hook, "call_second"}, :gate | tools] =
               drain_gate_trace()

      assert Enum.sort(tools) == [{:tool, :first}, {:tool, :second}]
    end

    test "a failing gate aborts the step before any tool runs" do
      {:ok, supervisor} = Task.Supervisor.start_link()

      for policy <- [Policy.default(), Policy.concurrent()] do
        Process.put(:call_count, 0)

        assert {:error, state} =
                 Loop.run(gate_state(tool_policy: policy), "tools",
                   tool_supervisor: supervisor,
                   before_tool_execution: fn -> {:error, :storage_failed} end
                 )

        assert state.error =~ "Tool execution gate failed"
        assert state.error =~ "storage_failed"
        refute_received {:tool_execute, _}
      end
    end

    test "read-only calls skip the gate; one external call in a batch needs it", ctx do
      {:ok, supervisor} = Task.Supervisor.start_link()

      for policy <- [Policy.default(), Policy.concurrent()] do
        Process.put(:call_count, 0)
        state = gate_state(tools: [ReadOnlyFirstTool, ReadOnlySecondTool], tool_policy: policy)

        assert {:ok, _state} =
                 Loop.run(state, "tools",
                   tool_supervisor: supervisor,
                   before_tool_execution: ctx.gate
                 )

        refute :gate in drain_gate_trace()
      end

      Process.put(:call_count, 0)

      state =
        gate_state(tools: [ReadOnlyFirstTool, SecondTool], tool_policy: Policy.concurrent())

      assert {:ok, _state} =
               Loop.run(state, "tools",
                 tool_supervisor: supervisor,
                 before_tool_execution: ctx.gate
               )

      assert Enum.count(drain_gate_trace(), &(&1 == :gate)) == 1

      # Sequentially, only the external call is gated.
      Process.put(:call_count, 0)
      state = gate_state(tools: [ReadOnlyFirstTool, SecondTool])
      assert {:ok, _state} = Loop.run(state, "tools", before_tool_execution: ctx.gate)

      assert drain_gate_trace() == [
               {:hook, "call_first"},
               {:tool, :first},
               {:hook, "call_second"},
               :gate,
               {:tool, :second}
             ]
    end

    test "cancellation while the gate blocks prevents tool dispatch" do
      {:ok, supervisor} = Task.Supervisor.start_link()
      test_pid = self()

      for policy <- [Policy.default(), Policy.concurrent()] do
        signal = Cancellation.new_signal()
        on_exit(fn -> Cancellation.delete(signal) end)

        task =
          Task.async(fn ->
            Process.put(:call_count, 0)

            Loop.run(gate_state(tool_policy: policy, context: %{test_pid: test_pid}), "tools",
              tool_supervisor: supervisor,
              cancellation_signal: signal,
              before_tool_execution: fn ->
                send(test_pid, :tool_gate_entered)
                receive do: (:release_tool_gate -> :ok)
              end
            )
          end)

        assert_receive :tool_gate_entered
        Cancellation.cancel(signal, "cancelled at tool gate")
        send(task.pid, :release_tool_gate)
        assert {:cancelled, state} = Task.await(task, 2_000)
        assert state.error == "cancelled at tool gate"
        refute_received {:tool_execute, _}
      end
    end

    test "a raising gate is reported as a gate failure" do
      assert {:error, state} =
               Loop.run(gate_state(), "tools", before_tool_execution: fn -> raise "boom" end)

      assert state.error =~ "before_tool_execution_failed"
      refute_received {:tool_execute, _}
    end
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
      Application.put_env(:tackle_lib, :llm, FirstCallsToolThenAnswersAdapter)
      Process.put(:test_pid, self())
      :ok
    end

    defp turn_end_hook_state(context) do
      State.new(
        model: "test/model",
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
        State.new(model: "test/model", tools: [FirstTool], context: %{test_pid: self()})
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
      state = %{State.new(model: "test/model") | messages: [Message.user("hello")]}

      Application.put_env(:tackle_lib, :llm, TestAdapter)

      assert {:ok, _state} =
               Loop.continue(state, event_callback: &send(test_pid, {:event, &1}))

      assert [%Event{type: :turn_start} | _] = collect_events([])
    end

    test "an error before the provider call leaves no pending assistant message" do
      state = turn_end_hook_state(%{abort: :before_prompt})

      {{:error, state}, events} = run_collecting(state, "hello")

      assert state.pending_assistant_id == nil

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
      Application.put_env(:tackle_lib, :llm, TestAdapter)

      assert {:ok, state} =
               Loop.run(State.new(model: "test/model"), "hello",
                 event_callback: fn _event -> raise "observer bug" end
               )

      assert Tackle.Lib.last_answer(state) == "done"
    end

    test "queued messages are kept when finalizing one of them fails" do
      Application.put_env(:tackle_lib, :llm, TestAdapter)
      state = turn_end_hook_state(%{fail: :queued_message})

      assert {:error, state} =
               Loop.run(state, "hello",
                 take_incoming_messages: fn -> {:ok, ["queued a", "queued b"]} end
               )

      assert state.error == "Hook aborted after message: :journal_stalled"

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
        Application.put_env(:tackle_lib, :llm, adapter)
        Process.put(:test_pid, self())

        context = Map.merge(%{test_pid: self()}, extra_context)
        state = State.new(model: "test/model", hooks: [TerminalHook], context: context)

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
          model: "test/model",
          hooks: [FailingTerminalHook],
          context: %{test_pid: self()}
        )

      assert {:ok, final_state} = Loop.run(state, "hello")
      assert_receive {:after_turn_failed, :completed}
      refute_receive {:after_turn_failed, _}, 20
      assert final_state.context == state.context
    end

    test "continue runs terminal cleanup once" do
      state = State.new(model: "test/model", hooks: [TerminalHook], context: %{test_pid: self()})
      assert {:ok, final_state} = Loop.continue(state)
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
      # after_turn fires at the very end, once for the whole multi-step turn
      assert_receive {:hook_fired, :after_turn}
      refute_receive {:hook_fired, :after_turn}, 20
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
      # The before_prompt hook mutated the context, and it survives the turn
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
      assert state.status == :completed
    end

    test "successful and failed tool settlements share message, event, and hook ordering" do
      Application.put_env(:tackle_lib, :llm, HookTestAdapter)

      for {tools, event_type, settlement_type} <- [
            {[HookLoggingTool], :tool_end, Tackle.Lib.Tool.Result},
            {[], :tool_error, Tackle.Lib.Tool.Error}
          ] do
        Process.put(:llm_call_count, 0)

        state =
          State.new(
            model: "test/model",
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
    end

    test "after_message aborts both tool settlements before their event and after_tool_call" do
      Application.put_env(:tackle_lib, :llm, HookTestAdapter)

      for {tools, event_type} <- [
            {[HookLoggingTool], :tool_end},
            {[], :tool_error}
          ] do
        Process.put(:llm_call_count, 0)

        state =
          State.new(
            model: "test/model",
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
      Application.put_env(:tackle_lib, :llm, HookTestAdapter)
      Process.put(:llm_call_count, 0)

      state =
        State.new(
          model: "test/model",
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
        model: "test/model",
        hooks: Keyword.get(opts, :hooks, [GateHook]),
        tools: Keyword.get(opts, :tools, []),
        max_iterations: Keyword.get(opts, :max_iterations, :infinity),
        context: context
      )
    end

    test "continues the turn with the hook's messages, then completes" do
      Application.put_env(:tackle_lib, :llm, MessagesCapturingAdapter)
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
      Application.put_env(:tackle_lib, :llm, MessagesCapturingAdapter)
      Process.put(:test_pid, self())

      assert {:ok, state} = Loop.run(turn_end_state([{:continue, []}]), "hello")
      assert state.status == :completed
      assert state.current_iteration == 1
      assert_receive {:before_turn_end, :assistant, "done"}
      refute_receive {:before_turn_end, _, _}, 20
    end

    test "runs only after a final answer, not after a tool batch" do
      Application.put_env(:tackle_lib, :llm, StructuredMessagesCapturingAdapter)
      Process.put(:test_pid, self())
      Process.put(:call_count, 0)

      assert {:ok, _state} = Loop.run(turn_end_state([], tools: [FirstTool]), "hello")
      assert_receive {:tool_execute, :first}
      assert_receive {:before_turn_end, :assistant, "All done."}
      refute_receive {:before_turn_end, _, _}, 20
    end

    test "queued incoming messages are handled before the hooks run" do
      Application.put_env(:tackle_lib, :llm, MessagesCapturingAdapter)
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
      Application.put_env(:tackle_lib, :llm, MessagesCapturingAdapter)
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
      Application.put_env(:tackle_lib, :llm, MessagesCapturingAdapter)
      Process.put(:test_pid, self())

      assert {:error, state} = Loop.run(turn_end_state(:always, max_iterations: 3), "hello")
      assert state.status == :error
      assert state.error =~ "maximum iterations"
      assert state.current_iteration == 3
      assert_receive {:gate_after_turn, :always}
    end

    test "an error from the hook aborts the turn" do
      Application.put_env(:tackle_lib, :llm, MessagesCapturingAdapter)
      Process.put(:test_pid, self())

      assert {:error, state} = Loop.run(turn_end_state([{:error, :gate_crashed}]), "hello")
      assert state.status == :error
      assert state.error =~ "Hook aborted before turn end"
      assert state.error =~ "gate_crashed"
      assert_receive {:gate_after_turn, [{:error, :gate_crashed}]}
    end

    test "invalid messages abort the turn" do
      Application.put_env(:tackle_lib, :llm, MessagesCapturingAdapter)
      Process.put(:test_pid, self())

      assert {:error, state} = Loop.run(turn_end_state([{:continue, [""]}]), "hello")
      assert state.error =~ "invalid messages"
      assert state.current_iteration == 1
    end

    test "cancellation during the hook cancels instead of continuing" do
      Application.put_env(:tackle_lib, :llm, MessagesCapturingAdapter)
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
      Application.put_env(:tackle_lib, :llm, PermanentFailureAdapter)
      Process.put(:test_pid, self())

      assert {:error, _state} = Loop.run(turn_end_state([]), "hello")
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
      Application.put_env(:tackle_lib, :llm, MessagesCapturingAdapter)
      Process.put(:test_pid, self())
      signal = Cancellation.new_signal()

      state = State.new(model: "test/model", hooks: [SignalHook], context: %{test_pid: self()})
      assert {:ok, state} = Loop.run(state, "hello", cancellation_signal: signal)

      assert_receive {:signal_in, :before_prompt, ^signal}
      assert_receive {:signal_in, :before_turn_end, ^signal}
      assert_receive {:signal_in, :after_turn, nil}
      assert state.context.seen_prompt
      assert state.context.seen_turn_end
      refute Map.has_key?(state.context, :cancellation_signal)
    end

    test "a host's own :cancellation_signal context entry is kept" do
      Application.put_env(:tackle_lib, :llm, MessagesCapturingAdapter)
      Process.put(:test_pid, self())

      state =
        State.new(
          model: "test/model",
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
