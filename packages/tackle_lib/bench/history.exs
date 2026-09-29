Code.require_file("../../../bench/support.exs", __DIR__)

defmodule Tackle.Lib.Bench.History do
  alias Tackle.Lib.{ContextUsage, Message, Messages, ModelInfo, State, Tree, Usage}

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

    state = %{State.new(session_id: "bench", retry: false) | messages: messages}

    tree =
      Enum.reduce(messages, Tree.new(), fn message, tree ->
        {:ok, tree, _entry} = Tree.append_message(tree, message)
        tree
      end)

    checkpoint_messages =
      List.update_at(messages, count - 3, &%{&1 | token_usage: %Usage{total_tokens: 1_000}})

    %{
      linear: state,
      tree: %{state | tree: tree, model_messages: messages},
      # A short synthetic projection models the append/read cost after compaction;
      # this fixture does not benchmark the compaction transaction itself.
      compacted: %{state | model_messages: Enum.take(messages, -10)},
      checkpoint: %{state | messages: checkpoint_messages},
      next: %Message{id: "next", role: :user, content: "next question"}
    }
  end

  def append(fixture, mode), do: State.add_message(fixture[mode], fixture.next)

  def estimate(fixture, mode) do
    ContextUsage.estimate(fixture[mode], %ModelInfo{model: "bench", context_window: 128_000})
  end

  def project(fixture), do: Messages.to_provider(State.model_messages(fixture.linear))
end

alias Tackle.Lib.Bench.History

inputs = Map.new([10, 100, 1_000, 10_000], &{"#{&1} messages", History.fixture(&1)})

# Correctness checks are outside measured functions.
Enum.each(inputs, fn {_name, fixture} ->
  Enum.each([:linear, :tree, :compacted], fn mode ->
    updated = History.append(fixture, mode)
    true = List.last(updated.messages) == fixture.next
    true = length(updated.messages) == length(fixture.linear.messages) + 1
  end)

  %{usage_tokens: 1_000} = History.estimate(fixture, :checkpoint)
  %{usage_tokens: 0} = History.estimate(fixture, :linear)
end)

Tackle.Bench.run(
  %{
    "append / linear" => &History.append(&1, :linear),
    "append / tree" => &History.append(&1, :tree),
    "append / compacted" => &History.append(&1, :compacted),
    "context / no checkpoint" => &History.estimate(&1, :linear),
    "context / recent checkpoint" => &History.estimate(&1, :checkpoint),
    "provider projection" => &History.project/1
  },
  inputs: inputs
)
