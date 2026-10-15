defmodule Tackle.Session.CompressionTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Session.Catalog
  alias Tackle.Session.Compression
  alias Tackle.Session.Storage
  alias Tackle.Session.Storage.Lock

  @week_ago 8 * 24 * 3600

  unless Code.ensure_loaded?(:zstd), do: @moduletag(skip: "needs :zstd (OTP 28 or later)")

  setup do
    {:ok, home: tmp_home()}
  end

  test "compresses an idle journal and keeps it readable, indexable, and resumable", ctx do
    {session_id, cwd} = closed_session(ctx, "Idle work")
    location = [home: ctx.home, cwd: cwd]
    {:ok, path} = Storage.journal_path(session_id, location)
    {:ok, before} = Tackle.inspect_session(session_id, location)
    plain_size = File.stat!(path).size
    age(path)

    assert {:ok, report} = compress(ctx)
    assert report.compressed == 1
    assert report.bytes_before == plain_size
    assert report.bytes_after < plain_size
    refute File.exists?(path)
    assert File.regular?(Storage.compressed_path(path))
    assert Storage.journal_exists?(session_id, location)

    # Reads replay a temporary copy and leave nothing behind.
    assert {:ok, after_read} = Tackle.inspect_session(session_id, location)
    assert after_read.messages == before.messages
    assert after_read.last_seq == before.last_seq

    files = File.ls!(Path.dirname(path))
    assert "session.dlog.zst" in files
    refute "session.dlog" in files
    refute Enum.any?(files, &String.starts_with?(&1, "session.dlog.read-"))

    # The catalog indexes it from the sidecar.
    Catalog.rebuild(home: ctx.home)
    assert {:ok, %{title: "Idle work", last_indexed_seq: seq}} = Catalog.get(session_id)
    assert seq == before.last_seq

    # A writable owner restores the plain journal and continues it.
    scope =
      start_durable_scope(
        home: ctx.home,
        session: [session_id: session_id, cwd: cwd],
        root: [content: "continued"]
      )

    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    assert snapshot.session_id == session_id
    assert File.regular?(path)
    refute File.exists?(Storage.compressed_path(path))

    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "again")
    assert_receive {:tackle_turn_finished, ^session_id, ^turn_id, {:ok, _state}}, 5_000
    stop_scope(scope.scope_ref)

    assert {:ok, resumed} = Tackle.inspect_session(session_id, location)
    assert length(resumed.messages) == length(before.messages) + 2
  end

  test "leaves recent journals and live sessions alone", ctx do
    {fresh_id, fresh_cwd} = closed_session(ctx, "Fresh")
    {:ok, fresh_path} = Storage.journal_path(fresh_id, home: ctx.home, cwd: fresh_cwd)

    {live_id, live_cwd, _scope} = live_session(ctx)
    {:ok, live_path} = Storage.journal_path(live_id, home: ctx.home, cwd: live_cwd)
    age(live_path)

    assert {:ok, %{compressed: 0, skipped: 1}} = compress(ctx)
    assert File.regular?(fresh_path)
    assert File.regular?(live_path)
    refute File.exists?(Storage.compressed_path(live_path))
  end

  test "a pass runs at most once per interval unless forced", ctx do
    assert {:ok, %{compressed: 0}} = Compression.compress_idle(home: ctx.home)
    assert {:ok, :recently_run} = Compression.compress_idle(home: ctx.home)
    assert {:ok, %{compressed: 0}} = compress(ctx)
  end

  test "brings a stale summary sidecar up to date before compressing", ctx do
    {session_id, cwd} = closed_session(ctx, "Sidecar")
    location = [home: ctx.home, cwd: cwd]
    {:ok, path} = Storage.journal_path(session_id, location)
    {:ok, summary} = Storage.summary_path(session_id, location)
    File.rm!(summary)
    age(path)

    assert {:ok, %{compressed: 1}} = compress(ctx)
    assert {:ok, sidecar} = Catalog.read_sidecar_file(summary, session_id)
    {:ok, inspected} = Tackle.inspect_session(session_id, location)
    assert sidecar["last_indexed_seq"] == inspected.last_seq
    assert sidecar["summary"]["title"] == "Sidecar"
  end

  test "compressed sessions can be archived, restored, and forked", ctx do
    {session_id, cwd} = closed_session(ctx, "Portable")
    location = [home: ctx.home, cwd: cwd]
    {:ok, path} = Storage.journal_path(session_id, location)
    age(path)
    assert {:ok, %{compressed: 1}} = compress(ctx)

    assert :ok = Tackle.archive_session(session_id, location)

    assert {:ok, %{messages: [_ | _]}} =
             Tackle.inspect_session(session_id, Keyword.put(location, :archived, true))

    assert :ok = Tackle.unarchive_session(session_id, location)
    assert {:ok, child_id} = Tackle.fork_session(session_id, location)
    assert {:ok, %{messages: [_ | _]}} = Tackle.inspect_session(child_id, location)
  end

  test "the plain journal wins over a leftover compressed copy", ctx do
    {session_id, cwd} = closed_session(ctx, "Both")
    {:ok, path} = Storage.journal_path(session_id, home: ctx.home, cwd: cwd)
    File.write!(Storage.compressed_path(path), "not zstd")

    assert {:ok, _replay} = Tackle.inspect_session(session_id, home: ctx.home, cwd: cwd)
    assert :ok = Compression.restore(path)
    assert File.regular?(path)
    refute File.exists?(Storage.compressed_path(path))
  end

  test "a corrupt compressed journal is an error, not an empty session", ctx do
    {session_id, cwd} = closed_session(ctx, "Corrupt")
    {:ok, path} = Storage.journal_path(session_id, home: ctx.home, cwd: cwd)
    File.rm!(path)
    File.write!(Storage.compressed_path(path), "not zstd")

    assert {:error, {:decompress_failed, _path, _reason}} =
             Tackle.inspect_session(session_id, home: ctx.home, cwd: cwd)

    assert {:error, {:decompress_failed, _path, _reason}} = Compression.restore(path)
    assert File.regular?(Storage.compressed_path(path))
  end

  test "compresses idle recovery copies and sweeps stale temporary files", ctx do
    {session_id, cwd} = closed_session(ctx, "Recovered")
    location = [home: ctx.home, cwd: cwd]
    {:ok, path} = Storage.journal_path(session_id, location)
    {:ok, copy} = Storage.preserve_for_recovery(session_id, path, location)
    age(copy)

    stale = Path.join(Path.dirname(path), "session.dlog.read-1")
    File.write!(stale, "left by a crashed reader")
    age(stale)

    assert {:ok, %{compressed: 1}} = compress(ctx)
    refute File.exists?(copy)
    assert File.regular?(copy <> ".zst")
    refute File.exists?(stale)
    assert File.regular?(path)
  end

  test "a truncated compressed journal is an error and is kept", ctx do
    {session_id, cwd} = closed_session(ctx, "Truncated")
    location = [home: ctx.home, cwd: cwd]
    {:ok, path} = Storage.journal_path(session_id, location)
    age(path)
    assert {:ok, %{compressed: 1}} = compress(ctx)

    zst = Storage.compressed_path(path)
    full = File.read!(zst)
    File.write!(zst, binary_part(full, 0, byte_size(full) - 64))

    assert {:error, {:decompress_failed, _path, _reason}} =
             Tackle.inspect_session(session_id, location)

    assert {:error, {:decompress_failed, _path, _reason}} = Compression.restore(path)
    refute File.exists?(path)
    assert File.regular?(zst)
  end

  test "the catalog indexes a compressed journal from its sidecar alone", ctx do
    {session_id, cwd} = closed_session(ctx, "Indexed")
    {:ok, path} = Storage.journal_path(session_id, home: ctx.home, cwd: cwd)
    age(path)
    assert {:ok, %{compressed: 1}} = compress(ctx)

    # An unreadable journal can only be listed from the sidecar.
    File.write!(Storage.compressed_path(path), "not zstd")
    Catalog.forget(session_id)
    Catalog.rebuild(home: ctx.home)
    assert {:ok, %{title: "Indexed"}} = Catalog.get(session_id)
  end

  test "skips a journal whose writer lock is held", ctx do
    {session_id, cwd} = closed_session(ctx, "Locked")
    location = [home: ctx.home, cwd: cwd]
    {:ok, path} = Storage.journal_path(session_id, location)
    {:ok, dir} = Storage.session_dir(session_id, location)
    age(path)
    {:ok, lock} = Lock.acquire(dir)

    try do
      assert {:ok, %{compressed: 0, skipped: 1}} = compress(ctx)
      assert File.regular?(path)
      refute File.exists?(Storage.compressed_path(path))
    after
      Storage.release_lock(lock)
    end

    assert {:ok, %{compressed: 1}} = compress(ctx)
  end

  test "keeps temporary files that may still be in use", ctx do
    {session_id, cwd} = closed_session(ctx, "Temp")
    {:ok, dir} = Storage.session_dir(session_id, home: ctx.home, cwd: cwd)
    fresh = Path.join(dir, "session.dlog.read-7")
    File.write!(fresh, "a reader is replaying this")

    assert {:ok, _report} = compress(ctx)
    assert File.regular?(fresh)
  end

  test "deleting a session waits out a brief lock from this process", ctx do
    {session_id, cwd} = closed_session(ctx, "Deleted")
    location = [home: ctx.home, cwd: cwd]
    {:ok, dir} = Storage.session_dir(session_id, location)
    test_pid = self()

    holder =
      spawn(fn ->
        {:ok, lock} = Lock.acquire(dir)
        send(test_pid, :locked)

        receive do
          :release -> Storage.release_lock(lock)
        end
      end)

    assert_receive :locked
    Process.send_after(holder, :release, 200)
    assert :ok = Tackle.delete_session(session_id, location)
    refute File.exists?(dir)

    # Background writes never recreate a directory that moved away.
    path = Path.join(dir, "summary.etf")
    assert {:error, _reason} = Storage.atomic_write(path, "x", create_dir: false)
    refute File.exists?(dir)
  end

  defp compress(ctx), do: Compression.compress_idle(home: ctx.home, min_interval: 0)

  defp age(path), do: File.touch!(path, System.os_time(:second) - @week_ago)

  defp closed_session(ctx, title) do
    {session_id, cwd, scope} = live_session(ctx, title)
    stop_scope(scope.scope_ref)
    {session_id, cwd}
  end

  defp live_session(ctx, title \\ "Live") do
    cwd = Path.join(ctx.home, "cwd-#{System.unique_integer([:positive])}")

    scope =
      start_durable_scope(
        home: ctx.home,
        session: [cwd: cwd, title: title],
        root: [content: String.duplicate("a compressible answer ", 200)]
      )

    {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "first")
    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:ok, _state}}, 5_000
    {snapshot.session_id, cwd, scope}
  end
end
