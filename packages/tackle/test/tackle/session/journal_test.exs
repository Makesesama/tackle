defmodule Tackle.Session.JournalTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Runtime.ID
  alias Tackle.Session.Journal
  alias Tackle.Session.Journal.Watchdog
  alias Tackle.Session.Loader
  alias Tackle.Session.Log
  alias Tackle.Session.Persistence
  alias Tackle.Session.Reader
  alias Tackle.Session.Storage

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
      assert [%Tackle.Lib.Message{role: :user, content: "hello"}] = decode_messages(projection)

      assert {:ok, _turn_id} = Journal.begin_turn(journal, :continue, nil)
      assert {:ok, status} = Journal.status(journal)
      assert status.last_seq == 6
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

    test "stalled disk sync stops the owner without discarding earlier durable history", ctx do
      {:ok, journal} = start_journal(ctx, journal_timeout: 250)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      assert :ok = Journal.append_message(journal, Message.user("hello"))
      log = {:tackle_session, ctx.session_id}
      assert :ok = :disk_log.block(log, true)
      ref = Process.monitor(journal)

      assert {:error, {:journal_stalled, diagnostic}} = Journal.flush(journal)
      assert diagnostic["stage"] == "sync"
      assert_receive {:DOWN, ^ref, :process, ^journal, :killed}, 1_000
      assert :disk_log.unblock(log) in [:ok, {:error, :no_such_log}]
      # The log backend may finish work already dispatched before owner death.
      # Reading validates durable history; no append is automatically retried.
      assert {:ok, replay} = Reader.read(ctx.session_id, home: ctx.home)
      assert [%{"content" => "hello"}] = replay.projection.messages
    end

    test "failure cleanup is bounded even when disk sync is blocked", ctx do
      {:ok, journal} = start_journal(ctx, journal_timeout: 250)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")
      log = {:tackle_session, ctx.session_id}
      assert :ok = :disk_log.block(log, true)
      ref = Process.monitor(journal)
      bad_message = Message.assistant(content: "hi", provider_state: %{"pid" => self()})

      assert {:error, {:journal_stalled, diagnostic}} =
               Journal.append_message(journal, bad_message)

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

    test "missing owners fail closed only for durable hook contexts", ctx do
      state = %State{session_id: ctx.session_id}
      message = Message.assistant(content: "answer")

      assert {:error, {:journal_unavailable, :not_found}} =
               Persistence.after_message(state, message, %{journal_required: true})

      assert {:error, {:journal_unavailable, :not_found}} =
               Persistence.before_tool_call(state, %{}, %{journal_required: true})

      assert :ok = Persistence.after_message(state, message, %{})
      assert :ok = Persistence.before_tool_call(state, %{}, %{})
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

  describe "fail-closed behavior" do
    test "stops the owner when a message cannot be persisted", ctx do
      {:ok, journal} = start_journal(ctx)
      {:ok, _turn_id} = Journal.begin_turn(journal, :run, "hello")

      bad_message = Message.assistant(content: "hi", provider_state: %{"pid" => self()})

      assert {:error, {:journal_failure, {:invalid_message, {:forbidden_term, :pid}}}} =
               Journal.append_message(journal, bad_message)

      ref = Process.monitor(journal)
      assert_receive {:DOWN, ^ref, :process, ^journal, _reason}, 1_000
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

  describe "storage ownership" do
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
               {:"$gen_call", _from, {:append_message, %Message{id: ^message_id}, _parent}} ->
                 true

               _other ->
                 false
             end)
           end) == :ok
  end

  defp stop_journal(journal) do
    if Process.alive?(journal), do: GenServer.stop(journal)
  catch
    :exit, _reason -> :ok
  end

  defp decode_messages(projection) do
    {:ok, messages} = Loader.decode_messages(projection.messages)
    messages
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
