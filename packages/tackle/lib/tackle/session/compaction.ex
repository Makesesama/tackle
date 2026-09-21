defmodule Tackle.Session.Compaction do
  @moduledoc """
  Durable persistence barrier for one library compaction.

  Implements `Tackle.Lib.Compaction.Committer` for the root harness. It lowers a
  `Tackle.Lib.Compaction.Record` into the `context.compacted` journal event and
  commits it synchronously before the library installs the replacement in memory.

  The event stores the synthetic checkpoint as a durable message, the shadowed
  transcript message ids for provenance, the first retained id, the parent entry
  when the session branches, and auxiliary summarization usage. It never
  rewrites the append-only transcript, and the canonical journal therefore
  remains complete while the model surface changes.

  `decode/1` is the inverse fold used by replay and by the durable projection.
  """

  @behaviour Tackle.Lib.Compaction.Committer

  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.Tree
  alias Tackle.Session.Codec
  alias Tackle.Session.Journal

  @impl true
  def commit(%Record{} = record, context) do
    with {:ok, session_id} <- session_id(context),
         {:ok, journal} <- Journal.whereis(session_id),
         {:ok, data} <- encode(record, context) do
      Journal.context_compacted(journal, data)
    end
  end

  @doc """
  Rebuilds a `Tackle.Lib.Compaction.Record` from durable event data.

  Returns an explicit error for a malformed checkpoint rather than repairing it.
  """
  @spec decode(map()) :: {:ok, Record.t()} | {:error, term()}
  def decode(%{} = data) do
    with {:ok, summary_message} <- Codec.decode_message(Map.get(data, "summary_message")),
         {:ok, usage} <- Codec.decode_usage(Map.get(data, "summary_usage")) do
      {:ok,
       %Record{
         compaction_id: Map.get(data, "compaction_id"),
         trigger: decode_trigger(Map.get(data, "trigger")),
         summary_message: summary_message,
         shadowed_message_ids: Map.get(data, "shadowed_message_ids", []),
         first_retained_message_id: Map.get(data, "first_retained_message_id"),
         previous_compaction_id: Map.get(data, "previous_compaction_id"),
         tokens_before: Map.get(data, "tokens_before", 0),
         estimated_tokens_after: Map.get(data, "estimated_tokens_after", 0),
         summary_usage: usage,
         summary_model: Map.get(data, "summary_model"),
         created_at: Map.get(data, "created_at"),
         details: Map.get(data, "details", %{})
       }}
    end
  end

  def decode(other), do: {:error, {:invalid_compaction_data, other}}

  # The committer is installed only for durable sessions, so a missing journal is
  # a hard durability failure rather than an ephemeral no-op.
  defp session_id(%{session_id: session_id}) when is_binary(session_id), do: {:ok, session_id}
  defp session_id(_context), do: {:error, :missing_session_id}

  defp encode(%Record{} = record, context) do
    with {:ok, summary_message} <- Codec.encode_message(record.summary_message) do
      data = %{
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
      }

      {:ok, maybe_put_parent(data, context)}
    end
  end

  # Only a branching session records the entry the checkpoint attaches to. A
  # linear session leaves the key absent so replay keeps chaining by position.
  defp maybe_put_parent(data, %{tree: %Tree{}} = context) do
    Map.put(data, "parent_id", Map.get(context, :tree_parent_id))
  end

  defp maybe_put_parent(data, _context), do: data

  defp decode_trigger(nil), do: :manual
  defp decode_trigger(trigger) when is_atom(trigger), do: trigger

  defp decode_trigger(trigger) when is_binary(trigger) do
    case trigger do
      "pressure" -> :pressure
      "overflow" -> :overflow
      "manual" -> :manual
      _other -> :manual
    end
  end

  defp decode_trigger(_trigger), do: :manual
end
