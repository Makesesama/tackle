defmodule Tackle.Session.Committer do
  @moduledoc """
  Commits compactions and tree navigations to a durable session's journal.

  Implements `Tackle.Lib.Committer`: the library commits each compaction
  record and each tree navigation here before it installs the change in
  memory. The committer resolves the live journal by session id and commits
  and syncs before it returns:

    * a `Tackle.Lib.Compaction.Record` becomes a `context.compacted` event
      (`Tackle.Session.Codec.encode_compaction/1`). It never rewrites the
      append-only transcript, so the canonical journal stays complete while
      the model surface changes;
    * a `Tackle.Lib.Tree.Change` becomes a `tree.navigated` event. A
      navigation is committed and synced even when the user exits without
      another prompt, so resume restores the selected position, including the
      position before the first message.

  `Tackle.Session.Durable` installs the committer only in durable sessions, so
  a missing journal is a hard durability failure rather than an in-memory
  no-op.
  """

  @behaviour Tackle.Lib.Committer

  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.Tree.Change
  alias Tackle.Session.Codec
  alias Tackle.Session.Journal

  @impl true
  def commit(%Record{} = record, context) do
    with {:ok, journal} <- journal(context),
         {:ok, data} <- Codec.encode_compaction(record) do
      Journal.context_compacted(journal, data)
    end
  end

  def commit(%Change{} = change, context) do
    with {:ok, journal} <- journal(context) do
      Journal.tree_navigated(journal, change)
    end
  end

  defp journal(%{session_id: session_id}) when is_binary(session_id),
    do: Journal.whereis(session_id)

  defp journal(_context), do: {:error, :missing_session_id}
end
