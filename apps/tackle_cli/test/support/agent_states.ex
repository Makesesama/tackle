defmodule Tackle.CLI.Test.AgentStates do
  @moduledoc false

  # Builds agent states the way the library does, through their tree, so a
  # test never sets the cached `messages`/`model_messages` by hand.

  alias Tackle.Lib.Compaction.{Checkpoint, Record}
  alias Tackle.Lib.{State, Tree}

  @doc "Appends `messages` to `state` (a new state by default)."
  def with_messages(state \\ State.new(), messages),
    do: Enum.reduce(messages, state, &State.add_message(&2, &1))

  @doc "Replaces the conversation of `state` with a single branch of `messages`."
  def replace_messages(%State{} = state, messages),
    do: state |> State.put_tree(Tree.new()) |> with_messages(messages)

  @doc """
  Commits a compaction that shadows the whole current model context, the
  way a compaction with nothing retained does, and returns the state and
  its record.
  """
  def compact(%State{} = state, compaction_id, summary \\ "Earlier work") do
    record = %Record{
      compaction_id: compaction_id,
      trigger: :manual,
      summary_message: Checkpoint.message(compaction_id, summary),
      shadowed_message_ids: Enum.map(state.model_messages, & &1.id),
      tokens_before: 1_200,
      estimated_tokens_after: 300,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    {:ok, tree, entry} = Tree.append_compaction(state.tree, record)
    {State.put_tree(state, tree), entry.compaction}
  end
end
