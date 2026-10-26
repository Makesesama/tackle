defmodule Tackle.Session.CatalogTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Runtime.ID
  alias Tackle.Session.Catalog
  alias Tackle.Session.Catalog.Entry
  alias Tackle.Session.Journal
  alias Tackle.Session.Log
  alias Tackle.Session.Storage

  setup do
    home = tmp_home()
    {:ok, home: home}
  end

  test "lists and searches durable sessions", ctx do
    cwd = unique_cwd(ctx, "alpha")
    create_session(ctx, cwd: cwd, title: "Alpha work", content: "answer")
    other = unique_cwd(ctx, "beta")
    create_session(ctx, cwd: other, title: "Beta work", content: "answer")

    Catalog.rebuild(home: ctx.home)

    assert {:ok, %{sessions: sessions}} = Tackle.list_sessions(%{cwd: cwd})
    assert Enum.map(sessions, & &1.title) == ["Alpha work"]

    assert {:ok, %{sessions: found}} = Tackle.search_sessions("Alpha work")
    assert Enum.map(found, & &1.cwd) == [cwd]
  end

  test "its crash reports show neither cached search text nor options" do
    waiting = {{:candidates, %{text: "secret query"}}, {self(), make_ref()}}

    status = %{
      state: %{
        table: Catalog,
        opts: [env: %{"TACKLE_SECRET" => "secret"}],
        rebuild: nil,
        deferred: [waiting]
      },
      message: {:"$gen_cast", {:cache_search_text, "session", 3, "secret conversation"}},
      reason: :boom,
      log: [{:in, {:"$gen_cast", {:record, %{preview: "secret preview"}}}}]
    }

    redacted = Catalog.format_status(status)

    refute inspect(redacted, limit: :infinity, printable_limit: :infinity) =~ "secret"

    assert redacted.state == %{
             table: Catalog,
             opts: [:env],
             rebuild: nil,
             deferred: [:candidates]
           }

    assert redacted.message == {:"$gen_cast", :cache_search_text}
    assert redacted.reason == :boom
  end

  test "excludes tool arguments and tool output from default search", ctx do
    secret = "SECRET-#{System.unique_integer([:positive])}"
    path = Path.join(ctx.home, "tool-input.txt")
    File.write!(path, secret)

    tool_call = %{"id" => "call_1", "name" => "read", "arguments" => %{"path" => path}}

    scope =
      start_durable_scope(
        home: ctx.home,
        root: [
          tools: [Tackle.Tools.Read],
          mode: :tool_then_answer,
          llm_opts: [tool_call: tool_call, content: "done"]
        ]
      )

    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "please read a file")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

    assert {:ok, entry} = Tackle.session_summary(snapshot.session_id, home: ctx.home)
    refute Map.has_key?(entry, :search_text)

    assert {:ok, %{sessions: []}} = Tackle.search_sessions(secret)
  end

  test "builds a live session's search text only when searching", ctx do
    marker = "WOMBAT#{System.unique_integer([:positive])}"
    scope = start_durable_scope(home: ctx.home, root: [content: "answer"])
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    session_id = snapshot.session_id
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "look for #{marker} please")
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000

    # Journal commits index metadata only; the text is not built per commit.
    assert eventually(fn -> match?({:ok, _}, Catalog.get(session_id)) end) == :ok
    assert %Entry{search_text: nil} = catalog_entry(session_id)

    assert {:ok, %{sessions: [%{session_id: ^session_id}]}} = Tackle.search_sessions(marker)
    assert eventually(fn -> is_binary(catalog_entry(session_id).search_text) end) == :ok

    # A later turn replaces the cached text, so new words are found too.
    next = "KOALA#{System.unique_integer([:positive])}"
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "then #{next}")
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000
    assert {:ok, %{sessions: [%{session_id: ^session_id}]}} = Tackle.search_sessions(next)
  end

  test "searches a session closed in this run from its file", ctx do
    marker = "PLATYPUS#{System.unique_integer([:positive])}"
    session_id = create_session(ctx, cwd: unique_cwd(ctx, "closed"), title: marker <> " title")
    assert {:error, :not_found} = Journal.whereis(session_id)
    assert %Entry{search_text: nil, journal_path: path} = catalog_entry(session_id)
    assert is_binary(path)

    # The first user message ("hello from <title>") is only in the file.
    assert {:ok, %{sessions: [%{session_id: ^session_id}]}} =
             Tackle.search_sessions("hello from #{marker}")
  end

  test "filters by a status given as an atom or a string", ctx do
    cwd = unique_cwd(ctx, "status")
    Catalog.rebuild(home: ctx.home)
    Catalog.record(%{session_id: "running", cwd: cwd, status: :active, updated_at: "2"})
    Catalog.record(%{session_id: "stopped", cwd: cwd, status: :clean, updated_at: "1"})

    for status <- [:active, "active"] do
      assert {:ok, %{sessions: [%{session_id: "running"}]}} =
               Catalog.list(cwd: cwd, status: status)
    end

    assert {:ok, %{sessions: [%{session_id: "stopped"}]}} =
             Catalog.list(cwd: cwd, status: "clean")

    assert {:ok, %{sessions: []}} = Catalog.list(cwd: cwd, status: "no-such-status")
  end

  test "paginates with a stable cursor", ctx do
    cwd = unique_cwd(ctx, "paged")
    ids = for index <- 1..3, do: create_session(ctx, cwd: cwd, title: "Page #{index}")

    Catalog.rebuild(home: ctx.home)

    {:ok, %{sessions: first_page, next_cursor: cursor}} =
      Tackle.list_sessions(%{cwd: cwd, limit: 2})

    assert [_, _] = first_page
    assert is_binary(cursor)

    {:ok, %{sessions: second_page, next_cursor: nil}} =
      Tackle.list_sessions(%{cwd: cwd, limit: 2, cursor: cursor})

    assert [_session] = second_page

    all_ids = Enum.map(first_page ++ second_page, & &1.session_id)
    assert Enum.sort(all_ids) == Enum.sort(ids)
  end

  test "rebuilds missing or corrupt summaries from journals", ctx do
    cwd = unique_cwd(ctx, "rebuild")
    session_id = create_session(ctx, cwd: cwd, title: "Rebuildable")

    {:ok, path} = Storage.summary_path(session_id, home: ctx.home, cwd: cwd)
    File.write!(path, "not an etf sidecar")

    Catalog.rebuild(home: ctx.home)

    assert {:ok, entry} = Catalog.get(session_id)
    assert entry.title == "Rebuildable"
    assert entry.last_indexed_seq > 0
  end

  test "uses a sidecar whose journal is unchanged without replaying it", ctx do
    cwd = unique_cwd(ctx, "current")
    session_id = create_session(ctx, cwd: cwd, title: "Current")
    {:ok, path} = Storage.journal_path(session_id, home: ctx.home, cwd: cwd)

    # Same size and modification time, but no longer a journal: a replay
    # would fail, so the session is indexed only if its sidecar is trusted.
    %File.Stat{size: size, mtime: mtime} = File.stat!(path, time: :posix)
    File.write!(path, :binary.copy(<<0>>, size))
    File.touch!(path, mtime)

    assert %{indexed: 1, stale: 0, skipped: 0} = Catalog.rebuild(home: ctx.home)
    assert {:ok, %{title: "Current", stale: false}} = Catalog.get(session_id)
  end

  test "replays a journal that changed since its sidecar, or an old sidecar", ctx do
    cwd = unique_cwd(ctx, "changed")
    session_id = create_session(ctx, cwd: cwd, title: "Journal title")
    {:ok, summary} = Storage.summary_path(session_id, home: ctx.home, cwd: cwd)

    for journal <- [%{"size" => 1, "mtime" => 1}, :absent] do
      rewrite_sidecar!(summary, session_id, journal, "Sidecar title")

      assert %{indexed: 1, skipped: 0} = Catalog.rebuild(home: ctx.home)
      assert {:ok, %{title: "Journal title"}} = Catalog.get(session_id)
    end
  end

  test "a replay that times out falls back to the sidecar, marked stale", ctx do
    cwd = unique_cwd(ctx, "slow")
    session_id = create_session(ctx, cwd: cwd, title: "Journal title")
    {:ok, summary} = Storage.summary_path(session_id, home: ctx.home, cwd: cwd)
    rewrite_sidecar!(summary, session_id, :absent, "Sidecar title")

    report =
      with_disk_log_stalled(fn ->
        Catalog.rebuild(home: ctx.home, rebuild_session_timeout: 300)
      end)

    assert report == %{indexed: 1, stale: 1, skipped: 0}
    assert {:ok, %{title: "Sidecar title", stale: true}} = Catalog.get(session_id)
  end

  test "reads wait for a running rebuild, which keeps journal updates", ctx do
    cwd = unique_cwd(ctx, "waiting")
    session_id = create_session(ctx, cwd: cwd, title: "Waiting")
    {:ok, summary} = Storage.summary_path(session_id, home: ctx.home, cwd: cwd)
    # Without a current sidecar the rebuild has to replay the journal.
    rewrite_sidecar!(summary, session_id, :absent, "Waiting")

    # Longer than a default `GenServer.call/2` timeout.
    rebuild_timeout = 5_300

    {listed, recorded} =
      with_disk_log_stalled(fn ->
        rebuild =
          Task.async(fn ->
            Catalog.rebuild(home: ctx.home, rebuild_session_timeout: rebuild_timeout)
          end)

        # The rebuild is replaying the journal once its open waits.
        assert eventually(fn -> disk_log_waiting?() end) == :ok

        Catalog.record(%{session_id: "live", title: "Live", updated_at: "9"})
        listed = Catalog.list(%{})
        Task.await(rebuild, :infinity)
        {listed, Catalog.get("live")}
      end)

    assert {:ok, %{sessions: sessions}} = listed
    assert "live" in Enum.map(sessions, & &1.session_id)
    assert {:ok, %{title: "Live"}} = recorded
  end

  test "a stalled session does not block the catalog rebuild", ctx do
    healthy_id = create_session(ctx, cwd: unique_cwd(ctx, "healthy"), title: "Healthy")
    blocked_dir = Path.join([ctx.home, "sessions", "blocked-journal"])
    journal_path = Path.join(blocked_dir, "session.dlog")
    blocked_summary_dir = Path.join([ctx.home, "sessions", "blocked-summary"])
    summary_path = Path.join(blocked_summary_dir, "summary.etf")
    File.mkdir_p!(blocked_dir)
    File.mkdir_p!(blocked_summary_dir)
    _ = File.rm(journal_path)
    _ = File.rm(summary_path)

    mkfifo = System.find_executable("mkfifo") || flunk("mkfifo is required for this test")
    assert {"", 0} = System.cmd(mkfifo, [journal_path], stderr_to_stdout: true)
    assert {"", 0} = System.cmd(mkfifo, [summary_path], stderr_to_stdout: true)

    started_at = System.monotonic_time(:millisecond)

    assert %{indexed: 1, skipped: 2} =
             Catalog.rebuild(home: ctx.home, rebuild_session_timeout: 250)

    assert System.monotonic_time(:millisecond) - started_at < 2_000
    assert {:ok, %{session_id: ^healthy_id}} = Catalog.get(healthy_id)
  end

  test "a malformed journal is skipped by rebuild and search instead of crashing", ctx do
    healthy_id = create_session(ctx, cwd: unique_cwd(ctx, "healthy"), title: "Healthy")
    broken = %{home: ctx.home, session_id: ID.generate()}

    write_raw_journal!(broken, [
      Log.header(session_id: broken.session_id, created_at: now(), cwd: nil, parent: nil),
      Log.commit(
        session_id: broken.session_id,
        seq: 1,
        commit_id: ID.generate(),
        written_at: now(),
        events: [Log.event("message.appended", %{"parent_id" => nil})]
      )
    ])

    assert %{indexed: 1, skipped: 1} = Catalog.rebuild(home: ctx.home)
    assert {:ok, %{session_id: ^healthy_id}} = Catalog.get(healthy_id)

    # An entry recorded earlier still points at the file; searching it falls
    # back to the entry's metadata.
    {:ok, path} = Storage.journal_path(broken.session_id, home: ctx.home)
    Catalog.record(%{session_id: broken.session_id, title: "Broken", journal_path: path})

    assert {:ok, %{sessions: [%{session_id: id}]}} = Tackle.search_sessions("Broken")
    assert id == broken.session_id
    assert {:ok, %{sessions: []}} = Tackle.search_sessions("nothing matches this")
    assert Process.alive?(Process.whereis(Catalog))
  end

  test "marks stale projections and catches them up by sequence", ctx do
    cwd = unique_cwd(ctx, "stale")

    scope =
      start_durable_scope(
        home: ctx.home,
        session: [cwd: cwd, title: "Stale"],
        root: [content: "a"]
      )

    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "first")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

    assert {:ok, entry} = Catalog.get(snapshot.session_id)
    first_seq = entry.last_indexed_seq

    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "second")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000

    assert {:ok, updated} = Catalog.get(snapshot.session_id)
    assert updated.last_indexed_seq > first_seq
  end

  defp create_session(ctx, opts) do
    root_opts = [content: Keyword.get(opts, :content, "answer")]
    session_opts = opts |> Keyword.take([:cwd, :title, :tags]) |> Keyword.put(:home, ctx.home)

    scope = start_durable_scope(home: ctx.home, session: session_opts, root: root_opts)
    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "hello from #{opts[:title]}")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000
    stop_scope(scope.scope_ref)
    snapshot.session_id
  end

  defp catalog_entry(session_id) do
    [{^session_id, entry}] = :ets.lookup(Catalog, session_id)
    entry
  end

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())

  # `journal` is the file stat to record, or `:absent` for a sidecar written
  # before sidecars recorded it.
  defp rewrite_sidecar!(path, session_id, journal, title) do
    {:ok, payload} = Catalog.read_sidecar_file(path, session_id)
    payload = put_in(payload, ["summary", "title"], title)

    payload =
      if journal == :absent,
        do: Map.delete(payload, "journal"),
        else: Map.put(payload, "journal", journal)

    File.write!(path, :erlang.term_to_binary(payload))
  end

  # Every `:disk_log.open/1` waits while the log server is suspended, so
  # replaying a journal stalls while reading its sidecar does not.
  defp with_disk_log_stalled(fun) do
    server = Process.whereis(:disk_log_server)
    :ok = :sys.suspend(server)

    try do
      fun.()
    after
      :sys.resume(server)
    end
  end

  defp disk_log_waiting? do
    {:message_queue_len, waiting} =
      Process.info(Process.whereis(:disk_log_server), :message_queue_len)

    waiting > 0
  end

  defp unique_cwd(ctx, label) do
    Path.join(ctx.home, "cwd-#{label}-#{System.unique_integer([:positive])}")
  end
end
