defmodule Tackle.Lib.Tree.Navigator do
  @moduledoc """
  Navigation transaction for a conversation tree.

  Navigation prepares a transition against an expected revision and position,
  validates the destination, and returns the destination tree plus the
  navigation outcome. It never mutates existing entries, never runs a turn, and
  never re-executes a tool.

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

  alias Tackle.Lib.Message
  alias Tackle.Lib.Tree
  alias Tackle.Lib.Tree.Change

  @type target :: nil | String.t() | {:entry, String.t()} | {:edit, String.t()}

  @type mode :: :move | :edit

  @type outcome :: %{
          tree: Tree.t(),
          selected_id: String.t() | nil,
          destination_id: String.t() | nil,
          draft: Message.t() | nil,
          mode: mode(),
          noop?: boolean(),
          change: Change.t() | nil
        }

  @doc """
  Prepares one navigation against a tree.

  `opts` may carry `:expected_revision` for a stale-transition check, and
  `:session_id` so the returned `Tackle.Lib.Tree.Change` identifies its session.
  """
  @spec navigate(Tree.t(), target(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def navigate(%Tree{} = tree, target, opts \\ []) do
    with :ok <- validate_revision(tree, Keyword.get(opts, :expected_revision)),
         {:ok, selected_id, destination_id, mode} <- resolve_target(tree, target),
         :ok <- validate_resumable(tree, destination_id) do
      draft = draft_message(tree, selected_id, mode)

      if destination_id == tree.active_id do
        {:ok,
         %{
           tree: tree,
           selected_id: selected_id,
           destination_id: destination_id,
           draft: draft,
           mode: mode,
           noop?: true,
           change: nil
         }}
      else
        change = %Change{
          session_id: Keyword.get(opts, :session_id),
          from_id: tree.active_id,
          to_id: destination_id,
          selected_id: selected_id,
          mode: mode,
          revision: tree.revision + 1
        }

        case Tree.move(tree, destination_id) do
          {:ok, tree} ->
            {:ok,
             %{
               tree: tree,
               selected_id: selected_id,
               destination_id: destination_id,
               draft: draft,
               mode: mode,
               noop?: false,
               change: change
             }}

          {:error, _reason} = error ->
            error
        end
      end
    end
  end

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
