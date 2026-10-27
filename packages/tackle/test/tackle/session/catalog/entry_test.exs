defmodule Tackle.Session.Catalog.EntryTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Message
  alias Tackle.Session.Catalog.Entry
  alias Tackle.Session.Codec
  alias Tackle.Session.Log
  alias Tackle.Session.Projection
  alias Tackle.Test.LegacyJournals

  @session_id "session-1"

  test "describes a projection, building search text only when asked" do
    projection = projection()

    assert %Entry{
             session_id: @session_id,
             title: "Listing",
             cwd: "/work",
             created_at: "2026-01-01T00:00:00Z",
             updated_at: "2026-01-01T00:00:03Z",
             status: :interrupted,
             model: "fake/model",
             tags: ["notes"],
             message_count: 1,
             preview: "list the files",
             last_indexed_seq: 3,
             parent_session_id: "parent",
             archived: false,
             stale: false,
             search_text: nil,
             journal_path: nil
           } = entry = Entry.from_projection(projection)

    assert is_integer(entry.context_tokens)

    assert %Entry{
             status: :active,
             archived: true,
             journal_path: "/sessions/session.dlog",
             search_text: search_text
           } =
             Entry.from_projection(projection,
               status: :active,
               archived: true,
               journal_path: "/sessions/session.dlog",
               search_text: true
             )

    assert search_text == Projection.search_text(projection)
  end

  test "a sidecar summary round-trips everything but the location and staleness" do
    entry = %{
      Entry.from_projection(projection(), search_text: true, journal_path: "/x/session.dlog")
      | archived: true,
        stale: true
    }

    summary = Entry.to_sidecar(entry)

    assert summary["status"] == "interrupted"
    assert Enum.all?(Map.keys(summary), &is_binary/1)
    refute Enum.any?(["archived", "stale", "journal_path"], &Map.has_key?(summary, &1))
    assert :ok = Codec.validate(summary)

    assert Entry.from_sidecar(summary) == %{
             entry
             | archived: false,
               stale: false,
               journal_path: nil
           }
  end

  test "reads the summary of a sidecar an earlier version wrote" do
    payload = :erlang.binary_to_term(LegacyJournals.sidecar("old", "Old title", 7))

    assert Entry.from_sidecar(payload["summary"]) == %Entry{
             session_id: "old",
             title: "Old title",
             cwd: nil,
             created_at: payload["summary"]["created_at"],
             updated_at: payload["summary"]["updated_at"],
             status: :clean,
             model: payload["summary"]["model"],
             tags: [],
             message_count: 2,
             preview: "before closing",
             last_indexed_seq: 7,
             parent_session_id: nil,
             context_tokens: nil,
             search_text: "Old title\nbefore closing"
           }

    # Summaries also carried the projection's model message and compaction
    # counts, and could miss fields entirely.
    assert %Entry{session_id: "bare", tags: [], message_count: 0, last_indexed_seq: 0} =
             Entry.from_sidecar(%{
               "session_id" => "bare",
               "model_message_count" => 3,
               "compaction_count" => 1
             })
  end

  test "names statuses" do
    assert {:ok, :active} = Entry.status_named("active")
    assert {:ok, :clean} = Entry.status_named("clean")
    assert :error = Entry.status_named("closed")
  end

  defp projection do
    header =
      Log.header(
        session_id: @session_id,
        created_at: "2026-01-01T00:00:00Z",
        cwd: "/work",
        parent: %{"session_id" => "parent", "seq" => 2}
      )

    {:ok, message} =
      Codec.encode_message(%Message{
        id: "u1",
        role: :user,
        content: "list the files",
        timestamp: ~U[2026-01-01 00:00:02Z]
      })

    Projection.new(header)
    |> Projection.apply_commit(
      commit(1, [
        Log.event("session.created", %{
          "cwd" => "/work",
          "model_ref" => "fake/model",
          "title" => "Listing",
          "tags" => ["notes"]
        })
      ])
    )
    |> Projection.apply_commit(
      commit(2, [Log.event("turn.started", %{"turn_id" => "t1", "operation" => "run"})])
    )
    |> Projection.apply_commit(
      commit(3, [Log.event("message.appended", %{"message" => message})])
    )
  end

  defp commit(seq, events) do
    Log.commit(
      session_id: @session_id,
      seq: seq,
      commit_id: "commit-#{seq}",
      written_at: "2026-01-01T00:00:0#{seq}Z",
      turn_id: if(seq > 1, do: "t1"),
      events: events
    )
  end
end
