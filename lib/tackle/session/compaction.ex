defmodule Tackle.Session.Compaction do
  @moduledoc """
  Durable persistence barrier for one library compaction.

  Implements `Tackle.Lib.Compaction.Committer` for the root harness. It lowers a
  `Tackle.Lib.Compaction.Record` into the `context.compacted` journal event and
  commits it synchronously before the library installs the replacement in memory.

  The event stores the synthetic checkpoint as a durable message, the shadowed
  transcript message ids for provenance, the first retained id, and auxiliary
  summarization usage. It never rewrites the append-only transcript, and the
  canonical journal therefore remains complete while the model surface changes.
  """

  @behaviour Tackle.Lib.Compaction.Committer

  alias Tackle.Lib.Compaction.Record
  alias Tackle.Session.Codec
  alias Tackle.Session.Journal

  @impl true
  def commit(%Record{} = record, context) do
    with {:ok, session_id} <- session_id(context),
         {:ok, journal} <- Journal.whereis(session_id),
         {:ok, data} <- encode(record) do
      Journal.context_compacted(journal, data)
    end
  end

  # The committer is installed only for durable sessions, so a missing journal is
  # a hard durability failure rather than an ephemeral no-op.
  defp session_id(%{session_id: session_id}) when is_binary(session_id), do: {:ok, session_id}
  defp session_id(_context), do: {:error, :missing_session_id}

  defp encode(%Record{} = record) do
    with {:ok, summary_message} <- Codec.encode_message(record.summary_message) do
      {:ok,
       %{
         "compaction_id" => record.compaction_id,
         "trigger" => Atom.to_string(record.trigger),
         "summary_message" => summary_message,
         "shadowed_message_ids" => record.shadowed_message_ids,
         "first_retained_message_id" => record.first_retained_message_id,
         "previous_compaction_id" => record.previous_compaction_id,
         "tokens_before" => record.tokens_before,
         "estimated_tokens_after" => record.estimated_tokens_after,
         "summary_usage" => Codec.encode_usage(record.summary_usage),
         "summary_model" => record.summary_model,
         "created_at" => record.created_at,
         "details" => record.details
       }}
    end
  end
end
