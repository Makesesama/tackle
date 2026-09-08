defmodule Tackle.Lib.ContextUsageTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Message
  alias Tackle.Lib.ModelInfo
  alias Tackle.Lib.State
  alias Tackle.Lib.Usage

  defmodule ExampleTool do
    use Tackle.Lib.Tool

    tool_name("example")
    description("A deliberately descriptive tool definition")

    input do
      field(:query, :string, required: true, description: "Query text")
    end

    def run(%{"query" => query}, _context), do: {:ok, query}
  end

  test "returns nil when the selected model has no context metadata" do
    assert ContextUsage.estimate(State.new()) == nil
  end

  test "uses the latest valid checkpoint and estimates only trailing messages" do
    state =
      state_with_window(1_000)
      |> State.add_message(Message.user("ignored before checkpoint"))
      |> State.add_message(
        Message.assistant(content: "answer", token_usage: %Usage{total_tokens: 100})
      )
      |> State.add_message(Message.user("12345678"))
      |> State.add_message(Message.tool_result("call", "tool", "1234"))

    assert %ContextUsage{} = context = ContextUsage.estimate(state)
    assert context.tokens == 103
    assert context.usage_tokens == 100
    assert context.trailing_tokens == 3
    assert context.estimated?
    assert context.remaining_tokens == 897
    assert_in_delta context.percent, 10.3, 0.000_001
  end

  test "ignores all-zero usage and clearly marks a full-context estimate" do
    state =
      state_with_window(1_000, system_prompt: "1234")
      |> State.add_message(
        Message.assistant(content: "12345678", token_usage: %Usage{total_tokens: 0})
      )

    assert %ContextUsage{usage_tokens: 0, estimated?: true} =
             context =
             ContextUsage.estimate(state)

    assert context.tokens >= 3
    assert context.trailing_tokens == context.tokens
  end

  test "includes disjoint cache buckets exactly once when total is absent" do
    info = model_info(100)

    usage = %Usage{
      input_tokens: 10,
      output_tokens: 5,
      cache_read_tokens: 20,
      cache_write_tokens: 2
    }

    assert %ContextUsage{tokens: 37, usage_tokens: 37, trailing_tokens: 0, estimated?: false} =
             ContextUsage.from_usage(usage, info)
  end

  test "allows pressure above one hundred percent and clamps remaining tokens" do
    context = ContextUsage.from_usage(%Usage{total_tokens: 120}, model_info(100))

    assert context.tokens == 120
    assert context.percent == 120.0
    assert context.remaining_tokens == 0
  end

  test "uses newly selected model limits without discarding conversation" do
    state =
      state_with_window(100)
      |> State.add_message(Message.assistant(content: "answer", token_usage: %{total_tokens: 50}))

    reconfigured = %{state | llm: selection(model_info(200))}

    assert ContextUsage.estimate(state).percent == 50.0
    assert ContextUsage.estimate(reconfigured).percent == 25.0
  end

  test "estimates provider-neutral tool definitions before the first checkpoint" do
    without_tools = state_with_window(10_000) |> ContextUsage.estimate()
    with_tools = state_with_window(10_000, tools: [ExampleTool]) |> ContextUsage.estimate()

    assert with_tools.tokens > without_tools.tokens
    assert with_tools.estimated?
  end

  defp state_with_window(window, opts \\ []) do
    opts
    |> Keyword.put(:llm, selection(model_info(window)))
    |> State.new()
  end

  defp selection(info) do
    %Selection{
      adapter: __MODULE__,
      adapter_id: "test",
      model: info.model,
      ref: "test/#{info.model}",
      model_info: info
    }
  end

  defp model_info(window) do
    %ModelInfo{model: "model", context_window: window, max_output_tokens: nil, pricing: nil}
  end
end
