defmodule Tackle.Session.ProjectionTest do
  use ExUnit.Case, async: true

  alias Tackle.Session.Codec
  alias Tackle.Session.Log
  alias Tackle.Session.Projection

  defp header do
    Log.header(session_id: "session-1", created_at: "2026-01-01T00:00:00Z")
  end

  defp commit(seq, events) do
    Log.commit(
      session_id: "session-1",
      seq: seq,
      commit_id: "commit-#{seq}",
      written_at: "2026-01-01T00:00:0#{seq}Z",
      events: events
    )
  end

  defp message_event(message) do
    {:ok, data} = Codec.encode_message(message)
    Log.event("message.appended", %{"message" => data})
  end

  defp message(id, role, content) do
    %Tackle.Lib.Message{
      id: id,
      role: role,
      content: content,
      timestamp: ~U[2026-01-01 00:00:00Z]
    }
  end

  test "message.appended extends both the transcript and the model projection" do
    projection =
      Projection.new(header())
      |> Projection.apply_commit(commit(1, [message_event(message("u1", :user, "hello"))]))
      |> Projection.apply_commit(commit(2, [message_event(message("a1", :assistant, "hi"))]))

    assert Enum.map(projection.messages, & &1["id"]) == ["u1", "a1"]
    assert Enum.map(projection.model_messages, & &1["id"]) == ["u1", "a1"]
  end

  test "context.compacted replaces the model prefix but never the transcript" do
    projection =
      Projection.new(header())
      |> Projection.apply_commit(commit(1, [message_event(message("u1", :user, "old"))]))
      |> Projection.apply_commit(commit(2, [message_event(message("a1", :assistant, "reply"))]))

    {:ok, summary} = Codec.encode_message(message("ckpt-1", :user, "checkpoint"))

    compacted =
      Projection.apply_commit(
        projection,
        commit(3, [
          Log.event("context.compacted", %{
            "compaction_id" => "ckpt-1",
            "trigger" => "manual",
            "summary_message" => summary,
            "shadowed_message_ids" => ["u1"],
            "first_retained_message_id" => "a1",
            "tokens_before" => 100,
            "estimated_tokens_after" => 20,
            "created_at" => "2026-01-01T00:00:03Z"
          })
        ])
      )

    assert Enum.map(compacted.messages, & &1["id"]) == ["u1", "a1"]
    assert Enum.map(compacted.model_messages, & &1["id"]) == ["ckpt-1", "a1"]
    assert length(compacted.compactions) == 1

    assert Projection.search_text(compacted) =~ "old"
    refute Projection.search_text(compacted) =~ "checkpoint"
  end

  test "falls back to shadowed ids when the retained id is missing" do
    projection =
      Projection.new(header())
      |> Projection.apply_commit(commit(1, [message_event(message("u1", :user, "old"))]))
      |> Projection.apply_commit(commit(2, [message_event(message("a1", :assistant, "reply"))]))

    {:ok, summary} = Codec.encode_message(message("ckpt-1", :user, "checkpoint"))

    compacted =
      Projection.apply_commit(
        projection,
        commit(3, [
          Log.event("context.compacted", %{
            "compaction_id" => "ckpt-1",
            "trigger" => "pressure",
            "summary_message" => summary,
            "shadowed_message_ids" => ["u1"],
            "first_retained_message_id" => nil,
            "tokens_before" => 100,
            "estimated_tokens_after" => 20,
            "created_at" => "2026-01-01T00:00:03Z"
          })
        ])
      )

    assert Enum.map(compacted.model_messages, & &1["id"]) == ["ckpt-1", "a1"]
  end

  test "metadata reports transcript, model, and compaction counts" do
    projection = Projection.new(header())
    metadata = Projection.metadata(projection)

    assert metadata.message_count == 0
    assert metadata.model_message_count == 0
    assert metadata.compaction_count == 0
  end
end
