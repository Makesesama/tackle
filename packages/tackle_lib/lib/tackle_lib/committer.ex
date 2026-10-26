defmodule Tackle.Lib.Committer do
  @moduledoc """
  Durability seam for the changes a state makes between turns.

  `Tackle.Lib` owns the in-memory transactions but is persistence-free. Two
  of them change what a durable host has to replay, and both commit through
  the one committer a state names in `:committer`
  (`Tackle.Lib.State.new/1`):

    * a compaction commits its `Tackle.Lib.Compaction.Record` before the
      replacement model context is installed; and
    * a navigation commits its `Tackle.Lib.Tree.Change` before the new active
      position is installed.

  The library calls `c:commit/2` and installs the change only when it returns
  `:ok`. A failure leaves the state unchanged and is reported as
  `{:durable_commit_failed, reason}`: the caller must not continue with a
  state whose change was never persisted. A committer that returns anything
  else, raises, throws, or exits fails the same way.

  The context names the state's session and carries its host context:
  `%{session_id: session_id, context: context}`. A committer lowers the change
  into its own durable schema.

  A state without a committer keeps every change in memory, which is valid
  only for explicitly in-memory use.
  """

  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.State
  alias Tackle.Lib.Tree.Change

  @typedoc "A change the library commits before installing it."
  @type change :: Record.t() | Change.t()

  @typedoc "What a committer learns about the state it commits for."
  @type context :: %{session_id: String.t(), context: map()}

  @callback commit(change(), context()) :: :ok | {:error, term()}

  @doc """
  Commits `change` through the state's committer.

  Returns `:ok` without a committer, and `{:error, {:durable_commit_failed,
  reason}}` when the committer fails in any way.
  """
  @spec commit(State.t(), change()) :: :ok | {:error, {:durable_commit_failed, term()}}
  def commit(%State{committer: nil}, _change), do: :ok

  def commit(%State{committer: module} = state, change) do
    case module.commit(change, %{session_id: state.session_id, context: state.context}) do
      :ok -> :ok
      {:error, reason} -> {:error, {:durable_commit_failed, reason}}
      other -> {:error, {:durable_commit_failed, {:unexpected_commit_result, other}}}
    end
  rescue
    error -> {:error, {:durable_commit_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:durable_commit_failed, {kind, reason}}}
  end

  @doc """
  Validates a committer module: `nil`, or a loaded module exporting `commit/2`.
  """
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(nil), do: :ok

  def validate(module) when is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:invalid_committer, module, :not_loaded}}

      not function_exported?(module, :commit, 2) ->
        {:error, {:invalid_committer, module, :no_commit}}

      true ->
        :ok
    end
  end

  def validate(other), do: {:error, {:invalid_committer, other}}
end
