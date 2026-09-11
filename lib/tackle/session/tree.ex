defmodule Tackle.Session.Tree do
  @moduledoc """
  Durable persistence barrier for one conversation-tree navigation.

  Implements `Tackle.Lib.Tree.Committer` for the root harness. It resolves the
  live journal by session id and commits a `tree.navigated` event synchronously
  before the library installs the new active position. A navigation is committed
  and synced even when the user exits without another prompt, so resume restores
  the selected position, including the position before the first message.

  The committer is installed only for durable sessions, so a missing journal is a
  hard durability failure rather than an in-memory no-op.
  """

  @behaviour Tackle.Lib.Tree.Committer

  alias Tackle.Lib.Tree.Change
  alias Tackle.Session.Journal

  @impl true
  def commit_navigation(%Change{} = change, context) do
    with {:ok, session_id} <- session_id(context),
         {:ok, journal} <- Journal.whereis(session_id) do
      Journal.tree_navigated(journal, change)
    end
  end

  defp session_id(%{session_id: session_id}) when is_binary(session_id), do: {:ok, session_id}
  defp session_id(_context), do: {:error, :missing_session_id}
end
