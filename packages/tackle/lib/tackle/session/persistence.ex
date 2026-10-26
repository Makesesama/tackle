defmodule Tackle.Session.Persistence do
  @moduledoc """
  Internal `Tackle.Lib.Hook` that makes a durable session fail closed.

  The hook runs on the loop's semantic boundaries, not on streaming deltas:

    * `after_message/3` persists a settled user, assistant, or tool message; and
    * `before_tool_call/3` persists `tool.execution_started` before the tool is
      invoked.

  Both hooks append write-behind (`sync: false`): the commit is validated,
  sequenced, and appended in order without waiting for the disk. The session's
  `:before_tool_execution` gate (`Journal.await_durable/1`) makes everything
  appended so far durable before a tool with external effects runs; read-only
  tools skip it. Turn start and terminal settlement are write-behind too.

  The loop emits live events before the hook completes; those events remain
  observational. Guarantee: tool intent is durable before an external tool
  runs. Unsynced commits reach the OS within about two seconds, so an
  application crash keeps them; power loss can lose the unsynced tail,
  including whole recent turns. Replay then sees a consistent prefix, and an
  external tool whose result was lost is reported as uncertain.

  The hook is provider-neutral and storage-free: it resolves the session's
  journal by session id and is a no-op for sessions without one, so the same
  hook can be installed for durable and ephemeral agents alike. Durable session
  context carries `:journal_required`, so a missing owner fails closed rather
  than being mistaken for an ephemeral session.

  The hook reads the just-appended tree entry from the settled state and
  commits the message together with its parent link, rather than guessing
  parentage from the previous journal commit; a journal without branching
  leaves the implied link out.
  """

  @behaviour Tackle.Lib.Hook

  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Tree
  alias Tackle.Session.Journal

  @impl true
  def after_message(%State{session_id: session_id} = state, %Message{} = message, context) do
    with :ok <-
           persist(session_id, context, fn journal ->
             Journal.append_message(journal, message, tree_parent(state, message.id), sync: false)
           end) do
      # Live message_end precedes the hook. Title generation must wait until
      # this user message is appended, not race it.
      if message.role == :user and is_pid(context[:session_owner]) do
        send(context.session_owner, {:tackle_message_appended, session_id, message})
      end

      :ok
    end
  end

  @impl true
  def before_tool_call(%State{session_id: session_id}, call, context) do
    persist(session_id, context, &Journal.tool_started(&1, call, sync: false))
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

  @doc """
  Returns the journal parent of a message just appended to `state`: the
  parent of its tree entry, or `:none` when the tree does not hold it. The
  journal decides whether to record the link (see
  `Tackle.Session.Journal.append_message/4`).
  """
  @spec tree_parent(State.t(), String.t()) :: {:tree, String.t() | nil} | :none
  def tree_parent(%State{tree: tree}, message_id) do
    case Tree.entry(tree, message_id) do
      %{parent_id: parent_id} -> {:tree, parent_id}
      nil -> :none
    end
  end
end
