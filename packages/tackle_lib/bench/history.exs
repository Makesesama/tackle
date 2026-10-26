Code.require_file("../../../bench/support.exs", __DIR__)

defmodule Tackle.Lib.Bench.History do
  alias Tackle.Lib.{ContextUsage, Message, Messages, ModelInfo, State, Tree, Usage}
  alias Tackle.Lib.Compaction.{Checkpoint, Record}

  def fixture(count) do
    messages =
      for index <- 1..count do
        %Message{
          id: "message-#{index}",
          role: if(rem(index, 2) == 1, do: :user, else: :assistant),
          content: String.duplicate("synthetic context ", 16),
          timestamp: ~U[2026-01-01 00:00:00Z]
        }
      end

    checkpoint_messages =
      List.update_at(messages, count - 3, &%{&1 | token_usage: %Usage{total_tokens: 1_000}})

    plain = state(messages)

    %{
      plain: plain,
      # A compaction keeping the last 10 messages models the append/read cost
      # after compaction; this fixture does not benchmark the compaction
      # transaction itself.
      compacted: compacted(plain, messages),
      checkpoint: state(checkpoint_messages),
      next: %Message{id: "next", role: :user, content: "next question"}
    }
  end

  defp state(messages) do
    tree =
      Enum.reduce(messages, Tree.new(), fn message, tree ->
        {:ok, tree, _entry} = Tree.append_message(tree, message)
        tree
      end)

    State.new(session_id: "bench", retry: false, tree: tree)
  end

  defp compacted(state, messages) do
    {shadowed, [first_retained | _]} = Enum.split(messages, -10)

    record = %Record{
      compaction_id: "compaction",
      trigger: :manual,
      summary_message: Checkpoint.message("compaction", "synthetic summary"),
      shadowed_message_ids: Enum.map(shadowed, & &1.id),
      first_retained_message_id: first_retained.id,
      tokens_before: 0,
      estimated_tokens_after: 0,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    {:ok, tree, _entry} = Tree.append_compaction(state.tree, record)
    State.put_tree(state, tree)
  end

  def append(fixture, mode), do: State.add_message(fixture[mode], fixture.next)

  def estimate(fixture, mode) do
    ContextUsage.estimate(fixture[mode], %ModelInfo{model: "bench", context_window: 128_000})
  end

  def project(fixture), do: Messages.to_provider(State.model_messages(fixture.plain))
end

alias Tackle.Lib.Bench.History

inputs = Map.new([10, 100, 1_000, 10_000], &{"#{&1} messages", History.fixture(&1)})

# Correctness checks are outside measured functions.
Enum.each(inputs, fn {_name, fixture} ->
  Enum.each([:plain, :compacted], fn mode ->
    updated = History.append(fixture, mode)
    true = List.last(updated.messages) == fixture.next
    true = length(updated.messages) == length(fixture.plain.messages) + 1
  end)

  %{usage_tokens: 1_000} = History.estimate(fixture, :checkpoint)
  %{usage_tokens: 0} = History.estimate(fixture, :plain)
end)

Tackle.Bench.run(
  %{
    "append" => &History.append(&1, :plain),
    "append / compacted" => &History.append(&1, :compacted),
    "context / no checkpoint" => &History.estimate(&1, :plain),
    "context / recent checkpoint" => &History.estimate(&1, :checkpoint),
    "provider projection" => &History.project/1
  },
  inputs: inputs
)
