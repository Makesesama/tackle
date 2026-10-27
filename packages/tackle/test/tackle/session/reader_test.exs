defmodule Tackle.Session.ReaderTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Session.Log
  alias Tackle.Session.Reader

  @session_id "session-1"

  test "names a session's writable log by its id" do
    assert Reader.name(@session_id) == {:tackle_session, @session_id}
  end

  test "writes a new journal file that reads back, leaving no log open" do
    path = Path.join(tmp_home(), "session.dlog")
    header = Log.header(session_id: @session_id, created_at: "2026-01-01T00:00:00Z")

    commit =
      Log.commit(
        session_id: @session_id,
        seq: 1,
        commit_id: "commit-1",
        written_at: "2026-01-01T00:00:01Z",
        events: [Log.event("session.created", %{"title" => "Written"})]
      )

    logs = :disk_log.all()

    assert :ok = Reader.write_journal(path, [header, commit])
    assert :disk_log.all() == logs

    assert {:ok, %{header: ^header, commits: [^commit], last_seq: 1}} =
             Reader.read(@session_id, path: path)
  end

  test "reports a journal file it cannot open" do
    path = Path.join([tmp_home(), "missing", "session.dlog"])

    assert {:error, {:journal_open_failed, ^path, _reason}} = Reader.write_journal(path, [])
  end
end
