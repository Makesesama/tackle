defmodule Tackle.Session.StoragePauseTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.LLM.Error
  alias Tackle.Runtime
  alias Tackle.Runtime.{Envelope, Messaging}
  alias Tackle.Session
  alias Tackle.Session.{Journal, JournalRegistry, Spec}
  alias Tackle.Test.Adapter

  defmodule ManualRetryAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    defdelegate adapter_id(), to: Adapter

    @impl true
    defdelegate models(), to: Adapter

    @impl true
    defdelegate model_info(model), to: Adapter

    @impl true
    def generate(_schema, opts) do
      send(opts[:test_pid], {:adapter_called, self(), opts[:model], opts})

      receive do
        {:fail, reason} ->
          {:error, reason}

        {:respond, content} ->
          {:ok, %{data: %{"content" => content}, usage: nil, model: opts[:model]}}
      end
    end
  end

  defmodule HoldToolHook do
    @behaviour Tackle.Lib.Hook

    @impl true
    def before_tool_call(_state, _call, context) do
      send(context.test_pid, {:intent_pending, self()})
      receive do: (:release_intent -> :ok)
    end
  end

  test "a provider retry waits behind outstanding storage even without another message" do
    scope = configured_scope(providers: [ManualRetryAdapter], retry: [base_delay_ms: 0])
    root = scope.root_agent_ref
    {:ok, snapshot} = Tackle.subscribe(root)
    {:ok, turn} = Tackle.submit(root, "seed")
    assert_receive {:adapter_called, provider, _, _}
    log = {:tackle_session, snapshot.session_id}
    :ok = :disk_log.block(log, true)

    try do
      sync = Task.async(fn -> Journal.flush(Journal.via(snapshot.session_id)) end)
      assert_storage(snapshot.session_id, :delayed)
      send(provider, {:fail, Error.from_transport(:timeout)})
      assert_receive {:tackle_event, _, ^turn, %Tackle.Lib.Event{type: :retry_start}}, 5_000
      await_queued(snapshot.session_id)
      refute_receive {:adapter_called, _, _, _}, 150
      assert {:ok, %{storage: :delayed}} = Tackle.snapshot(root)
      :ok = :disk_log.unblock(log)
      assert Task.await(sync) == :ok
      assert_receive {:adapter_called, retry_provider, _, _}, 5_000
      send(retry_provider, {:respond, "recovered"})
      assert_receive {:tackle_turn_finished, _, ^turn, {:ok, _}}, 5_000
    after
      :disk_log.unblock(log)
    end
  end

  test "cancellation during pending tool-intent durability prevents dispatch on recovery" do
    call = %{id: "call-paused", name: "blocking", arguments: %{name: "must not run"}}

    scope =
      configured_scope(
        tools: [Tackle.Test.BlockingTool],
        hooks: [HoldToolHook],
        context: %{test_pid: self()},
        llm_opts: [mode: :tool_then_answer, tool_call: call]
      )

    root = scope.root_agent_ref
    {:ok, snapshot} = Tackle.subscribe(root)
    {:ok, turn} = Tackle.submit(root, "use a tool")
    assert_receive {:intent_pending, provider}, 5_000
    log = {:tackle_session, snapshot.session_id}
    :ok = :disk_log.block(log, true)

    try do
      sync = Task.async(fn -> Journal.flush(Journal.via(snapshot.session_id)) end)
      assert_storage(snapshot.session_id, :delayed)
      send(provider, :release_intent)
      await_queued(snapshot.session_id)
      assert :ok = Tackle.cancel(root)
      refute_receive {:tool_entered, _, _}, 50
      :ok = :disk_log.unblock(log)
      assert Task.await(sync) == :ok
      assert_receive {:tackle_turn_finished, _, ^turn, {:cancelled, _}}, 5_000
      refute_receive {:tool_entered, _, _}, 100
      {:ok, replay} = read_journal(snapshot.session_id, home: scope.home)
      assert Enum.count(replay.commits, &event?(&1, "tool.execution_started")) == 1
      assert Enum.count(replay.projection.messages, &(&1["role"] == "tool")) == 1
    after
      :disk_log.unblock(log)
    end
  end

  test "a storage pause leaves controls responsive and resumes automatically" do
    scope = durable_scope()
    root = scope.root_agent_ref
    {:ok, snapshot} = Tackle.subscribe(root)
    {:ok, turn} = Tackle.submit(root, "seed")
    assert_receive {:tackle_turn_finished, _, ^turn, _}, 5_000
    assert_receive {:adapter_called, _, _, _}
    log = {:tackle_session, snapshot.session_id}
    :ok = :disk_log.block(log, true)

    try do
      sync = Task.async(fn -> Journal.flush(Journal.via(snapshot.session_id)) end)
      assert_storage(snapshot.session_id, :delayed)
      # Delayed sessions reject admission rather than retaining more drafts.
      assert {:error, :storage_busy} = Tackle.submit(root, "rejected")
      assert {:ok, %{storage: :delayed}} = Tackle.snapshot(root)
      assert :ok = Tackle.cancel(root)
      assert {:error, :storage_busy} = Tackle.reconfigure(root, thinking: "off")
      refute_receive {:adapter_called, _, _, _}, 150
      :ok = :disk_log.unblock(log)
      assert Task.await(sync) == :ok
      assert_storage(snapshot.session_id, :ready)
      {:ok, next} = Tackle.submit(root, "next")
      assert_receive {:tackle_turn_finished, _, ^next, {:ok, _}}, 5_000
      {:ok, replay} = read_journal(snapshot.session_id, home: scope.home)
      assert Enum.count(replay.commits, &event?(&1, "turn.started")) == 2
      assert Enum.count(replay.projection.messages, &(&1["content"] == "next")) == 1
    after
      :disk_log.unblock(log)
    end
  end

  test "an accepted begin stays cancellable while its journal request waits" do
    scope = durable_scope()
    root = scope.root_agent_ref
    {:ok, snapshot} = Tackle.subscribe(root)
    {:ok, turn} = Tackle.submit(root, "seed")
    assert_receive {:tackle_turn_finished, _, ^turn, _}, 5_000
    assert_receive {:adapter_called, _, _, _}
    log = {:tackle_session, snapshot.session_id}
    :ok = :disk_log.block(log, true)

    try do
      sync = Task.async(fn -> Journal.flush(Journal.via(snapshot.session_id)) end)
      await_sync(snapshot.session_id)
      submit = Task.async(fn -> Tackle.submit(root, "cancel me") end)

      assert eventually(fn ->
               {:ok, current} = Tackle.snapshot(root)
               not is_nil(current.active_turn)
             end) == :ok

      assert :ok = Tackle.cancel(root)
      assert_storage(snapshot.session_id, :delayed)

      assert {:ok, %{active_turn: %{cancellation_requested?: true}, storage: :delayed}} =
               Tackle.snapshot(root)

      refute_receive {:adapter_called, _, _, _}, 150
      :ok = :disk_log.unblock(log)
      assert Task.await(sync) == :ok
      assert {:ok, cancelled_turn} = Task.await(submit)
      assert_receive {:tackle_turn_finished, _, ^cancelled_turn, {:cancelled, _}}, 5_000
      refute_receive {:adapter_called, _, _, _}, 50
    after
      :disk_log.unblock(log)
    end
  end

  test "settled tool results wait behind a stalled journal before another provider effect" do
    call = %{id: "call-1", name: "blocking", arguments: %{name: "first"}}

    scope =
      durable_scope(
        tools: [Tackle.Test.BlockingTool],
        context: %{test_pid: self()},
        mode: :tool_then_answer,
        llm_opts: [tool_call: call]
      )

    root = scope.root_agent_ref
    {:ok, snapshot} = Tackle.subscribe(root)
    {:ok, turn} = Tackle.submit(root, "use a tool")
    assert_receive {:adapter_called, _, _, _}
    assert_receive {:tool_entered, "first", tool}, 5_000
    log = {:tackle_session, snapshot.session_id}
    :ok = :disk_log.block(log, true)

    try do
      sync = Task.async(fn -> Journal.flush(Journal.via(snapshot.session_id)) end)
      assert_storage(snapshot.session_id, :delayed)
      send(tool, {:release, "first"})
      assert {:ok, %{storage: :delayed, active_turn: %{id: ^turn}}} = Tackle.snapshot(root)
      refute_receive {:adapter_called, _, _, _}, 150
      refute_receive {:tackle_turn_finished, _, ^turn, _}, 20
      refute_receive {:tool_entered, _, _}, 20
      :ok = :disk_log.unblock(log)
      assert Task.await(sync) == :ok
      assert_storage(snapshot.session_id, :ready)
      assert_receive {:adapter_called, _, _, _}, 5_000
      assert_receive {:tackle_turn_finished, _, ^turn, {:ok, _}}, 5_000
      refute_receive {:tool_entered, _, _}, 20
      {:ok, replay} = read_journal(snapshot.session_id, home: scope.home)
      assert Enum.count(replay.commits, &event?(&1, "tool.execution_started")) == 1
      assert Enum.count(replay.projection.messages, &(&1["role"] == "tool")) == 1
      assert Enum.map(replay.commits, & &1["seq"]) == Enum.to_list(1..replay.last_seq)
      assert length(Enum.uniq_by(replay.commits, & &1["commit_id"])) == replay.last_seq
    after
      :disk_log.unblock(log)
    end
  end

  test "an accepted configuration commit leaves snapshots responsive" do
    scope = durable_scope()
    root = scope.root_agent_ref
    {:ok, snapshot} = Tackle.subscribe(root)
    {:ok, turn} = Tackle.submit(root, "seed")
    assert_receive {:tackle_turn_finished, _, ^turn, _}, 5_000
    log = {:tackle_session, snapshot.session_id}
    :ok = :disk_log.block(log, true)

    try do
      sync = Task.async(fn -> Journal.flush(Journal.via(snapshot.session_id)) end)
      await_sync(snapshot.session_id)
      config = Task.async(fn -> Tackle.reconfigure(root, thinking: "off") end)
      assert_storage(snapshot.session_id, :delayed)
      assert {:ok, %{storage: :delayed, active_turn: nil}} = Tackle.snapshot(root)
      assert {:error, :storage_busy} = Tackle.submit(root, "rejected")
      assert :ok = Tackle.cancel(root)
      :ok = :disk_log.unblock(log)
      assert Task.await(sync) == :ok
      assert {:ok, _} = Task.await(config)
      assert_storage(snapshot.session_id, :ready)
    after
      :disk_log.unblock(log)
    end
  end

  test "deferred notices remain byte bounded during a storage pause" do
    scope = durable_scope()
    root = scope.root_agent_ref
    {:ok, snapshot} = Tackle.subscribe(root)
    {:ok, turn} = Tackle.submit(root, "seed")
    assert_receive {:tackle_turn_finished, _, ^turn, _}, 5_000
    log = {:tackle_session, snapshot.session_id}
    :ok = :disk_log.block(log, true)

    try do
      sync = Task.async(fn -> Journal.flush(Journal.via(snapshot.session_id)) end)
      assert_storage(snapshot.session_id, :delayed)

      {:ok, accepted} =
        Envelope.new(:completion, root, String.duplicate("x", 16 * 1024 * 1024))

      {:ok, excess} =
        Envelope.new(:completion, root, String.duplicate("x", 9 * 1024 * 1024))

      assert :ok = Messaging.deliver(root, accepted)
      assert {:error, :deferred_inbox_full} = Messaging.deliver(root, excess)
      {:ok, session} = Runtime.session_pid(root)
      assert [^accepted] = Session.inbox(session)
      # The admitted notice remains bounded while the original sync is pending.
      # Remove it as test cleanup rather than sending a 16-MiB fake model request.
      assert {:ok, [_]} = GenServer.call(session, :take_incoming_messages)
      :ok = :disk_log.unblock(log)
      assert Task.await(sync) == :ok
    after
      :disk_log.unblock(log)
    end
  end

  test "one-shot runtime completion notices remain bounded and survive a storage pause" do
    scope = durable_scope(mode: :manual)
    root = scope.root_agent_ref
    {:ok, snapshot} = Tackle.subscribe(root)
    {:ok, turn} = Tackle.submit(root, "seed")
    assert_receive {:adapter_called, task, _, _}
    log = {:tackle_session, snapshot.session_id}
    :ok = :disk_log.block(log, true)

    try do
      sync = Task.async(fn -> Journal.flush(Journal.via(snapshot.session_id)) end)
      assert_storage(snapshot.session_id, :delayed)
      {:ok, completion} = Envelope.new(:completion, root, "child finished")
      assert :ok = Messaging.deliver(root, completion)
      {:ok, session} = Runtime.session_pid(root)
      assert [^completion] = Session.inbox(session)
      refute_receive {:adapter_called, _, _, _}, 50
      :ok = :disk_log.unblock(log)
      assert Task.await(sync) == :ok
      send(task, {:respond, "one"})
      assert_receive {:adapter_called, notice_task, _, opts}, 5_000

      assert Enum.count(opts[:messages], &String.contains?(&1.content || "", "child finished")) ==
               1

      send(notice_task, {:respond, "two"})
      assert_receive {:tackle_turn_finished, _, ^turn, _}, 5_000
      assert [] = Session.inbox(session)
      {:ok, replay} = read_journal(snapshot.session_id, home: scope.home)

      assert Enum.count(
               replay.projection.messages,
               &String.contains?(&1["content"] || "", "child finished")
             ) == 1
    after
      :disk_log.unblock(log)
    end
  end

  test "captured inbox entries cannot be withdrawn or erase newly arriving notices" do
    scope = durable_scope()
    root = scope.root_agent_ref
    {:ok, snapshot} = Tackle.subscribe(root)
    {:ok, turn} = Tackle.submit(root, "seed")
    assert_receive {:tackle_turn_finished, _, ^turn, _}, 5_000
    assert_receive {:adapter_called, _, _, _}
    {:ok, session} = Runtime.session_pid(root)
    log = {:tackle_session, snapshot.session_id}
    :ok = :disk_log.block(log, true)
    :ok = :sys.suspend(session)

    try do
      {:ok, message} = Envelope.new(:message, root, "reserved")
      delivery = Task.async(fn -> Messaging.deliver(root, message) end)

      assert eventually(fn ->
               {:messages, messages} = Process.info(session, :messages)
               Enum.any?(messages, &match?({:"$gen_call", _, {:deliver, _}}, &1))
             end) == :ok

      sync = Task.async(fn -> Journal.flush(Journal.via(snapshot.session_id)) end)
      await_sync(snapshot.session_id)
      :ok = :sys.resume(session)
      assert Task.await(delivery) == :ok

      assert eventually(fn ->
               match?(%{storage_task: %{kind: :begin_turn}}, :sys.get_state(session))
             end) == :ok

      assert {:error, :storage_busy} = Session.withdraw_queued(session, "reserved")
      {:ok, completion} = Envelope.new(:completion, root, "arrived later")
      assert :ok = Messaging.deliver(root, completion)
      :ok = :disk_log.unblock(log)
      assert Task.await(sync) == :ok
      assert_receive {:tackle_turn_finished, _, _, _}, 5_000
      assert eventually(fn -> Session.inbox(session) == [] end) == :ok

      assert eventually(fn ->
               {:ok, current} = Tackle.snapshot(root)

               Enum.any?(
                 current.agent_state.messages,
                 &String.contains?(&1.content || "", "arrived later")
               )
             end) == :ok
    after
      if Process.alive?(session), do: :sys.resume(session)
      :disk_log.unblock(log)
    end
  end

  test "an admitted close keeps its continuation when the turn task exits" do
    scope = durable_scope(mode: :manual)
    root = scope.root_agent_ref
    {:ok, snapshot} = Tackle.subscribe(root)
    {:ok, _turn} = Tackle.submit(root, "seed")
    assert_receive {:adapter_called, turn_task, _, _}
    {:ok, session} = Runtime.session_pid(root)
    log = {:tackle_session, snapshot.session_id}
    :ok = :disk_log.block(log, true)

    try do
      sync = Task.async(fn -> Journal.flush(Journal.via(snapshot.session_id)) end)
      await_sync(snapshot.session_id)
      close = Task.async(fn -> Session.close(session) end)
      assert_storage(snapshot.session_id, :delayed)

      assert eventually(fn ->
               match?(%{storage_task: %{kind: :close}}, :sys.get_state(session))
             end) == :ok

      Process.exit(turn_task, :kill)

      assert eventually(fn -> not Process.alive?(turn_task) end) == :ok
      refute_receive {:tackle_turn_failed, _, _, _}, 50
      assert %{storage_task: %{kind: :close}} = :sys.get_state(session)

      assert {:ok, %{storage: :delayed}} = Tackle.snapshot(root)
      assert Task.yield(close, 20) == nil
      :ok = :disk_log.unblock(log)
      assert Task.await(sync) == :ok
      assert Task.await(close) == :ok
      assert_receive {:tackle_session_closed, session_id}, 5_000
      assert session_id == snapshot.session_id
      {:ok, replay} = read_journal(session_id, home: scope.home)
      assert Enum.count(replay.commits, &event?(&1, "session.closed")) == 1
      assert replay.projection.closed_at != nil
    after
      :disk_log.unblock(log)
    end
  end

  test "terminal persistence waits asynchronously after a turn task crashes" do
    scope = durable_scope(mode: :manual)
    root = scope.root_agent_ref
    {:ok, snapshot} = Tackle.subscribe(root)
    {:ok, turn} = Tackle.submit(root, "seed")
    assert_receive {:adapter_called, task, _, _}
    log = {:tackle_session, snapshot.session_id}
    :ok = :disk_log.block(log, true)

    try do
      sync = Task.async(fn -> Journal.flush(Journal.via(snapshot.session_id)) end)
      assert_storage(snapshot.session_id, :delayed)
      Process.exit(task, :kill)
      {:ok, session} = Runtime.session_pid(root)

      assert eventually(fn ->
               match?(%{storage_task: %{kind: :terminal}}, :sys.get_state(session))
             end) == :ok

      assert {:ok, %{storage: :delayed}} = Tackle.snapshot(root)
      assert :ok = Tackle.cancel(root)
      refute_receive {:tackle_turn_failed, _, ^turn, _}, 150
      :ok = :disk_log.unblock(log)
      assert Task.await(sync) == :ok
      assert_receive {:tackle_turn_failed, _, ^turn, :killed}, 5_000
      {:ok, replay} = read_journal(snapshot.session_id, home: scope.home)
      assert Enum.count(replay.commits, &event?(&1, "turn.crashed")) == 1
    after
      :disk_log.unblock(log)
    end
  end

  test "a real crash during the pause still requires interrupted-turn recovery" do
    scope = durable_scope(mode: :manual)
    root = scope.root_agent_ref
    {:ok, snapshot} = Tackle.subscribe(root)
    {:ok, _turn} = Tackle.submit(root, "interrupted")
    assert_receive {:adapter_called, _, _, _}
    {:ok, journal} = Journal.whereis(snapshot.session_id)
    log = {:tackle_session, snapshot.session_id}
    :ok = :disk_log.block(log, true)
    sync = Task.async(fn -> Journal.flush(journal) end)
    assert_storage(snapshot.session_id, :delayed)
    Process.exit(journal, :kill)
    assert {:error, _} = Task.await(sync)
    :disk_log.unblock(log)
    stop_scope(scope.scope_ref)

    resumed =
      start_scope(
        session: Spec.new!(session_id: snapshot.session_id, storage: [home: scope.home])
      )

    assert {:error, {:recovery_required, _}} = Tackle.submit(resumed.root_agent_ref, "retry")
  end

  defp configured_scope(config_opts) do
    home = tmp_home()
    session = Spec.new!(storage: [home: home, journal_timeout: 100])

    opts =
      Keyword.merge(
        [
          providers: [Adapter],
          model: "test/echo",
          system_prompt: "Test agent"
        ],
        config_opts
      )

    opts =
      Keyword.update(opts, :llm_opts, [test_pid: self()], &Keyword.put(&1, :test_pid, self()))

    {:ok, config} = Tackle.Config.new(opts)
    spec = scope_spec(session: session)
    spec = %{spec | root_spec: %{spec.root_spec | config: config}}
    {:ok, scope} = Tackle.Runtime.start_scope(spec)
    on_exit(fn -> stop_scope(scope.scope_ref) end)
    Map.put(scope, :home, home)
  end

  defp durable_scope(root_opts \\ []) do
    home = tmp_home()
    session = Spec.new!(storage: [home: home, journal_timeout: 100])
    scope = start_scope(session: session, root: root_opts)
    Map.put(scope, :home, home)
  end

  defp await_sync(session_id) do
    {:ok, journal} = Journal.whereis(session_id)

    [{watchdog, _}] =
      Registry.lookup(JournalRegistry, {:journal_watchdog, journal})

    assert eventually(fn -> :sys.get_state(watchdog).stage == :sync end) == :ok
  end

  defp await_queued(session_id) do
    {:ok, journal} = Journal.whereis(session_id)

    [{watchdog, _}] =
      Registry.lookup(JournalRegistry, {:journal_watchdog, journal})

    assert eventually(fn -> not :queue.is_empty(:sys.get_state(watchdog).queued) end) == :ok
  end

  defp assert_storage(session_id, storage) do
    assert_receive {:tackle_storage, ^session_id, ^storage}, 2_000
  end

  defp event?(commit, type), do: Enum.any?(commit["events"], &(&1["type"] == type))
end
