Code.require_file("../../../bench/support.exs", __DIR__)

defmodule Tackle.Lib.Bench.Context do
  alias Tackle.Lib.{ContextUsage, Message, ModelInfo, State, Tree, Usage}

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

    checkpoint =
      List.update_at(messages, count - 3, &%{&1 | token_usage: %Usage{total_tokens: 1_000}})

    %{plain: state(messages), checkpoint: state(checkpoint)}
  end

  defp state(messages) do
    tree =
      Enum.reduce(messages, Tree.new(), fn message, tree ->
        {:ok, tree, _entry} = Tree.append_message(tree, message)
        tree
      end)

    State.new(session_id: "bench", retry: false, tree: tree)
  end

  def estimate(fixture, mode) do
    ContextUsage.estimate(fixture[mode], %ModelInfo{model: "bench", context_window: 128_000})
  end
end

alias Tackle.Lib.Bench.Context

inputs = Map.new([1_000, 10_000], &{"#{&1} messages", Context.fixture(&1)})

Enum.each(inputs, fn {_name, fixture} ->
  %{usage_tokens: 1_000} = Context.estimate(fixture, :checkpoint)
  %{usage_tokens: 0} = Context.estimate(fixture, :plain)
end)

Tackle.Bench.run(
  %{
    "context / no checkpoint" => &Context.estimate(&1, :plain),
    "context / recent checkpoint" => &Context.estimate(&1, :checkpoint)
  },
  inputs: inputs
)
