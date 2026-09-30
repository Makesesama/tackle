defmodule Tackle.Session.Persistence do
  @moduledoc """
  Internal `Tackle.Lib.Hook` that makes a durable session fail closed.

  The hook runs on the loop's semantic boundaries, not on streaming deltas:

    * `after_message/3` persists a settled user, assistant, or tool message; and
    * `before_tool_call/3` persists `tool.execution_started` before the tool is
      invoked.

  The loop emits live events before the hook completes; those events remain
  observational. The durability guarantee is that a settled message is
  committed before the loop performs the next provider or tool effect, and that
  terminal completion is not announced before the terminal commit is synced.

  The hook is provider-neutral and storage-free: it resolves the session's
  journal by session id and is a no-op for sessions without one, so the same
  hook can be installed for durable and ephemeral agents alike. Durable session
  context carries `:journal_required`, so a missing owner fails closed rather
  than being mistaken for an ephemeral session.

  For a branching session the hook reads the just-appended tree entry from the
  settled state and commits the message together with its parent link, rather
  than guessing parentage from the previous journal commit.
  """

  @behaviour Tackle.Lib.Hook

  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Tree
  alias Tackle.Session.Journal

  @impl true
  def after_message(%State{session_id: session_id} = state, %Message{} = message, context) do
    persist(session_id, context, fn journal ->
      Journal.append_message(journal, message, tree_parent(state, message.id))
    end)
  end

  @impl true
  def before_tool_call(%State{session_id: session_id}, call, context) do
    persist(session_id, context, &Journal.tool_started(&1, call))
  end

  defp persist(session_id, context, fun) do
    case Journal.whereis(session_id) do
      {:ok, journal} ->
        fun.(journal)

      {:error, :not_found} ->
        if context[:journal_required],
          do: {:error, {:journal_unavailable, :not_found}},
          else: :ok
    end
  end

  defp tree_parent(%State{tree: %Tree{} = tree}, message_id) do
    case Tree.entry(tree, message_id) do
      %{parent_id: parent_id} -> {:tree, parent_id}
      _entry -> :none
    end
  end

  defp tree_parent(_state, _message_id), do: :none
end
