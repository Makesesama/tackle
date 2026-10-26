defmodule Tackle.Lib.Tree.Navigator do
  @moduledoc """
  Navigation transaction for a conversation tree.

  Navigation prepares a transition against an expected revision and position,
  validates the destination, commits the `Tackle.Lib.Tree.Change` through the
  state's `Tackle.Lib.Committer`, and only then installs the new active
  position. It never mutates existing entries, never runs a turn, and never
  re-executes a tool. `Tackle.Lib.navigate/3` delegates here.

  ## Targets

    * `nil` — return to the position before the first message (an empty active
      conversation that keeps all history);
    * an entry id — move to that entry;
    * `{:entry, id}` — explicit move, equivalent to passing the id;
    * `{:edit, id}` — select a user message for editing: the effective
      destination is its parent, and the selected message is exposed as a draft.

  ## Safety

  The destination must be a structurally complete tool boundary (see
  `Tackle.Lib.Tree.resumable?/2`). An unsafe destination is inspectable but
  rejected here, so selecting it cannot replay a tool, fabricate a result, or
  send a malformed provider history.

  Selecting the current position is a no-op: the tree, its revision, and any
  durable state are left untouched, though `:edit` still exposes the draft.
  """

  alias Tackle.Lib.Committer
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Tree
  alias Tackle.Lib.Tree.Change
  alias Tackle.Lib.Tree.Navigator.Outcome

  @type target :: nil | String.t() | {:entry, String.t()} | {:edit, String.t()}

  @doc """
  Navigates the active position of a state's tree.

  The only option is `:expected_revision`, which rejects a transition prepared
  against another revision of the tree. The change is committed through the
  state's own committer. Expected failures include `:turn_in_progress`,
  `{:unknown_entry, id}`, `{:unsafe_continuation, id}`, `{:stale_transition,
  expected, actual}`, and `{:durable_commit_failed, reason}`. A failed validation or commit leaves the state unchanged.
  """
  @spec navigate(State.t(), target(), keyword()) ::
          {:ok, State.t(), Outcome.t()} | {:error, term()}
  def navigate(%State{} = state, target, opts \\ []) do
    opts = Keyword.validate!(opts, [:expected_revision])

    with {:ok, tree} <- navigable_tree(state),
         {:ok, moved, outcome} <- prepare(tree, target, opts),
         :ok <- commit(state, outcome) do
      {:ok, install(state, moved), outcome}
    end
  end

  @doc """
  Prepares one navigation against a tree, without committing it.

  Returns the tree with its new active position and the outcome. `opts` may
  carry `:expected_revision` for a stale-transition check.
  """
  @spec prepare(Tree.t(), target(), keyword()) :: {:ok, Tree.t(), Outcome.t()} | {:error, term()}
  def prepare(%Tree{} = tree, target, opts \\ []) do
    with :ok <- validate_revision(tree, Keyword.get(opts, :expected_revision)),
         {:ok, selected_id, destination_id, mode} <- resolve_target(tree, target),
         :ok <- validate_resumable(tree, destination_id),
         {:ok, moved} <- Tree.move(tree, destination_id) do
      change = %Change{
        from_id: tree.active_id,
        to_id: destination_id,
        selected_id: selected_id,
        mode: mode,
        revision: moved.revision
      }

      outcome = %Outcome{
        change: change,
        draft: draft_message(tree, selected_id, mode),
        noop?: destination_id == tree.active_id
      }

      {:ok, moved, outcome}
    end
  end

  # The library refuses to navigate a state that is visibly mid-turn. Immutable
  # state cannot know about another process executing a copy, so the host must
  # still serialize turns, navigation, and compaction.
  defp navigable_tree(%State{status: status}) when status in [:thinking, :acting],
    do: {:error, :turn_in_progress}

  defp navigable_tree(%State{tree: tree}), do: {:ok, tree}

  defp commit(_state, %Outcome{noop?: true}), do: :ok
  defp commit(state, %Outcome{change: change}), do: Committer.commit(state, change)

  defp install(%State{} = state, %Tree{} = tree),
    do: state |> State.put_tree(tree) |> State.reset_turn()

  defp resolve_target(_tree, nil), do: {:ok, nil, nil, :move}

  defp resolve_target(%Tree{} = tree, {:entry, id}) when is_binary(id),
    do: resolve_target(tree, id)

  defp resolve_target(%Tree{} = tree, {:edit, id}) when is_binary(id) do
    case Tree.entry(tree, id) do
      %{kind: :message, message: %Message{role: :user}} = entry ->
        {:ok, id, entry.parent_id, :edit}

      nil ->
        {:error, {:unknown_entry, id}}

      %{} ->
        {:error, {:not_editable, id}}
    end
  end

  defp resolve_target(%Tree{} = tree, id) when is_binary(id) do
    case Tree.entry(tree, id) do
      nil -> {:error, {:unknown_entry, id}}
      _entry -> {:ok, id, id, :move}
    end
  end

  defp resolve_target(_tree, target), do: {:error, {:invalid_target, target}}

  defp validate_revision(_tree, nil), do: :ok

  defp validate_revision(%Tree{} = tree, expected) when is_integer(expected) do
    if Tree.revision(tree) == expected,
      do: :ok,
      else: {:error, {:stale_transition, expected, Tree.revision(tree)}}
  end

  defp validate_revision(_tree, other), do: {:error, {:invalid_expected_revision, other}}

  defp validate_resumable(tree, destination_id) do
    if Tree.resumable?(tree, destination_id),
      do: :ok,
      else: {:error, {:unsafe_continuation, destination_id}}
  end

  defp draft_message(_tree, nil, _mode), do: nil
  defp draft_message(_tree, _selected_id, :move), do: nil

  defp draft_message(%Tree{} = tree, selected_id, :edit) do
    case Tree.entry(tree, selected_id) do
      %{kind: :message, message: message} -> message
      _entry -> nil
    end
  end
end
