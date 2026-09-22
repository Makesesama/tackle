defmodule Tackle.Phoenix.RunnerTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.State
  alias Tackle.Lib.Usage
  alias Tackle.Phoenix.EventReducer
  alias Tackle.Phoenix.Runner

  @pubsub __MODULE__.PubSub
  @registry __MODULE__.Registry
  @dynamic_supervisor __MODULE__.DynamicSupervisor
  @task_supervisor __MODULE__.TaskSupervisor

  defmodule CorrelationAgent do
    @moduledoc false

    alias Tackle.Lib.Event
    alias Tackle.Lib.Message
    alias Tackle.Lib.State

    def continue(%State{} = state, opts) do
      event_callback = Keyword.fetch!(opts, :event_callback)
      assistant = Message.assistant(id: "assistant-message", content: "done")

      event_callback.(Event.message_start(id: assistant.id))
      event_callback.(Event.message_end(assistant))

      {:ok, State.add_message(state, assistant)}
    end
  end

  defmodule CrashingAgent do
    @moduledoc false

    def continue(_state, _opts), do: exit(:correlation_crash)
  end

  defmodule CorrelationStore do
    @moduledoc false
    @behaviour Tackle.Phoenix.Store

    @impl true
    def init_host(host_state) do
      notify(host_state, :init_host)
      host_state
    end

    @impl true
    def handle_host_message(host_state, {:deliver, input, message_id}) do
      notify(host_state, {:handle_host_message, message_id})

      {:run_turn, host_state, input,
       session_id: host_state.session_id,
       user_message_id: message_id,
       pre_persisted_message?: true,
       turn_metadata: %{kind: "initial_request", source_session_id: "parent-session"}}
    end

    def handle_host_message(_host_state, _message), do: :unhandled

    @impl true
    def before_turn(host_state, opts) do
      notify(host_state, {:before_turn, opts})
      :ok
    end

    @impl true
    def enrich_state(host_state, agent_state, opts) do
      notify(host_state, {:enrich_state, opts})
      agent_state
    end

    @impl true
    def persist_user_message(host_state, _agent_state, message) do
      notify(host_state, {:persist_user_message, message})
      host_state
    end

    @impl true
    def persist_pending_message(host_state, data, opts) do
      notify(host_state, {:persist_pending_message, data, opts})
      host_state
    end

    @impl true
    def settle_turn(host_state, result, usage, opts) do
      notify(host_state, {:settle_turn, result, usage, opts})
      host_state
    end

    @impl true
    def after_turn(host_state, result, opts) do
      notify(host_state, {:after_turn, result, opts})
      host_state
    end

    @impl true
    def current_session_id(host_state), do: host_state.session_id

    @impl true
    def handle_turn_failed(host_state, reason, opts) do
      notify(host_state, {:handle_turn_failed, reason, opts})
      {host_state, nil}
    end

    defp notify(%{test_pid: test_pid}, message), do: send(test_pid, {:store, message})
  end

  test "snapshot retains only visible in-flight content and retries discard the partial answer" do
    messages = %{}
    start = Event.message_start(id: "answer")
    text = Event.new(:message_delta, %{delta: "Hel"}, id: "answer")
    reasoning = Event.new(:message_delta, %{delta: "secret", field: :reasoning}, id: "answer")
    tool = Event.new(:message_delta, %{delta: "{}", field: :tool_input}, id: "answer")

    messages =
      Enum.reduce(
        [start, text, reasoning, tool],
        messages,
        &EventReducer.project_streaming(&2, &1)
      )

    assert messages == %{"answer" => %{content: "Hel"}}

    assert EventReducer.project_streaming(
             messages,
             Event.new(:retry_scheduled, %{}, id: "answer")
           ) == %{}

    assert EventReducer.project_streaming(
             messages,
             Event.message_end(Tackle.Lib.Message.assistant(id: "answer", content: "Hello"))
           ) == %{}
  end

  test "runner snapshot replays in-flight text after subscribers join" do
    config = correlation_runner_config(Tackle.Phoenix.RunnerShutdownAgent)
    agent_state = %State{context: %{test_pid: self(), persistence: %{}}}
    host_state = %{test_pid: self(), session_id: "stream-session"}

    assert {:ok, runner} =
             Runner.run_turn(config, "stream-user", agent_state, "Hi",
               session_id: "stream-session",
               agent_state: agent_state,
               host_state: host_state
             )

    assert_receive {:runner_shutdown_agent_started, _pid, _signal}
    send(runner, {:tackle_event, Event.message_start(id: "answer")})
    send(runner, {:tackle_event, Event.new(:message_delta, %{delta: "Hello"}, id: "answer")})

    send(
      runner,
      {:tackle_event,
       Event.new(:message_delta, %{delta: "private", field: :reasoning}, id: "answer")}
    )

    assert %{streaming_messages: %{"answer" => %{content: "Hello"}}} = Runner.snapshot(runner)
    assistant = Tackle.Lib.Message.assistant(id: "answer", content: "Hello!")
    send(runner, {:tackle_event, Event.message_end(assistant)})

    assert %{agent_state: %State{messages: [_user, ^assistant]}, streaming_messages: %{}} =
             Runner.snapshot(runner)

    send(runner, {:tackle_event, Event.message_start(id: "retry")})

    send(
      runner,
      {:tackle_event, Event.new(:message_delta, %{delta: "discard", id: "retry"}, id: "retry")}
    )

    send(runner, {:tackle_event, Event.new(:retry_scheduled, %{}, id: "retry")})
    assert %{streaming_messages: %{}} = Runner.snapshot(runner)
    :ok = Runner.cancel_turn(runner)
  end

  test "retry events clear only the provisional streaming message" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        streaming_messages: %{
          "pending-message" => %{content: "partial"},
          "other-message" => %{content: "settled elsewhere"}
        }
      }
    }

    event = Event.new(:retry_scheduled, %{attempt: 1}, id: "pending-message")
    socket = EventReducer.handle_tackle_event(socket, event)

    assert socket.assigns.streaming_messages == %{
             "other-message" => %{content: "settled elsewhere"}
           }
  end

  setup do
    {:ok, _started} = Application.ensure_all_started(:phoenix_pubsub)
    start_supervised!({Phoenix.PubSub, name: @pubsub})
    start_supervised!({Registry, keys: :unique, name: @registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @dynamic_supervisor})
    start_supervised!({Task.Supervisor, name: @task_supervisor})
    :ok
  end

  test "session runners are temporary supervisor children" do
    assert %{restart: :temporary} =
             Supervisor.child_spec({Runner, {:config, "user", "session", %State{}, :host}}, [])
  end

  test "optional host mailbox callbacks start an ordinary correlated turn" do
    config = correlation_runner_config(CorrelationAgent)
    agent_state = %State{context: %{persistence: %{}}}
    host_state = %{test_pid: self(), session_id: "mailbox-child"}

    :ok = Runner.subscribe(config, "mailbox-user", "mailbox-child")

    assert {:ok, runner_pid} =
             Runner.get_or_start(config, "mailbox-user",
               session_id: "mailbox-child",
               agent_state: agent_state,
               host_state: host_state
             )

    assert_receive {:store, :init_host}

    send(runner_pid, {:deliver, "from the host mailbox", "mailbox-message"})

    assert_receive {:store, {:handle_host_message, "mailbox-message"}}
    assert_receive {:store, {:before_turn, before_opts}}
    assert Keyword.fetch!(before_opts, :user_message_id) == "mailbox-message"
    refute_receive {:store, {:persist_user_message, _message}}

    assert_receive {:store, {:settle_turn, {:ok, final_state}, %Usage{}, settle_opts}}
    assert Keyword.fetch!(settle_opts, :pre_persisted_message?)
    assert [%{id: "mailbox-message"}, %{id: "assistant-message"}] = final_state.messages
    assert_receive {:agent_turn_done, {:ok, ^final_state}}
  end

  test "forwards stable pre-persisted message correlation through the Store lifecycle" do
    config = correlation_runner_config(CorrelationAgent)
    agent_state = %State{context: %{persistence: %{}}}
    host_state = %{test_pid: self(), session_id: "child-session"}

    :ok = Runner.subscribe(config, "child-user", "child-session")

    assert {:ok, runner_pid} =
             Runner.run_turn(config, "child-user", agent_state, "delegated request",
               session_id: "child-session",
               agent_state: agent_state,
               host_state: host_state,
               user_message_id: "persisted-user-message",
               pre_persisted_message?: true,
               turn_metadata: %{
                 "kind" => "initial_request",
                 "source_session_id" => "parent-session"
               }
             )

    assert_receive {:store, {:before_turn, before_opts}}
    assert_correlation(before_opts)

    assert_receive {:store, {:enrich_state, enrich_opts}}
    assert_correlation(enrich_opts)

    refute_receive {:store, {:persist_user_message, _message}}

    assert_receive {:agent_event,
                    %Event{type: :message_end, data: %{message: %{id: "persisted-user-message"}}}}

    assert_receive {:store, {:persist_pending_message, %{id: "assistant-message"}, pending_opts}}
    assert_correlation(pending_opts)

    assert_receive {:store, {:settle_turn, {:ok, final_state}, %Usage{}, settle_opts}}
    assert_correlation(settle_opts)

    assert [%{id: "persisted-user-message", role: :user}, %{id: "assistant-message"}] =
             final_state.messages

    assert MapSet.member?(
             final_state.context.persistence.persisted_ids,
             "persisted-user-message"
           )

    assert_receive {:store, {:after_turn, {:ok, ^final_state}, after_opts}}
    assert_correlation(after_opts)
    assert_receive {:agent_turn_done, {:ok, ^final_state}}

    assert %{turn_active?: false, runner_pid: nil} = Runner.snapshot(runner_pid)
  end

  test "runs multiple independently correlated sessions through the ordinary Runner path" do
    config = correlation_runner_config(CorrelationAgent)
    agent_state = %State{context: %{persistence: %{}}}

    for index <- 1..2 do
      session_id = "child-session-#{index}"

      assert {:ok, _runner_pid} =
               Runner.run_turn(config, "multi-user", agent_state, "request #{index}",
                 session_id: session_id,
                 agent_state: agent_state,
                 host_state: %{test_pid: self(), session_id: session_id},
                 user_message_id: "child-message-#{index}",
                 pre_persisted_message?: true,
                 turn_metadata: %{
                   kind: "initial_request",
                   source_session_id: "parent-session"
                 }
               )
    end

    settled_message_ids =
      for _index <- 1..2 do
        assert_receive {:store, {:settle_turn, {:ok, _state}, %Usage{}, opts}}
        Keyword.fetch!(opts, :user_message_id)
      end

    assert MapSet.new(settled_message_ids) ==
             MapSet.new(["child-message-1", "child-message-2"])
  end

  test "normal turns persist a generated user message and forward its effective id" do
    config = correlation_runner_config(CorrelationAgent)
    agent_state = %State{context: %{persistence: %{}}}
    host_state = %{test_pid: self(), session_id: "normal-session"}

    assert {:ok, _runner_pid} =
             Runner.run_turn(config, "normal-user", agent_state, "normal request",
               session_id: "normal-session",
               agent_state: agent_state,
               host_state: host_state
             )

    assert_receive {:store, {:before_turn, _opts}}
    assert_receive {:store, {:enrich_state, _opts}}
    assert_receive {:store, {:persist_user_message, %{id: user_message_id}}}
    assert is_binary(user_message_id)

    assert_receive {:store, {:persist_pending_message, _data, pending_opts}}
    assert Keyword.fetch!(pending_opts, :user_message_id) == user_message_id
    refute Keyword.fetch!(pending_opts, :pre_persisted_message?)
    assert Keyword.fetch!(pending_opts, :turn_metadata) == %{}

    assert_receive {:store, {:settle_turn, {:ok, _state}, %Usage{}, settle_opts}}
    assert Keyword.fetch!(settle_opts, :user_message_id) == user_message_id

    assert_receive {:store, {:after_turn, {:ok, _state}, after_opts}}
    assert Keyword.fetch!(after_opts, :user_message_id) == user_message_id
  end

  test "preserves stable correlation when a pre-persisted turn is cancelled" do
    config = correlation_runner_config(Tackle.Phoenix.RunnerShutdownAgent)

    agent_state = %State{
      context: %{test_pid: self(), persistence: %{}}
    }

    host_state = %{test_pid: self(), session_id: "cancelled-session"}

    assert {:ok, runner_pid} =
             Runner.run_turn(config, "cancelled-user", agent_state, "cancel",
               session_id: "cancelled-session",
               agent_state: agent_state,
               host_state: host_state,
               user_message_id: "cancelled-message",
               pre_persisted_message?: true,
               turn_metadata: %{kind: "parent_reply", source_session_id: "parent-session"}
             )

    assert_receive {:store, {:before_turn, _opts}}
    assert_receive {:store, {:enrich_state, _opts}}
    assert_receive {:runner_shutdown_agent_started, task_pid, _signal}

    :ok = Runner.cancel_turn(runner_pid)

    assert_receive {:runner_shutdown_agent_cancelled, ^task_pid}
    assert_receive {:store, {:settle_turn, {:cancelled, _state}, %Usage{}, settle_opts}}
    assert_correlation(settle_opts, "cancelled-message", "parent_reply")

    assert_receive {:store, {:after_turn, {:cancelled, _state}, after_opts}}
    assert_correlation(after_opts, "cancelled-message", "parent_reply")
  end

  test "forwards stable correlation to failure handling" do
    config = correlation_runner_config(CrashingAgent)
    agent_state = %State{context: %{persistence: %{}}}
    host_state = %{test_pid: self(), session_id: "failed-session"}

    :ok = Runner.subscribe(config, "failed-user", "failed-session")

    assert {:ok, _runner_pid} =
             Runner.run_turn(config, "failed-user", agent_state, "fail",
               session_id: "failed-session",
               agent_state: agent_state,
               host_state: host_state,
               user_message_id: "failed-message",
               pre_persisted_message?: true,
               turn_metadata: %{kind: "parent_reply", source_session_id: "parent-session"}
             )

    assert_receive {:store, {:before_turn, _opts}}
    assert_receive {:store, {:enrich_state, _opts}}

    assert_receive {:store, {:handle_turn_failed, :correlation_crash, failure_opts}}
    assert_correlation(failure_opts, "failed-message", "parent_reply")
    assert %Usage{} = Keyword.fetch!(failure_opts, :turn_usage)
    assert_receive {:agent_turn_failed, :correlation_crash}
  end

  test "rejects malformed or unbounded turn correlation before starting a runner" do
    config = correlation_runner_config(CorrelationAgent)
    agent_state = %State{}

    invalid_options = [
      [user_message_id: ""],
      [user_message_id: String.duplicate("m", 256)],
      [pre_persisted_message?: true],
      [pre_persisted_message?: :yes],
      [turn_metadata: %{kind: "initial_request"}],
      [
        turn_metadata: %{
          kind: String.duplicate("k", 65),
          source_session_id: "parent-session"
        }
      ],
      [
        turn_metadata: %{
          kind: "initial_request",
          source_session_id: String.duplicate("s", 256)
        }
      ],
      [
        turn_metadata: %{
          kind: "initial_request",
          source_session_id: "parent-session",
          extra: "not allowed"
        }
      ]
    ]

    for opts <- invalid_options do
      assert {:error, {:invalid_turn_option, _field}} =
               Runner.run_turn(config, "invalid-user", agent_state, "request", opts)
    end

    assert [] = Registry.lookup(@registry, {:current, "invalid-user"})
  end

  test "allows a Store to omit the optional pending-message callback" do
    state = runner_state()
    event = Event.message_start(id: "pending-message")

    assert {:noreply, returned_state, _timeout} =
             Runner.handle_info({:tackle_event, event}, state)

    assert returned_state.host_state == state.host_state
  end

  test "keeps provider usage when a turn ends before step settlement" do
    state = runner_state()
    usage = %Usage{input_tokens: 2, output_tokens: 8, total_tokens: 10}

    assert {:noreply, state, _timeout} =
             Runner.handle_info({:tackle_event, Event.usage(usage)}, state)

    assert %{pending_step: ^usage} = state.turn_usage
  end

  test "deduplicates provider and step settlement usage" do
    state = runner_state()
    usage = %Usage{input_tokens: 2, output_tokens: 8, total_tokens: 10}

    {:noreply, state, _timeout} =
      Runner.handle_info({:tackle_event, Event.usage(usage)}, state)

    {:noreply, state, _timeout} =
      Runner.handle_info({:tackle_event, Event.usage(usage)}, state)

    step_end = Event.new(:step_end, %{iteration: 0, usage: usage})
    {:noreply, state, _timeout} = Runner.handle_info({:tackle_event, step_end}, state)

    assert %{0 => ^usage} = state.turn_usage
    assert map_size(state.turn_usage) == 1
  end

  test "rejecting a concurrent turn preserves the accepted turn telemetry state" do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:tackle, :phoenix, :turn, :stop],
        fn event, measurements, metadata, pid -> send(pid, {event, measurements, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    accepted_ref = make_ref()
    rejected_ref = make_ref()

    state = %{
      runner_state()
      | turn_task: %Task{
          ref: make_ref(),
          mfa: {__MODULE__, :current_session_id, [:host]},
          owner: self(),
          pid: self()
        },
        turn_telemetry_ref: accepted_ref,
        turn_operation: :run,
        turn_started_at: System.monotonic_time(),
        turn_stats: %{iterations: 2, tool_call_count: 1}
    }

    assert {:reply, {:error, :turn_in_progress}, returned_state, _timeout} =
             Runner.handle_call(
               {:continue_turn, %State{},
                turn_telemetry_ref: rejected_ref, turn_started_at: System.monotonic_time()},
               self(),
               state
             )

    assert returned_state.turn_telemetry_ref == accepted_ref
    assert returned_state.turn_operation == :run

    assert_receive {[:tackle, :phoenix, :turn, :stop], _measurements,
                    %{telemetry_ref: ^rejected_ref, outcome: :rejected}}

    refute_receive {[:tackle, :phoenix, :turn, :stop], _measurements,
                    %{telemetry_ref: ^accepted_ref}}
  end

  test "snapshot reports the active lifecycle and state replacement fails safe while busy" do
    config = shutdown_runner_config()
    agent_state = %State{context: %{test_pid: self(), persistence: %{}}}

    :ok = Runner.subscribe(config, "snapshot-user", "shutdown-session")

    assert {:ok, runner_pid} =
             Runner.run_turn(config, "snapshot-user", agent_state, "start",
               session_id: "shutdown-session",
               agent_state: agent_state
             )

    assert_receive {:runner_shutdown_agent_started, _task_pid, _signal}

    assert %{
             agent_state: %State{messages: [_user_message]},
             session_id: "shutdown-session",
             turn_active?: true,
             runner_pid: ^runner_pid
           } = Runner.snapshot(config, "snapshot-user", session_id: "shutdown-session")

    assert {:error, :turn_in_progress} = Runner.replace_state(runner_pid, %State{}, :replacement)

    :ok = Runner.cancel_turn(runner_pid)
    assert_receive {:runner_shutdown_agent_cancelled, _task_pid}
    assert_receive {:agent_turn_done, {:cancelled, %State{}}}

    assert %{turn_active?: false, runner_pid: nil} =
             Runner.snapshot(config, "snapshot-user", session_id: "shutdown-session")
  end

  test "supervisor shutdown settles a cooperative cancellation with correlation" do
    config = correlation_runner_config(Tackle.Phoenix.RunnerShutdownAgent)

    agent_state = %State{
      context: %{test_pid: self(), persistence: %{}}
    }

    host_state = %{test_pid: self(), session_id: "terminated-session"}

    assert {:ok, runner_pid} =
             Runner.run_turn(config, "terminated-user", agent_state, "terminate",
               session_id: "terminated-session",
               agent_state: agent_state,
               host_state: host_state,
               user_message_id: "terminated-message",
               pre_persisted_message?: true,
               turn_metadata: %{kind: "parent_reply", source_session_id: "parent-session"}
             )

    assert_receive {:store, {:before_turn, _opts}}
    assert_receive {:store, {:enrich_state, _opts}}
    assert_receive {:runner_shutdown_agent_started, task_pid, _signal}

    runner_ref = Process.monitor(runner_pid)
    Process.exit(runner_pid, :shutdown)

    assert_receive {:runner_shutdown_agent_cancelled, ^task_pid}
    assert_receive {:store, {:settle_turn, {:cancelled, _state}, %Usage{}, settle_opts}}
    assert_correlation(settle_opts, "terminated-message", "parent_reply")

    assert_receive {:store, {:after_turn, {:cancelled, _state}, after_opts}}
    assert_correlation(after_opts, "terminated-message", "parent_reply")
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :shutdown}
  end

  test "supervisor shutdown cancels, awaits, and cleans up an active turn" do
    config = shutdown_runner_config()
    agent_state = %State{context: %{test_pid: self(), persistence: %{}}}

    assert {:ok, runner_pid} =
             Runner.run_turn(config, "shutdown-user", agent_state, "start",
               session_id: "shutdown-session",
               agent_state: agent_state
             )

    assert_receive {:runner_shutdown_agent_started, task_pid, signal}
    assert Process.alive?(task_pid)

    task_ref = Process.monitor(task_pid)
    runner_ref = Process.monitor(runner_pid)
    Process.exit(runner_pid, :shutdown)

    assert_receive {:runner_shutdown_agent_cancelled, ^task_pid}
    assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :normal}
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :shutdown}
    assert Cancellation.reason(signal) == nil
  end

  test "termination closes an active turn telemetry lifecycle" do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:tackle, :phoenix, :turn, :exception],
        fn event, measurements, metadata, pid -> send(pid, {event, measurements, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    telemetry_ref = make_ref()

    assert :ok =
             Runner.terminate(:shutdown, %{
               runner_state()
               | turn_telemetry_ref: telemetry_ref,
                 turn_operation: :run,
                 turn_started_at: System.monotonic_time()
             })

    assert_receive {[:tackle, :phoenix, :turn, :exception], %{duration: duration, count: 1},
                    %{telemetry_ref: ^telemetry_ref, error_type: :runner_terminated}}

    assert is_integer(duration)
  end

  test "collects usage when a provider only reports total tokens" do
    state = runner_state()
    usage = %Usage{total_tokens: 10}

    assert {:noreply, state, _timeout} =
             Runner.handle_info({:tackle_event, Event.usage(usage)}, state)

    assert %{pending_step: ^usage} = state.turn_usage
  end

  def current_session_id(_host_state), do: "session-1"

  defp assert_correlation(
         opts,
         message_id \\ "persisted-user-message",
         kind \\ "initial_request"
       ) do
    assert Keyword.fetch!(opts, :user_message_id) == message_id
    assert Keyword.fetch!(opts, :pre_persisted_message?)

    assert Keyword.fetch!(opts, :turn_metadata) == %{
             kind: kind,
             source_session_id: "parent-session"
           }
  end

  defp correlation_runner_config(agent) do
    %{
      registry: @registry,
      dynamic_supervisor: @dynamic_supervisor,
      task_supervisor: @task_supervisor,
      pubsub: @pubsub,
      store: CorrelationStore,
      agent: agent
    }
  end

  defp shutdown_runner_config do
    %{
      registry: @registry,
      dynamic_supervisor: @dynamic_supervisor,
      task_supervisor: @task_supervisor,
      pubsub: @pubsub,
      store: Tackle.Phoenix.RunnerShutdownStore,
      agent: Tackle.Phoenix.RunnerShutdownAgent
    }
  end

  defp runner_state do
    %{
      config: %{
        pubsub: @pubsub,
        store: __MODULE__
      },
      user_id: "user-1",
      initial_session_id: "session-1",
      host_state: :host,
      turn_task: nil,
      turn_signal: nil,
      turn_usage: %{},
      turn_telemetry_ref: nil,
      turn_operation: nil,
      turn_started_at: nil,
      turn_metadata: %{},
      turn_opts: [],
      turn_stats: %{iterations: 0, tool_call_count: 0}
    }
  end
end
