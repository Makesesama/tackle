defmodule Tackle.Session.JournalTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Tree
  alias Tackle.Runtime.ID
  alias Tackle.Session.Journal
  alias Tackle.Session.Journal.Watchdog
  alias Tackle.Session.Log
  alias Tackle.Session.Persistence
  alias Tackle.Session.Reader
  alias Tackle.Session.Storage

  defmodule BlockingReportHandler do
    def log(%{meta: %{mfa: {Watchdog, :report, 2}}}, %{config: test_pid}) do
      send(test_pid, {:report_blocked, self()})

      receive do
        :unblock -> :ok
      end
    end

    def log(_event, _config), do: :ok
  end

  setup do
    home = tmp_home()
    {:ok, home: home, session_id: ID.generate()}
  end

  describe "new journal" do
    test "defers materialization until the first turn", ctx do
      {:ok, journal} = start_journal(ctx)

      assert {:ok, projection} = Journal.projection(journal)
      assert projection.session_id == ctx.session_id
      assert projection.last_seq == 0
      assert projection.messages == []

      assert {:ok, status} = Journal.status(journal)
      assert status.last_seq == 0
      assert status.materialized? == false

      {:ok, path} = Storage.journal_path(ctx.session_id, home: ctx.home)
      refute File.exists?(path)
      refute File.dir?(Path.dirname(path))

      assert {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")

      assert {:ok, projection} = Journal.projection(journal)
      assert projection.last_seq == 2

      assert {:ok, status} = Journal.status(journal)
      assert status.last_seq == 2
      assert File.exists?(path)
    end

    test "does not create a journal when closed before the first turn", ctx do
      {:ok, journal} = start_journal(ctx)

      assert :ok = Journal.close_journal(journal)
      assert :ok = Journal.flush(journal)

      {:ok, path} = Storage.journal_path(ctx.session_id, home: ctx.home)
      refute File.exists?(path)
      refute File.dir?(Path.dirname(path))

      stop_journal(journal)

      assert {:error, _reason} = Reader.read(ctx.session_id, home: ctx.home)
    end
  end

  describe "turn protocol" do
    test "persists turn boundaries and messages with contiguous sequences", ctx do
      {:ok, journal} = start_journal(ctx)
      turn_id = ID.generate()

      assert {:ok, ^turn_id} = Journal.begin_turn(journal, :run, "hello", turn_id)
      assert :ok = Journal.append_message(journal, Message.user("hello"))
      assert :ok = Journal.tool_started(journal, %{id: "call-1", name: "read", arguments: %{}})
      assert :ok = Journal.append_message(journal, Message.tool_result("call-1", "read", "out"))
      assert :ok = Journal.settle_turn(journal, "turn.completed", %{})

      assert {:ok, status} = Journal.status(journal)
      assert status.last_seq == 6

      # turn.started and the terminal event are write-behind.
      assert :ok = Journal.flush(journal)
      {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)

      assert [
               %{"type" => "session.created"},
               %{"type" => "turn.started"},
               %{"type" => "message.appended"},
               %{"type" => "tool.execution_started"},
               %{"type" => "message.appended"},
               %{"type" => "turn.completed"}
             ] = Enum.map(replay.commits, &commit_type?/1)

      assert [_, _] = replay.projection.messages
      assert replay.projection.status == :clean
      assert replay.projection.active_turn == nil
    end

    test "a journal without branching keeps its format and refuses a branch", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      user = Message.user("hello")
      answer = Message.assistant(content: "world")

      # The parent a branching session would record is implied, so not written.
      assert :ok = Journal.append_message(journal, user, {:tree, nil})
      assert :ok = Journal.append_message(journal, answer, {:tree, user.id})

      # A parent other than the active entry would branch.
      assert {:error, :tree_disabled} =
               Journal.append_message(journal, Message.user("branch"), {:tree, user.id})

      assert {:ok, %{last_seq: 4}} = Journal.status(journal)
      assert :ok = Journal.flush(journal)
      {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)

      appended =
        for commit <- replay.commits,
            %{"type" => "message.appended", "data" => data} <- commit["events"],
            do: data

      assert [_, _] = appended
      refute Enum.any?(appended, &Map.has_key?(&1, "parent_id"))
      assert Enum.map(replay.projection.messages, & &1["id"]) == [user.id, answer.id]
    end

    test "a branching journal records every parent", ctx do
      {:ok, journal} = start_journal(ctx, tree: true)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      user = Message.user("hello")
      assert :ok = Journal.append_message(journal, user, {:tree, nil})
      assert :ok = Journal.append_message(journal, Message.user("sibling"), {:tree, nil})

      assert :ok = Journal.flush(journal)
      {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)

      assert [nil, nil] =
               for(
                 commit <- replay.commits,
                 %{"type" => "message.appended", "data" => data} <- commit["events"],
                 do: Map.fetch!(data, "parent_id")
               )

      assert [_, _] = Tree.roots(replay.projection.tree)
    end

    test "rejects a second concurrent turn", ctx do
      {:ok, journal} = start_journal(ctx)
      assert {:ok, _turn_id} = Journal.begin_turn(journal, :run, "one")
      assert {:error, :turn_in_progress} = Journal.begin_turn(journal, :run, "two")
    end
  end

  describe "replay after reopen" do
    test "replay derives the same message surfaces as live commits", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      :ok = Journal.append_message(journal, Message.user("hello"))
      :ok = Journal.append_message(journal, Message.assistant(content: "world"))
      :ok = Journal.settle_turn(journal, "turn.completed", %{})

      {:ok, live} = Journal.projection(journal)
      assert :ok = Journal.flush(journal)
      {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)

      assert replay.projection.messages == live.messages
      assert replay.projection.model_messages == live.model_messages
      assert replay.projection.tree == live.tree
      assert replay.projection.last_seq == live.last_seq
    end

    test "continues sequence numbering and reconstructs messages", ctx do
      {:ok, journal} = start_journal(ctx)
      turn_id = ID.generate()
      {:ok, ^turn_id} = Journal.begin_turn(journal, :run, "hello", turn_id)
      :ok = Journal.append_message(journal, Message.user("hello"))
      :ok = Journal.settle_turn(journal, "turn.completed", %{})
      :ok = Journal.close_journal(journal)

      stop_journal(journal)

      {:ok, journal} = start_journal(ctx)
      assert {:ok, projection} = Journal.projection(journal)
      assert projection.last_seq == 5
      assert [%Message{role: :user, content: "hello"}] = Tree.transcript(projection.tree)

      assert {:ok, _turn_id} = Journal.begin_turn(journal, :continue, nil)
      assert {:ok, status} = Journal.status(journal)
      assert status.last_seq == 6
    end
  end

  describe "write-behind appends" do
    test "are appended in order and become durable at the next await_durable", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      assert :ok = Journal.append_message(journal, Message.user("hello"), :none, sync: false)

      assert :ok =
               Journal.tool_started(journal, %{id: "call-1", name: "read", arguments: %{}},
                 sync: false
               )

      assert {:ok, %{last_seq: 4}} = Journal.status(journal)
      log = {:tackle_session, ctx.session_id}
      :ok = :disk_log.block(log, true)

      try do
        task = Task.async(fn -> Journal.await_durable(journal) end)
        # Unsynced commits exist, so the barrier must wait for the disk.
        assert Task.yield(task, 200) == nil
        :ok = :disk_log.unblock(log)
        assert Task.await(task) == :ok
      after
        :disk_log.unblock(log)
      end

      assert {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)
      assert [%{"content" => "hello"}] = replay.projection.messages
      assert replay.last_seq == 4
      stop_journal(journal)
    end

    test "one sync covers every commit appended before it", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      :ok = trace_syncs(journal)

      for n <- 1..5 do
        message = Message.assistant(content: "answer #{n}")
        assert :ok = Journal.append_message(journal, message, :none, sync: false)
      end

      assert collect_syncs(journal) == 0
      assert :ok = Journal.await_durable(journal)
      assert collect_syncs(journal) == 1
      stop_journal(journal)
    end

    test "await_durable does not touch the disk when nothing is unsynced", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      # turn.started is write-behind; make it durable first.
      assert :ok = Journal.await_durable(journal)
      log = {:tackle_session, ctx.session_id}
      :ok = :disk_log.block(log, true)

      try do
        task = Task.async(fn -> Journal.await_durable(journal) end)
        assert Task.yield(task, 1_000) == {:ok, :ok}
      after
        :disk_log.unblock(log)
      end

      stop_journal(journal)
    end

    test "await_idle never syncs but waits behind a stalled sync", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      :ok = trace_syncs(journal)
      assert :ok = Journal.append_message(journal, Message.user("hello"), :none, sync: false)
      assert :ok = Journal.await_idle(journal)
      assert collect_syncs(journal) == 0

      [{watchdog, _}] =
        Registry.lookup(Tackle.Session.JournalRegistry, {:journal_watchdog, journal})

      log = {:tackle_session, ctx.session_id}
      :ok = :disk_log.block(log, true)

      try do
        sync = Task.async(fn -> Journal.flush(journal) end)
        assert eventually(fn -> :sys.get_state(watchdog).stage == :sync end) == :ok
        idle = Task.async(fn -> Journal.await_idle(journal) end)
        assert Task.yield(idle, 200) == nil
        :ok = :disk_log.unblock(log)
        assert Task.await(sync) == :ok
        assert Task.await(idle) == :ok
      after
        :disk_log.unblock(log)
      end

      stop_journal(journal)
    end

    test "flush still syncs when nothing is unsynced", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      assert :ok = Journal.await_durable(journal)
      :ok = trace_syncs(journal)
      assert :ok = Journal.flush(journal)
      assert collect_syncs(journal) == 1
      stop_journal(journal)
    end
  end

  describe "durability acknowledgement" do
    test "a delayed append within the deadline commits once", ctx do
      {:ok, journal} = start_journal(ctx, journal_timeout: 1_000)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      message = Message.assistant(content: "answer")
      :ok = :sys.suspend(journal)

      try do
        task = Task.async(fn -> Journal.persist_message(ctx.session_id, message) end)
        await_queued_append(journal, message.id)

        assert Task.yield(task, 20) == nil
        :ok = :sys.resume(journal)
        assert Task.await(task, 5_000) == :ok

        assert {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)
        assert [%{"id" => id}] = replay.projection.messages
        assert id == message.id
        assert replay.last_seq == 3
      after
        if Process.alive?(journal), do: :sys.resume(journal)
        stop_journal(journal)
      end
    end

    test "a stalled append kills the owner, releases callers and saves diagnostics", ctx do
      {:ok, journal} = start_journal(ctx, journal_timeout: 250)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      :ok = :sys.suspend(journal)
      message = Message.assistant(content: "PRIVATE PAYLOAD")
      ref = Process.monitor(journal)
      task = Task.async(fn -> Journal.append_message(journal, message) end)
      await_queued_append(journal, message.id)
      second = Task.async(fn -> Journal.flush(journal) end)

      assert {:error, {:journal_stalled, diagnostic}} = Task.await(task, 2_000)
      assert_receive {:DOWN, ^ref, :process, ^journal, :killed}, 1_000
      assert {:error, {:journal_stalled, ^diagnostic}} = Task.await(second, 2_000)
      assert diagnostic["operation"] == "append_message"
      assert diagnostic["deadline_ms"] == 250
      assert diagnostic["elapsed_ms"] >= 250
      assert diagnostic["stacktrace"] != []
      refute inspect(diagnostic) =~ "PRIVATE PAYLOAD"

      {:ok, path} = Storage.journal_path(ctx.session_id, home: ctx.home)
      report = Path.join(Path.dirname(path), "journal-failure.json")
      assert eventually(fn -> File.exists?(report) end) == :ok
      assert JSON.decode!(File.read!(report)) == diagnostic
      assert Bitwise.band(File.stat!(report).mode, 0o777) == 0o600
    end

    test "stalled disk sync pauses the owner and resumes without replay or retry", ctx do
      {:ok, journal} = start_journal(ctx, journal_timeout: 100)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      assert :ok = Journal.append_message(journal, Message.user("hello"))
      assert :ready = Watchdog.subscribe(journal, self())
      log = {:tackle_session, ctx.session_id}
      assert :ok = :disk_log.block(log, true)
      ref = Process.monitor(journal)

      try do
        task = Task.async(fn -> Journal.flush(journal) end)
        session_id = ctx.session_id
        assert_receive {:tackle_storage, ^session_id, :delayed}, 1_000

        [{watchdog, _}] =
          Registry.lookup(Tackle.Session.JournalRegistry, {:journal_watchdog, journal})

        [request] = Map.keys(:sys.get_state(watchdog).pending)
        Process.sleep(250)
        assert Map.keys(:sys.get_state(watchdog).pending) == [request]
        assert Task.yield(task, 20) == nil
        refute_receive {:DOWN, ^ref, :process, ^journal, _}, 20
        refute_receive {:tackle_storage, ^session_id, :delayed}, 20
        assert :ok = :disk_log.unblock(log)
        assert Task.await(task) == :ok
        assert_receive {:tackle_storage, ^session_id, :ready}
        assert {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)
        assert [%{"content" => "hello"}] = replay.projection.messages
        assert replay.last_seq == 3
        {:ok, path} = Storage.journal_path(ctx.session_id, home: ctx.home)
        refute File.exists?(Path.join(Path.dirname(path), "journal-failure.json"))
      after
        :disk_log.unblock(log)
        Process.demonitor(ref, [:flush])
        stop_journal(journal)
      end
    end

    test "paused admission is bounded and queued commits stay behind sync", ctx do
      {:ok, journal} = start_journal(ctx, journal_timeout: 100)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      assert :ready = Watchdog.subscribe(journal, self())
      log = {:tackle_session, ctx.session_id}
      :ok = :disk_log.block(log, true)

      try do
        sync = Task.async(fn -> Journal.flush(journal) end)
        session_id = ctx.session_id
        assert_receive {:tackle_storage, ^session_id, :delayed}, 1_000

        [{watchdog, _}] =
          Registry.lookup(Tackle.Session.JournalRegistry, {:journal_watchdog, journal})

        tasks =
          for n <- 1..64,
              do:
                Task.async(fn ->
                  Journal.append_message(journal, Message.assistant(content: "answer #{n}"))
                end)

        assert eventually(fn -> :queue.len(:sys.get_state(watchdog).queued) == 64 end) == :ok
        assert {:error, :journal_busy} = Journal.flush(journal)
        assert map_size(:sys.get_state(watchdog).pending) == 1
        assert :ok = :disk_log.unblock(log)
        assert Task.await(sync) == :ok
        assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))
        assert {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)
        assert Enum.count_until(replay.projection.messages, 65) == 64
        assert Enum.map(replay.commits, & &1["seq"]) == Enum.to_list(1..66)
        assert Enum.count_until(Enum.uniq_by(replay.commits, & &1["commit_id"]), 67) == 66
      after
        :disk_log.unblock(log)
        stop_journal(journal)
      end
    end

    test "paused admission also bounds retained payload bytes", ctx do
      {:ok, journal} = start_journal(ctx, journal_timeout: 100)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      assert :ready = Watchdog.subscribe(journal, self())
      log = {:tackle_session, ctx.session_id}
      :ok = :disk_log.block(log, true)

      try do
        sync = Task.async(fn -> Journal.flush(journal) end)
        session_id = ctx.session_id
        assert_receive {:tackle_storage, ^session_id, :delayed}, 1_000
        oversized = Message.assistant(content: String.duplicate("x", 24 * 1024 * 1024))
        assert {:error, :journal_busy} = Journal.append_message(journal, oversized)
        assert :ok = :disk_log.unblock(log)
        assert Task.await(sync) == :ok
        assert {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)
        assert replay.last_seq == 2
      after
        :disk_log.unblock(log)
        stop_journal(journal)
      end
    end

    test "writer-lock loss remains fatal during a recoverable sync pause", ctx do
      {:ok, journal} = start_journal(ctx, journal_timeout: 100)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")

      [{watchdog, _}] =
        Registry.lookup(Tackle.Session.JournalRegistry, {:journal_watchdog, journal})

      lock = :sys.get_state(watchdog).lock
      assert is_port(lock.port)
      assert :ready = Watchdog.subscribe(journal, self())
      log = {:tackle_session, ctx.session_id}
      :ok = :disk_log.block(log, true)

      try do
        sync = Task.async(fn -> Journal.flush(journal) end)
        session_id = ctx.session_id
        assert_receive {:tackle_storage, ^session_id, :delayed}, 1_000
        Port.close(lock.port)
        assert {:error, {:journal_failure, {:writer_lock_lost, _}}} = Task.await(sync)
        diagnostic = await_failure_report(ctx)
        assert diagnostic["failure"] == "journal_failure/writer_lock_lost"
        assert diagnostic["stage"] == "sync"
      after
        :disk_log.unblock(log)
        stop_journal(journal)
      end
    end

    test "failure cleanup is bounded even when disk sync is blocked", ctx do
      {:ok, journal} = start_journal(ctx, journal_timeout: 250)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      log = {:tackle_session, ctx.session_id}
      assert :ok = :disk_log.block(log, true)
      ref = Process.monitor(journal)
      message = Message.assistant(content: "hi")
      # The owner stops on the notification, queued before the request, while
      # that request is pending.
      :ok = :sys.suspend(journal)
      send(journal, {:disk_log, node(), log, :full})
      task = Task.async(fn -> Journal.append_message(journal, message) end)
      await_queued_append(journal, message.id)
      :ok = :sys.resume(journal)

      assert {:error, {:journal_stalled, diagnostic}} = Task.await(task)

      assert diagnostic["stage"] == "cleanup_sync"
      assert_receive {:DOWN, ^ref, :process, ^journal, :killed}, 1_000
      assert :disk_log.unblock(log) in [:ok, {:error, :no_such_log}]
    end

    test "termination cleanup is guarded even without a pending durable request", ctx do
      {:ok, journal} = start_journal(ctx, journal_timeout: 250)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      log = {:tackle_session, ctx.session_id}
      assert :ok = :disk_log.block(log, true)
      ref = Process.monitor(journal)
      send(journal, {:disk_log, node(), log, :full})

      assert_receive {:DOWN, ^ref, :process, ^journal, :killed}, 2_000
      {:ok, path} = Storage.journal_path(ctx.session_id, home: ctx.home)
      report = Path.join(Path.dirname(path), "journal-failure.json")
      assert eventually(fn -> File.exists?(report) end) == :ok
      assert JSON.decode!(File.read!(report))["stage"] == "cleanup_sync"
      assert :disk_log.unblock(log) in [:ok, {:error, :no_such_log}]
    end

    test "startup is bounded before any durable request is issued", ctx do
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      ref = Process.monitor(owner)

      {:ok, watchdog} =
        Watchdog.start(owner, ctx.session_id,
          home: ctx.home,
          journal_timeout: 100
        )

      watcher_ref = Process.monitor(watchdog)

      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 1_000
      assert_receive {:DOWN, ^watcher_ref, :process, ^watchdog, :normal}, 3_000
      {:ok, path} = Storage.journal_path(ctx.session_id, home: ctx.home)
      diagnostic = JSON.decode!(File.read!(Path.join(Path.dirname(path), "journal-failure.json")))
      assert diagnostic["stage"] == "initializing"
      assert diagnostic["operation"] == "initializing"
    end

    test "completed requests do not leave armed deadline timers", ctx do
      {:ok, journal} = start_journal(ctx, journal_timeout: 100)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      assert :ok = Journal.append_message(journal, Message.user("hello"))
      Process.sleep(150)
      assert {:ok, _status} = Journal.status(journal)
      stop_journal(journal)
    end

    test "a failed diagnostic write does not keep the watchdog alive", ctx do
      {:ok, journal} = start_journal(ctx, journal_timeout: 250)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")

      [{watchdog, _}] =
        Registry.lookup(Tackle.Session.JournalRegistry, {:journal_watchdog, journal})

      # Make publication fail without interfering with stall detection.
      {:ok, path} = Storage.journal_path(ctx.session_id, home: ctx.home)
      report = Path.join(Path.dirname(path), "journal-failure.json")
      :ok = File.mkdir!(report)
      :ok = :sys.suspend(journal)
      ref = Process.monitor(watchdog)
      assert {:error, {:journal_stalled, _}} = Journal.flush(journal)
      assert_receive {:DOWN, ^ref, :process, ^watchdog, :normal}, 3_000
    end

    test "a timeout releases fallback ownership only after the log backend closes", ctx do
      old_path = System.get_env("PATH")
      System.put_env("PATH", "")

      try do
        {:ok, journal} = start_journal(ctx, journal_timeout: 250)
        {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
        assert :ok = Journal.append_message(journal, Message.user("hello"))
        {:ok, path} = Storage.journal_path(ctx.session_id, home: ctx.home)
        lock_path = Path.join(Path.dirname(path), "writer.lock")
        assert File.exists?(lock_path)
        :ok = :sys.suspend(journal)
        assert {:error, {:journal_stalled, _}} = Journal.flush(journal)
        assert eventually(fn -> not File.exists?(lock_path) end) == :ok

        {:ok, resumed} = start_journal(ctx, repair: true)
        assert {:ok, projection} = Journal.projection(resumed)
        assert [%{"content" => "hello"}] = projection.messages
        stop_journal(resumed)
      after
        if old_path, do: System.put_env("PATH", old_path), else: System.delete_env("PATH")
      end
    end

    test "a crashing watchdog stops a waiting caller only after owner death", ctx do
      {:ok, journal} = start_journal(ctx)
      :ok = :sys.suspend(journal)
      message = Message.assistant(content: "answer")
      task = Task.async(fn -> Journal.append_message(journal, message) end)
      await_queued_append(journal, message.id)

      [{watchdog, _}] =
        Registry.lookup(Tackle.Session.JournalRegistry, {:journal_watchdog, journal})

      Process.exit(watchdog, :kill)
      assert {:error, {:journal_unavailable, :killed}} = Task.await(task, 1_000)
      refute Process.alive?(journal)
    end

    test "a crashing watchdog kills even a suspended owner", ctx do
      {:ok, journal} = start_journal(ctx)
      :ok = :sys.suspend(journal)
      ref = Process.monitor(journal)

      [{watchdog, _}] =
        Registry.lookup(Tackle.Session.JournalRegistry, {:journal_watchdog, journal})

      Process.exit(watchdog, :kill)
      assert_receive {:DOWN, ^ref, :process, ^journal, :killed}, 1_000
    end

    test "healthy disk log notifications do not stop the owner", ctx do
      {:ok, journal} = start_journal(ctx)
      send(journal, {:disk_log, node(), :log, {:error_status, :ok}})
      assert {:ok, _status} = Journal.status(journal)
      stop_journal(journal)
    end

    test "disk full notifications stop the owner", ctx do
      {:ok, journal} = start_journal(ctx)
      ref = Process.monitor(journal)
      send(journal, {:disk_log, node(), :log, :full})
      assert_receive {:DOWN, ^ref, :process, ^journal, {:journal_failure, :disk_full}}, 1_000
    end

    test "the persistence hook fails closed without a journal", ctx do
      state = %State{session_id: ctx.session_id}
      message = Message.assistant(content: "answer")

      assert {:error, {:message_not_journaled, {:journal_unavailable, :not_found}}} =
               Persistence.after_message(state, message, %{})

      assert {:error, {:journal_unavailable, :not_found}} =
               Persistence.before_tool_call(state, %{}, %{})
    end

    test "journal death releases a waiting persistence hook with an error", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      message = Message.assistant(content: "answer")
      :ok = :sys.suspend(journal)

      try do
        task = Task.async(fn -> Journal.persist_message(ctx.session_id, message) end)
        await_queued_append(journal, message.id)
        Process.exit(journal, :kill)

        assert {:error, {:journal_unavailable, :killed}} = Task.await(task, 5_000)
      after
        if Process.alive?(journal), do: :sys.resume(journal)
        stop_journal(journal)
      end
    end
  end

  describe "failure diagnostics" do
    test "blocked reporting does not delay fallback lock cleanup", ctx do
      old_path = System.get_env("PATH")
      System.put_env("PATH", "")
      handler = :tackle_test_blocked_journal_report
      :ok = :logger.add_handler(handler, BlockingReportHandler, %{config: self()})

      try do
        {:ok, journal} = start_journal(ctx)
        {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")

        [{watchdog, _}] =
          Registry.lookup(Tackle.Session.JournalRegistry, {:journal_watchdog, journal})

        ref = Process.monitor(watchdog)
        {:ok, path} = Storage.journal_path(ctx.session_id, home: ctx.home)
        lock_path = Path.join(Path.dirname(path), "writer.lock")
        assert File.exists?(lock_path)

        Process.exit(journal, :kill)
        assert_receive {:report_blocked, _reporter}, 1_000
        assert eventually(fn -> not File.exists?(lock_path) end) == :ok
        assert_receive {:DOWN, ^ref, :process, ^watchdog, :normal}, 3_000
      after
        :logger.remove_handler(handler)
        if old_path, do: System.put_env("PATH", old_path), else: System.delete_env("PATH")
      end
    end

    test "deeply nested exit reasons produce a bounded report", ctx do
      owner =
        spawn(fn ->
          receive do
            {:stop, reason} -> exit(reason)
          end
        end)

      {:ok, watchdog} = Watchdog.start(owner, ctx.session_id, home: ctx.home)
      Watchdog.ready(owner)
      ref = Process.monitor(watchdog)
      reason = Enum.reduce(1..10_000, :disk_full, fn _, acc -> {:journal_failure, acc} end)
      send(owner, {:stop, reason})
      assert_receive {:DOWN, ^ref, :process, ^watchdog, :normal}, 3_000
      diagnostic = await_failure_report(ctx)
      assert diagnostic["failure"] == "journal_failure/unexpected_owner_exit"
      assert byte_size(JSON.encode!(diagnostic)) < 1_000
    end

    test "records disk failure even when no durable request is waiting", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      ref = Process.monitor(journal)
      send(journal, {:disk_log, node(), :log, :full})
      assert_receive {:DOWN, ^ref, :process, ^journal, {:journal_failure, :disk_full}}, 1_000

      diagnostic = await_failure_report(ctx)
      assert diagnostic["failure"] == "journal_failure/disk_full"
      assert diagnostic["operation"] == "owner_exit"
      assert diagnostic["sequence"] == 2
    end

    test "does not serialize arbitrary exit payloads", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      ref = Process.monitor(journal)
      send(journal, {:EXIT, self(), {:unexpected, "PRIVATE PAYLOAD"}})
      assert_receive {:DOWN, ^ref, :process, ^journal, {:unexpected, _}}, 1_000

      diagnostic = await_failure_report(ctx)
      assert diagnostic["failure"] == "unexpected_owner_exit"
      refute inspect(diagnostic) =~ "PRIVATE PAYLOAD"
    end

    test "normal teardown does not create a failure report", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")

      [{watchdog, _}] =
        Registry.lookup(Tackle.Session.JournalRegistry, {:journal_watchdog, journal})

      ref = Process.monitor(watchdog)
      stop_journal(journal)
      assert_receive {:DOWN, ^ref, :process, ^watchdog, :normal}, 3_000

      {:ok, path} = Storage.journal_path(ctx.session_id, home: ctx.home)
      refute File.exists?(Path.join(Path.dirname(path), "journal-failure.json"))
    end
  end

  defp await_failure_report(ctx) do
    {:ok, path} = Storage.journal_path(ctx.session_id, home: ctx.home)
    report = Path.join(Path.dirname(path), "journal-failure.json")
    assert eventually(fn -> File.exists?(report) end) == :ok
    assert Bitwise.band(File.stat!(report).mode, 0o777) == 0o600
    JSON.decode!(File.read!(report))
  end

  describe "rejected writes" do
    test "a message that cannot be persisted is refused without stopping the owner", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      :ok = Journal.append_message(journal, Message.user("hello"))
      {:ok, before} = Journal.status(journal)

      bad_message = Message.assistant(content: "hi", provider_state: %{"pid" => self()})

      assert {:error, {:invalid_message, {:forbidden_term, :pid}}} =
               Journal.append_message(journal, bad_message)

      assert {:error, {:invalid_tool_call, {:forbidden_term, :pid}}} =
               Journal.tool_started(journal, %{
                 id: "call-1",
                 name: "read",
                 arguments: %{"x" => self()}
               })

      assert {:error, {:invalid_settlement, {:forbidden_term, :pid}}} =
               Journal.settle_turn(journal, "turn.completed", %{"reason" => self()})

      assert Process.alive?(journal)
      assert {:ok, ^before} = Journal.status(journal)
      assert_journal_usable(ctx, journal, ["hello", "after"])
    end

    test "a commit that would not fold is refused before it is written", ctx do
      {:ok, journal} = start_journal(ctx, tree: true)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      user = Message.user("hello")
      :ok = Journal.append_message(journal, user, {:tree, nil})
      {:ok, before} = Journal.status(journal)

      assert {:error, {:invalid_commit, {:duplicate_entry, _id}}} =
               Journal.append_message(journal, user, {:tree, user.id})

      assert {:error, {:invalid_commit, {:unknown_parent, "missing"}}} =
               Journal.append_message(journal, Message.user("orphan"), {:tree, "missing"})

      navigation = %Tree.Change{
        from_id: user.id,
        to_id: "missing",
        selected_id: "missing",
        mode: :move,
        revision: 1
      }

      assert {:error, {:invalid_commit, _reason}} = Journal.tree_navigated(journal, navigation)

      assert Process.alive?(journal)
      assert {:ok, ^before} = Journal.status(journal)
      assert_journal_usable(ctx, journal, ["hello", "after"])
    end
  end

  describe "settling a turn" do
    test "refuses a turn other than the active one", ctx do
      {:ok, journal} = start_journal(ctx)
      turn_id = ID.generate()
      {:ok, ^turn_id} = Journal.begin_turn(journal, :run, "hello", turn_id)

      assert {:error, :turn_mismatch} =
               Journal.settle_turn(journal, "turn.completed", %{"turn_id" => "other-turn"})

      assert :ok = Journal.settle_turn(journal, "turn.completed", %{"turn_id" => turn_id})

      assert {:error, :turn_mismatch} =
               Journal.settle_turn(journal, "turn.completed", %{"turn_id" => turn_id})

      assert {:error, :turn_mismatch} =
               Journal.settle_turn(journal, "turn.errored", %{"turn_id" => "never-started"})

      assert {:error, :no_active_turn} = Journal.settle_turn(journal, "turn.completed", %{})
      stop_journal(journal)

      {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)

      terminals =
        Enum.filter(replay.commits, &(commit_type?(&1) == %{"type" => "turn.completed"}))

      assert [%{"turn_id" => ^turn_id}] = terminals
      assert Map.keys(replay.projection.turns) == [turn_id]
    end

    test "settles the interrupted turn of a reopened journal, and only that one", ctx do
      {:ok, journal} = start_journal(ctx)
      turn_id = ID.generate()
      {:ok, ^turn_id} = Journal.begin_turn(journal, :run, "hello", turn_id)
      stop_journal(journal)

      {:ok, journal} = start_journal(ctx)

      assert {:error, :turn_mismatch} =
               Journal.settle_turn(journal, "turn.abandoned", %{"turn_id" => "other-turn"})

      assert :ok = Journal.settle_turn(journal, "turn.abandoned", %{"turn_id" => turn_id})
      assert {:ok, %{active_turn: nil}} = Journal.projection(journal)
    end
  end

  describe "repair" do
    test "requires explicit repair for an uncleanly closed log", ctx do
      {:ok, journal} = start_journal(ctx)
      turn_id = ID.generate()
      {:ok, ^turn_id} = Journal.begin_turn(journal, :run, "hello", turn_id)
      :ok = Journal.append_message(journal, Message.user("hello"))
      :ok = Journal.settle_turn(journal, "turn.completed", %{})
      stop_journal(journal)

      mark_unclean!(ctx)

      assert {:error, {:repair_required, _path}} =
               Reader.open_writable(ctx.session_id, home: ctx.home, repair: false)

      assert {:ok, opened} = Reader.open_writable(ctx.session_id, home: ctx.home, repair: true)
      assert opened.recovered["bad_bytes"] == 0
      assert is_integer(opened.recovered["recovered_items"])
      Reader.close(opened.name)

      assert {:ok, files} = recovery_files(ctx)
      assert Enum.any?(files, &String.contains?(&1, "session.dlog"))
    end

    test "records session.recovered after a repaired open", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      :ok = Journal.append_message(journal, Message.user("hello"))
      :ok = Journal.settle_turn(journal, "turn.completed", %{})
      stop_journal(journal)

      mark_unclean!(ctx)

      {:ok, journal} = start_journal(ctx, repair: true)
      assert {:ok, projection} = Journal.projection(journal)
      assert projection.status == :recovered

      {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)
      assert replay.projection.status == :recovered
    end
  end

  describe "validation during replay" do
    test "rejects a sequence gap", ctx do
      write_raw_journal!(ctx, [
        header(ctx),
        commit(ctx, 2, [Log.event("turn.started", %{"turn_id" => "t", "operation" => "run"})])
      ])

      assert {:error, {:sequence_mismatch, 1, 2}} = Reader.read(ctx.session_id, home: ctx.home)
    end

    test "rejects an unknown required event", ctx do
      write_raw_journal!(ctx, [
        header(ctx),
        commit(ctx, 1, [Log.event("mystery.event", %{}, required: true)])
      ])

      assert {:error, {:unsupported_required_event, "mystery.event", 1}} =
               Reader.read(ctx.session_id, home: ctx.home)
    end

    test "ignores an unknown optional event", ctx do
      write_raw_journal!(ctx, [
        header(ctx),
        commit(ctx, 1, [Log.event("mystery.event", %{}, required: false)])
      ])

      assert {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)
      assert replay.projection.last_seq == 1
    end

    test "rejects a forbidden runtime term in a commit", ctx do
      write_raw_journal!(ctx, [
        header(ctx),
        %{
          commit(ctx, 1, [Log.event("turn.started", %{"turn_id" => "t"})])
          | "events" => [
              %{
                "type" => "turn.started",
                "version" => 1,
                "required" => true,
                "data" => %{"pid" => self()}
              }
            ]
        }
      ])

      assert {:error, {:invalid_event_data, "turn.started", {:forbidden_term, :pid}}} =
               Reader.read(ctx.session_id, home: ctx.home)
    end

    test "rejects a header with a mismatched session id" do
      home = tmp_home()
      session_id = ID.generate()
      other = ID.generate()

      write_raw_journal!(%{home: home, session_id: session_id}, [
        Log.header(session_id: other, created_at: now(), cwd: nil, parent: nil)
      ])

      assert {:error, {:header_session_mismatch, ^other, ^session_id}} =
               Reader.read(session_id, home: home)
    end
  end

  describe "configuration changes" do
    test "record the normalized thinking level, never a raw adapter option", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      base = config()

      # A provider-specific value a host set directly is not a level, and a
      # tuple could not be journaled at all.
      custom = %{base | llm_opts: Keyword.put(base.llm_opts, :reasoning_effort, {:budget, 2048})}
      unset = %{base | llm_opts: Keyword.delete(base.llm_opts, :reasoning_effort)}
      high = %{base | llm_opts: Keyword.put(base.llm_opts, :reasoning_effort, "high")}

      assert :ok = Journal.configuration_changed(journal, custom)
      assert :ok = Journal.configuration_changed(journal, unset)
      assert :ok = Journal.configuration_changed(journal, high)
      assert {:ok, %{thinking: "high"}} = Journal.projection(journal)
      stop_journal(journal)

      {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)

      thinking =
        for commit <- replay.commits,
            %{"type" => "session.configuration_changed", "data" => data} <- commit["events"],
            do: data["thinking"]

      assert thinking == ["off", "off", "high"]
    end
  end

  describe "shutdown" do
    test "the supervisor waits for the guarded cleanup deadline" do
      default = Journal.child_spec(session_id: "s")
      custom = Journal.child_spec(session_id: "s", journal_timeout: 30_000)

      assert default.shutdown > 15_000
      assert custom.shutdown > 30_000
    end

    test "after losing the writer lock the owner writes nothing more into the directory", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      {:ok, summary} = Storage.summary_path(ctx.session_id, home: ctx.home)
      %{lock: %{port: port}} = :sys.get_state(journal)
      ref = Process.monitor(journal)

      send(journal, {port, {:exit_status, 1}})

      assert_receive {:DOWN, ^ref, :process, ^journal,
                      {:journal_failure, {:writer_lock_lost, 1}}},
                     1_000

      refute File.exists?(summary)
    end

    test "a normal stop writes the summary sidecar", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      {:ok, summary} = Storage.summary_path(ctx.session_id, home: ctx.home)
      stop_journal(journal)

      assert File.exists?(summary)
    end
  end

  describe "storage ownership" do
    test "a lock this OS process holds briefly is waited out without stopping the owner", ctx do
      create_session!(ctx)
      holder = hold_lock(ctx)

      # Every failed attempt is a lock process that exits; none may stop the owner.
      Process.send_after(holder, :release, 300)
      assert {:ok, journal} = start_journal(ctx)
      ref = Process.monitor(journal)

      refute_receive {:DOWN, ^ref, :process, ^journal, _reason}, 200
      assert {:ok, %{materialized?: true}} = Journal.status(journal)
      assert {:ok, _turn_id} = Journal.begin_turn(journal, :run, "again")
      stop_journal(journal)
    end

    test "a session moved away while its lock is awaited is not recreated empty", ctx do
      create_session!(ctx)
      {:ok, path} = Storage.journal_path(ctx.session_id, home: ctx.home)
      dir = Path.dirname(path)
      holder = hold_lock(ctx)
      test_pid = self()

      spawn(fn ->
        # A failed start also sends the linked caller its exit signal.
        Process.flag(:trap_exit, true)
        send(test_pid, {:started, start_journal(ctx)})
      end)

      # The owner found the journal and now waits for the lock.
      assert eventually(fn -> owner_stage(ctx.session_id) == :acquire_lock end) == :ok

      # A move (under the lock) takes the session away; a directory of the same
      # name appears again, as one recreated by an unguarded lock attempt would.
      File.rename!(dir, dir <> "-moved")
      File.mkdir_p!(dir)
      send(holder, :release)

      assert_receive {:started, result}, 5_000
      assert result == {:error, {:session_not_found, ctx.session_id}}
      refute File.exists?(path)
    end

    test "the journal file is private, also one an earlier version left readable", ctx do
      opts = [cwd: "/tmp/private-project"]
      {:ok, journal} = start_journal(ctx, opts)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      {:ok, path} = Storage.journal_path(ctx.session_id, [home: ctx.home] ++ opts)
      {:ok, root} = Storage.sessions_root(home: ctx.home)

      assert file_mode(path) == 0o600
      assert file_mode(root) == 0o700
      assert file_mode(Path.dirname(Path.dirname(path))) == 0o700
      stop_journal(journal)

      File.chmod!(path, 0o644)
      {:ok, journal} = start_journal(ctx, opts)
      assert file_mode(path) == 0o600
      stop_journal(journal)
    end

    test "rejects a second journal owner in the same node", ctx do
      {:ok, _journal} = start_journal(ctx)
      assert {:error, {:already_started, _pid}} = start_journal(ctx)
    end

    test "the on-disk lock rejects a second writable owner", ctx do
      assert {:ok, lock} = Storage.acquire_lock(ctx.session_id, home: ctx.home)

      assert {:error, {:session_in_use, _owner}} =
               Storage.acquire_lock(ctx.session_id, home: ctx.home)

      assert :ok = Storage.release_lock(lock)
      assert {:ok, _lock} = Storage.acquire_lock(ctx.session_id, home: ctx.home)
    end
  end

  defp start_journal(ctx, opts \\ []) do
    case Journal.start_link([session_id: ctx.session_id, home: ctx.home] ++ opts) do
      {:ok, pid} ->
        # The test process must not be linked to a journal that intentionally
        # stops on failure; production starts it under a supervisor.
        Process.unlink(pid)
        {:ok, pid}

      error ->
        error
    end
  end

  defp await_queued_append(journal, message_id) do
    assert eventually(fn ->
             {:messages, messages} = Process.info(journal, :messages)

             Enum.any?(messages, fn
               {:"$gen_call", _from,
                {:append_message, %Message{id: ^message_id}, _parent, _sync?}} ->
                 true

               _other ->
                 false
             end)
           end) == :ok
  end

  defp file_mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp create_session!(ctx) do
    {:ok, journal} = start_journal(ctx)
    {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
    :ok = Journal.settle_turn(journal, "turn.completed", %{})
    stop_journal(journal)
  end

  # Holds the session's writer lock in another process of this OS process
  # until it receives `:release`.
  defp hold_lock(ctx) do
    test_pid = self()

    holder =
      spawn(fn ->
        {:ok, lock} = Storage.acquire_lock(ctx.session_id, home: ctx.home)
        send(test_pid, :locked)

        receive do
          :release -> Storage.release_lock(lock)
        end
      end)

    assert_receive :locked, 5_000
    holder
  end

  defp owner_stage(session_id) do
    with {:ok, owner} <- Journal.whereis(session_id),
         [{watchdog, _}] <-
           Registry.lookup(Tackle.Session.JournalRegistry, {:journal_watchdog, owner}) do
      :sys.get_state(watchdog).stage
    else
      _other -> nil
    end
  end

  # The journal still accepts writes (an "after" answer), and its file replays
  # and reopens with `contents`.
  defp assert_journal_usable(ctx, journal, contents) do
    assert :ok = Journal.append_message(journal, Message.assistant(content: "after"))
    assert :ok = Journal.settle_turn(journal, "turn.completed", %{})
    stop_journal(journal)

    assert {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)
    assert Enum.map(replay.projection.messages, & &1["content"]) == contents

    {:ok, reopened} = start_journal(ctx)
    assert {:ok, %{messages: messages}} = Journal.projection(reopened)
    assert length(messages) == length(contents)
    stop_journal(reopened)
  end

  defp stop_journal(journal) do
    if Process.alive?(journal), do: GenServer.stop(journal)
  catch
    :exit, _reason -> :ok
  end

  defp mark_unclean!(ctx) do
    {:ok, path} = Storage.journal_path(ctx.session_id, home: ctx.home)
    <<magic::binary-size(4), _status::binary-size(4), rest::binary>> = File.read!(path)
    File.write!(path, magic <> <<6, 7, 8, 9>> <> rest)
    :ok
  end

  defp write_raw_journal!(ctx, items) do
    {:ok, dir} = Storage.ensure_session_dir(ctx.session_id, home: ctx.home)
    path = Path.join(dir, "session.dlog")
    name = {:tackle_test_raw, ctx.session_id}

    {:ok, name} =
      :disk_log.open(
        name: name,
        file: String.to_charlist(path),
        type: :halt,
        format: :internal,
        mode: :read_write,
        repair: false,
        notify: false,
        size: :infinity
      )

    Enum.each(items, fn item -> :ok = :disk_log.log(name, item) end)
    :ok = :disk_log.sync(name)
    :ok = :disk_log.close(name)
  end

  defp header(ctx) do
    Log.header(session_id: ctx.session_id, created_at: now(), cwd: "/tmp", parent: nil)
  end

  defp commit(ctx, seq, events) do
    Log.commit(
      session_id: ctx.session_id,
      seq: seq,
      commit_id: ID.generate(),
      written_at: now(),
      turn_id: nil,
      events: events
    )
  end

  defp list_dir(dir), do: File.ls(dir)

  defp recovery_files(ctx) do
    with {:ok, dir} <- Storage.recovery_dir(ctx.session_id, home: ctx.home) do
      list_dir(dir)
    end
  end

  defp commit_type?(%{"events" => [event | _rest]}), do: %{"type" => event["type"]}

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
