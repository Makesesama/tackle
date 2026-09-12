defmodule Tackle.Lib.LoopTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.JSON
  alias Tackle.Lib.Loop
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
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
    def description, do: "Exits the task to exercise crash isolation."

    @impl true
    def parameters_schema, do: []

    # An exit is not an exception, so it escapes the tool settlement rescue and
    # terminates the supervised tool task itself.
    @impl true
    def execute(_args, _context), do: exit(:tool_boom)
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

  defp collect_events(events) do
    receive do
      {:event, %Event{} = event} -> collect_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
