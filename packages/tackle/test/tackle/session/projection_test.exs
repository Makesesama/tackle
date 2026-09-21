defmodule Tackle.Session.ProjectionTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Message
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
    retained = %{
      message("a1", :assistant, "reply")
      | token_usage: %Tackle.Lib.Usage{total_tokens: 90},
        provider_state: %{"provider" => "test", "opaque" => "large-continuation"}
    }

    projection =
      Projection.new(header())
      |> Projection.apply_commit(commit(1, [message_event(message("u1", :user, "old"))]))
      |> Projection.apply_commit(commit(2, [message_event(retained)]))

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
    assert [_compaction] = compacted.compactions

    canonical_retained = List.last(compacted.messages)
    model_retained = List.last(compacted.model_messages)
    assert canonical_retained["token_usage"]["total_tokens"] == 90
    assert canonical_retained["provider_state"]["opaque"] == "large-continuation"
    refute Map.has_key?(model_retained, "token_usage")
    refute Map.has_key?(model_retained, "provider_state")

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

  test "a durable tool result resolves its pending tool start" do
    projection =
      Projection.new(header())
      |> Projection.apply_commit(commit(1, [turn_event("turn-1")]))
      |> Projection.apply_commit(commit(2, [tool_start_event("call-1")]))
      |> Projection.apply_commit(commit(3, [tool_result_event("call-1")]))

    assert Projection.uncertain_tools(projection) == []
    assert projection.turns["turn-1"].pending_tools == []
  end

  test "only the matching tool start is resolved by a tool result" do
    projection =
      Projection.new(header())
      |> Projection.apply_commit(commit(1, [turn_event("turn-1")]))
      |> Projection.apply_commit(
        commit(2, [tool_start_event("call-1"), tool_start_event("call-2")])
      )
      |> Projection.apply_commit(commit(3, [tool_result_event("call-1")]))

    assert [%{tool_call_id: "call-2", name: "bash", started_at: "2026-01-01T00:00:00Z"}] =
             Projection.uncertain_tools(projection)
  end

  test "a resolved tool start stays resolved once the turn settles" do
    projection =
      Projection.new(header())
      |> Projection.apply_commit(commit(1, [turn_event("turn-1")]))
      |> Projection.apply_commit(commit(2, [tool_start_event("call-1")]))
      |> Projection.apply_commit(commit(3, [tool_result_event("call-1")]))
      |> Projection.apply_commit(commit(4, [turn_settled_event("turn-1")]))

    assert Projection.uncertain_tools(projection) == []
  end

  test "an unresolved tool start stays uncertain after the turn settles" do
    projection =
      Projection.new(header())
      |> Projection.apply_commit(commit(1, [turn_event("turn-1")]))
      |> Projection.apply_commit(commit(2, [tool_start_event("call-1")]))
      |> Projection.apply_commit(commit(3, [turn_settled_event("turn-1")]))

    assert [%{tool_call_id: "call-1"}] = Projection.uncertain_tools(projection)
  end

  defp turn_event(turn_id) do
    Log.event("turn.started", %{
      "turn_id" => turn_id,
      "operation" => "run",
      "input" => "prompt",
      "started_at" => "2026-01-01T00:00:00Z"
    })
  end

  defp turn_settled_event(turn_id) do
    Log.event("turn.completed", %{
      "turn_id" => turn_id,
      "status" => "completed",
      "ended_at" => "2026-01-01T00:00:04Z"
    })
  end

  defp tool_start_event(tool_call_id) do
    Log.event("tool.execution_started", %{
      "tool_call_id" => tool_call_id,
      "name" => "bash",
      "arguments" => %{},
      "started_at" => "2026-01-01T00:00:00Z"
    })
  end

  defp tool_result_event(tool_call_id) do
    message_event(Message.tool_result(tool_call_id, "bash", "output"))
  end
end
