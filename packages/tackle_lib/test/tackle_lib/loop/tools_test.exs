defmodule Tackle.Lib.Loop.ToolsTest do
  # Tool execution (`Tackle.Lib.Loop.Tools`), driven through `Tackle.Lib.Loop.run/3`.
  use ExUnit.Case, async: false

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.JSON
  alias Tackle.Lib.Loop
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Policy

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

      # An interrupted call is reported like any other tool error.
      assert_receive {:event,
                      %Event{
                        type: :tool_error,
                        data: %{
                          tool_call_id: "c1",
                          name: "blocking",
                          error: "Tool execution was cancelled before this call completed.",
                          reason: :interrupted,
                          details: nil,
                          metadata: %{}
                        }
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

  describe "unresolvable calls" do
    defmodule UnresolvableCallsAdapter do
      @behaviour Tackle.Lib.LLM

      @impl true
      def generate(_schema, opts) do
        if Enum.any?(Keyword.fetch!(opts, :messages), &(&1.role == :tool)) do
          {:ok, %{data: %{"content" => "done"}, usage: nil, model: "test/model"}}
        else
          calls = [
            %{"id" => "unknown", "name" => "missing", "arguments" => %{}},
            %{"id" => "stale", "name" => "first", "arguments" => %{}, "definition_id" => "old"}
          ]

          {:ok, %{data: %{"tool_calls" => calls}, usage: nil, model: "test/model"}}
        end
      end
    end

    test "settle as tool errors under both policies without running a tool" do
      Application.put_env(:tackle_lib, :llm, UnresolvableCallsAdapter)
      {:ok, supervisor} = Task.Supervisor.start_link()
      test_pid = self()

      for policy <- [Policy.default(), Policy.concurrent()] do
        state =
          State.new(
            model: "test/model",
            tools: [FirstTool],
            tool_policy: policy,
            context: %{test_pid: test_pid}
          )

        assert {:ok, final_state} =
                 Loop.run(state, "call them",
                   tool_supervisor: supervisor,
                   event_callback: &send(test_pid, {:event, &1})
                 )

        assert [unknown, stale] = Enum.filter(final_state.messages, &(&1.role == :tool))
        assert unknown.content == "Error: Unknown tool: missing"
        assert stale.content =~ "Error: Stale tool definition for first"

        assert_receive {:event,
                        %Event{type: :tool_error, data: %{tool_call_id: "unknown"} = unknown}}

        assert unknown.reason == :unknown_tool
        assert unknown.metadata == %{definition_id: nil}

        assert_receive {:event, %Event{type: :tool_error, data: %{tool_call_id: "stale"} = stale}}

        assert stale.reason == :stale_tool_definition
        assert stale.metadata == %{definition_id: "old"}
        refute_received {:tool_execute, _}
      end
    end
  end

  describe "a rejecting before_tool_call hook" do
    defmodule RejectSecondCallHook do
      @behaviour Tackle.Lib.Hook

      @impl true
      def before_tool_call(_state, %{id: "call_second"}, _context), do: {:error, :rejected}

      # Cancels the accepted call's own signal, which only the loop deletes
      # again when the call will not run.
      def before_tool_call(_state, call, %{cancellation_signal: signal}) do
        Cancellation.cancel(Cancellation.for_call(signal, call.id), :marked)
        :ok
      end
    end

    setup do
      Application.put_env(:tackle_lib, :llm, ToolCallingAdapter)
      Process.put(:call_count, 0)
      signal = Cancellation.new_signal()
      on_exit(fn -> Cancellation.delete(signal) end)
      %{signal: signal}
    end

    test "under the sequential policy stops after the calls before it", %{signal: signal} do
      test_pid = self()

      state =
        State.new(
          model: "test/model",
          tools: [FirstTool, SecondTool],
          hooks: [RejectSecondCallHook],
          context: %{test_pid: test_pid}
        )

      assert {:error, final_state} =
               Loop.run(state, "tools",
                 cancellation_signal: signal,
                 event_callback: &send(test_pid, {:event, &1})
               )

      assert final_state.error == "Hook aborted before tool call: :rejected"
      assert final_state.error_reason == :rejected
      assert_receive {:tool_execute, :first}
      refute_received {:tool_execute, :second}

      assert tool_events() == [
               {:tool_start, "call_first"},
               {:tool_execution_end, "call_first"},
               {:tool_end, "call_first"},
               {:tool_error, "call_second"}
             ]

      assert [_first, aborted] = Enum.filter(final_state.messages, &(&1.role == :tool))
      assert aborted.content =~ "aborted before this call completed"
    end

    test "under the concurrent policy stops the whole batch", %{signal: signal} do
      {:ok, supervisor} = Task.Supervisor.start_link()
      test_pid = self()

      state =
        State.new(
          model: "test/model",
          tools: [FirstTool, SecondTool],
          hooks: [RejectSecondCallHook],
          tool_policy: Policy.concurrent(),
          context: %{test_pid: test_pid}
        )

      assert {:error, final_state} =
               Loop.run(state, "tools",
                 cancellation_signal: signal,
                 tool_supervisor: supervisor,
                 event_callback: &send(test_pid, {:event, &1})
               )

      assert final_state.error == "Hook aborted before tool call: :rejected"
      refute_received {:tool_execute, _}

      assert tool_events() == [
               {:tool_start, "call_first"},
               {:tool_error, "call_first"},
               {:tool_error, "call_second"}
             ]

      # The started call never ran, and its cancellation record is gone.
      assert Cancellation.reason(Cancellation.for_call(signal, "call_first")) == nil
    end

    defp tool_events(acc \\ []) do
      receive do
        {:event, %Event{type: type, data: %{tool_call_id: id}}}
        when type in [:tool_start, :tool_execution_end, :tool_end, :tool_error] ->
          tool_events([{type, id} | acc])

        {:event, _event} ->
          tool_events(acc)
      after
        0 -> Enum.reverse(acc)
      end
    end
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
        assert state.error_reason == :storage_failed
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
end
