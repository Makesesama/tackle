Code.require_file("../../../bench/support.exs", __DIR__)

defmodule Tackle.Lib.Bench.Context do
  alias Tackle.Lib.{ContextUsage, Message, ModelInfo, State, Usage}

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

    checkpoint =
      List.update_at(messages, count - 3, &%{&1 | token_usage: %Usage{total_tokens: 1_000}})

    %{linear: state, checkpoint: %{state | messages: checkpoint}}
  end

  def estimate(fixture, mode) do
    ContextUsage.estimate(fixture[mode], %ModelInfo{model: "bench", context_window: 128_000})
  end
end

alias Tackle.Lib.Bench.Context

inputs = Map.new([1_000, 10_000], &{"#{&1} messages", Context.fixture(&1)})

Enum.each(inputs, fn {_name, fixture} ->
  %{usage_tokens: 1_000} = Context.estimate(fixture, :checkpoint)
  %{usage_tokens: 0} = Context.estimate(fixture, :linear)
end)

Tackle.Bench.run(
  %{
    "context / no checkpoint" => &Context.estimate(&1, :linear),
    "context / recent checkpoint" => &Context.estimate(&1, :checkpoint)
  },
  inputs: inputs
)
