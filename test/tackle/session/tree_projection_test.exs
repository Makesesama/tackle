defmodule Tackle.Session.TreeProjectionTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Tree
  alias Tackle.Session.Codec
  alias Tackle.Session.Compaction
  alias Tackle.Session.Log
  alias Tackle.Session.Projection
  alias Tackle.Session.ProjectionError

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

  defp message_event(message, opts) do
    {:ok, data} = Codec.encode_message(message)
    event_data = %{"message" => data}

    event_data =
      if Keyword.has_key?(opts, :parent_id),
        do: Map.put(event_data, "parent_id", opts[:parent_id]),
        else: event_data

    Log.event("message.appended", event_data)
  end

  defp message(id, role, content) do
    %Tackle.Lib.Message{
      id: id,
      role: role,
      content: content,
      timestamp: ~U[2026-01-01 00:00:00Z]
    }
  end

  test "tree metadata registers the new event types" do
    assert Log.known_event?("tree.enabled")
    assert Log.known_event?("tree.navigated")
  end

  test "parent-linked messages form branches and the active model surface follows the position" do
    projection = Projection.new(header(), tree: true)

    projection =
      projection
      |> Projection.apply_commit(
        commit(1, [message_event(message("u1", :user, "root"), parent_id: nil)])
      )
      |> Projection.apply_commit(
        commit(2, [message_event(message("a1", :assistant, "answer A"), parent_id: "u1")])
      )
      |> Projection.apply_commit(
        commit(3, [message_event(message("u2", :user, "branch B"), parent_id: nil)])
      )
      |> Projection.apply_commit(
        commit(4, [message_event(message("a2", :assistant, "answer B"), parent_id: "u2")])
      )

    assert projection.tree_enabled?
    assert Enum.map(projection.messages, & &1["id"]) == ["u1", "a1", "u2", "a2"]
    assert Enum.map(projection.model_messages, & &1["id"]) == ["u2", "a2"]

    summary = Projection.tree_summary(projection)
    assert summary.enabled?
    assert summary.active_id == "a2"
    assert Enum.map(summary.entries, & &1.id) == ["u1", "a1", "u2", "a2"]
    assert Enum.map(summary.entries, & &1.parent_id) == [nil, "u1", nil, "u2"]

    projection =
      Projection.apply_commit(
        projection,
        commit(5, [
          Log.event("tree.navigated", %{
            "from_id" => "a2",
            "to_id" => "a1",
            "selected_id" => "a1",
            "mode" => "move",
            "revision" => 5,
            "navigated_at" => "2026-01-01T00:00:05Z"
          })
        ])
      )

    assert Tree.active_id(projection.tree) == "a1"
    assert Enum.map(projection.model_messages, & &1["id"]) == ["u1", "a1"]
  end

  test "an unknown parent is rejected rather than repaired" do
    projection = Projection.new(header(), tree: true)

    assert_raise ProjectionError, fn ->
      Projection.apply_commit(
        projection,
        commit(1, [message_event(message("a1", :assistant, "orphan"), parent_id: "missing")])
      )
    end
  end

  test "context.compacted round-trips through the durable record decoder" do
    {:ok, summary} = Codec.encode_message(message("ckpt-1", :user, "checkpoint body"))

    data = %{
      "compaction_id" => "ckpt-1",
      "trigger" => "pressure",
      "summary_message" => summary,
      "shadowed_message_ids" => ["u1"],
      "first_retained_message_id" => "a1",
      "previous_compaction_id" => nil,
      "tokens_before" => 100,
      "estimated_tokens_after" => 20,
      "summary_usage" => nil,
      "summary_model" => "test/model",
      "created_at" => "2026-01-01T00:00:03Z",
      "details" => %{"pass" => 1}
    }

    assert {:ok, record} = Compaction.decode(data)
    assert record.compaction_id == "ckpt-1"
    assert record.trigger == :pressure
    assert record.summary_message.id == "ckpt-1"
    assert record.shadowed_message_ids == ["u1"]
    assert record.first_retained_message_id == "a1"
  end

  test "a compaction attaches to the active branch only" do
    projection = Projection.new(header(), tree: true)

    projection =
      projection
      |> Projection.apply_commit(
        commit(1, [message_event(message("u1", :user, "old"), parent_id: nil)])
      )
      |> Projection.apply_commit(
        commit(2, [message_event(message("a1", :assistant, "reply"), parent_id: "u1")])
      )

    {:ok, summary} = Codec.encode_message(message("ckpt-1", :user, "checkpoint"))

    projection =
      Projection.apply_commit(
        projection,
        commit(3, [
          Log.event("context.compacted", %{
            "compaction_id" => "ckpt-1",
            "trigger" => "manual",
            "summary_message" => summary,
            "shadowed_message_ids" => ["u1"],
            "first_retained_message_id" => "a1",
            "parent_id" => "a1",
            "tokens_before" => 100,
            "estimated_tokens_after" => 20,
            "created_at" => "2026-01-01T00:00:03Z"
          })
        ])
      )

    assert Enum.map(projection.model_messages, & &1["id"]) == ["ckpt-1", "a1"]
    assert Enum.map(projection.messages, & &1["id"]) == ["u1", "a1"]
    assert Tree.active_id(projection.tree) == "ckpt-1"
    assert Tree.last_compaction_id(projection.tree) == "ckpt-1"
  end
end
