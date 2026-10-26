defmodule Tackle.Lib.Compaction.CheckpointTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Compaction.Checkpoint
  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.Message
  alias Tackle.Lib.Usage

  test "a checkpoint message carries the framing and the summary" do
    message = Checkpoint.message("c1", "Earlier work")

    assert message.id == "c1"
    assert message.role == :user
    assert String.starts_with?(message.content, String.trim_trailing(Checkpoint.framing()))

    assert Checkpoint.summary(%{record("c1", [], nil) | summary_message: message}) ==
             "Earlier work"
  end

  test "a checkpoint without the framing is all summary" do
    foreign = %{record("c1", [], nil) | summary_message: Message.user("Plain summary\n")}
    assert Checkpoint.summary(foreign) == "Plain summary"

    no_text = %{record("c1", [], nil) | summary_message: %{Message.user("x") | content: nil}}
    assert Checkpoint.summary(no_text) == nil
  end

  describe "apply_compaction/2" do
    test "replaces the shadowed prefix, an earlier checkpoint included" do
      earlier = Checkpoint.message("c0", "older")
      kept = message("a1", token_usage: %Usage{total_tokens: 5}, provider_state: %{"k" => "v"})
      messages = [earlier, message("u1"), kept, message("u2")]

      record = record("c1", ["c0", "u1"], "a1")

      assert [checkpoint, retained_a1, retained_u2] =
               Checkpoint.apply_compaction(messages, record)

      assert checkpoint == record.summary_message
      assert retained_a1.id == "a1"
      assert retained_u2.id == "u2"
      # The retained tail loses what described requests before the compaction.
      assert retained_a1.token_usage == nil
      assert retained_a1.provider_state == nil
      assert retained_a1.content == kept.content
    end

    test "keeps only the checkpoint when everything was shadowed" do
      record = record("c1", ["u1", "a1"], nil)

      assert [checkpoint] = Checkpoint.apply_compaction([message("u1"), message("a1")], record)
      assert checkpoint.id == "c1"
    end
  end

  defp message(id, fields \\ []), do: struct(%{Message.user("text #{id}") | id: id}, fields)

  defp record(id, shadowed, first_retained) do
    %Record{
      compaction_id: id,
      trigger: :manual,
      summary_message: Checkpoint.message(id, "summary"),
      shadowed_message_ids: shadowed,
      first_retained_message_id: first_retained,
      tokens_before: 100,
      estimated_tokens_after: 10,
      created_at: ~U[2026-01-01 00:00:00Z]
    }
  end
end
