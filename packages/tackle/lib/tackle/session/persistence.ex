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
  journal by session id. `Tackle.Session.Durable` installs it only in durable
  sessions, so a journal that cannot be found fails the turn rather than
  being mistaken for a session without one.

  The hook appends a message through `Tackle.Session.Durable.append_message/3`,
  which commits it with the parent link of its tree entry in the settled
  state rather than guessing parentage from the previous journal commit; a
  journal without branching leaves the implied link out.

  A message the journal does not append fails the turn with
  `{:message_not_journaled, reason}`, the reason the turn's state records.
  The loop already holds that message, so the session rebuilds its state from
  the journal once the turn is settled (see `Tackle.Session.Durable.reopen/4`)
  instead of continuing with a transcript the journal does not have.

  Once a user message is appended, the hook tells the session that owns the
  agent (`Tackle.Runtime.session_pid/1` for the context's `:runtime`
  reference) with `{:tackle_message_appended, session_id, message}`, so the
  session can title itself from it.
  """

  @behaviour Tackle.Lib.Hook

  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef
  alias Tackle.Session.Durable
  alias Tackle.Session.Journal

  @impl true
  def after_message(%State{session_id: session_id} = state, %Message{} = message, context) do
    case persist(session_id, &Durable.append_message(&1, state, message)) do
      :ok -> notify_appended(message, session_id, context)
      {:error, reason} -> {:error, {:message_not_journaled, reason}}
    end
  end

  @impl true
  def before_tool_call(%State{session_id: session_id}, call, _context) do
    persist(session_id, &Journal.tool_started(&1, call, sync: false))
  end

  defp persist(session_id, fun) do
    case Journal.whereis(session_id) do
      {:ok, journal} -> fun.(journal)
      {:error, :not_found} -> {:error, {:journal_unavailable, :not_found}}
    end
  end

  # Live message_end precedes the hook. Title generation must wait until this
  # user message is appended, not race it; the session decides whether the
  # user wrote it.
  defp notify_appended(%Message{role: :user} = message, session_id, context) do
    with %AgentRef{} = agent_ref <- AgentRef.from_context(context),
         {:ok, session} <- Runtime.session_pid(agent_ref) do
      send(session, {:tackle_message_appended, session_id, message})
    end

    :ok
  end

  defp notify_appended(_message, _session_id, _context), do: :ok
end
