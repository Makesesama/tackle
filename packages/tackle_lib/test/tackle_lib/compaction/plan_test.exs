defmodule Tackle.Lib.Compaction.PlanTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Compaction.Plan
  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Message

  defp message(role, content, opts \\ [])

  defp message(:user, content, _opts), do: Message.user(content)
  defp message(:assistant, content, opts), do: Message.assistant([content: content] ++ opts)

  defp message(:tool, content, opts) do
    Message.tool_result(Keyword.fetch!(opts, :tool_call_id), "tool", content)
  end

  defp tokens(n), do: String.duplicate("x", n * 4)

  describe "select/2" do
    test "shadows the oldest prefix and keeps the retention budget" do
      messages = [
        message(:user, tokens(100)),
        message(:assistant, tokens(100)),
        message(:user, tokens(100)),
        message(:assistant, tokens(100))
      ]

      assert {:ok, plan} = Plan.select(messages, retain_tokens: 150)
      assert plan.cut_index == 2
      assert length(plan.shadowed) == 2
      assert length(plan.retained) == 2
      assert plan.retained_tokens >= 150
      assert plan.tokens_before == ContextUsage.estimate_messages(messages)
      assert plan.first_retained_id == Enum.at(messages, 2).id
    end

    test "never begins the retained tail with an orphan tool result" do
      messages = [
        message(:user, tokens(50)),
        message(:assistant, nil, tool_calls: [%{id: "c1", name: "t", arguments: %{}}]),
        message(:tool, tokens(200), tool_call_id: "c1"),
        message(:assistant, tokens(50))
      ]

      assert {:ok, plan} = Plan.select(messages, retain_tokens: 10)
      refute match?(%Message{role: :tool}, hd(plan.retained))
    end

    test "keeps an assistant tool call together with every linked result" do
      messages = [
        message(:user, tokens(200)),
        message(:assistant, nil,
          tool_calls: [
            %{id: "c1", name: "a", arguments: %{}},
            %{id: "c2", name: "b", arguments: %{}}
          ]
        ),
        message(:tool, tokens(200), tool_call_id: "c1"),
        message(:tool, tokens(200), tool_call_id: "c2"),
        message(:assistant, tokens(20))
      ]

      assert {:ok, plan} = Plan.select(messages, retain_tokens: 300)

      retained_tool_ids =
        plan.retained
        |> Enum.filter(&(&1.role == :tool))
        |> Enum.map(& &1.tool_call_id)

      if retained_tool_ids != [] do
        assistant_calls =
          plan.retained
          |> Enum.flat_map(fn
            %Message{tool_calls: calls} when is_list(calls) -> Enum.map(calls, & &1.id)
            _message -> []
          end)

        assert Enum.all?(retained_tool_ids, &(&1 in assistant_calls))
      end
    end

    test "prefers a user-turn boundary" do
      messages = [
        message(:user, tokens(100)),
        message(:assistant, tokens(100)),
        message(:user, tokens(100)),
        message(:assistant, tokens(100))
      ]

      assert {:ok, plan} = Plan.select(messages, retain_tokens: 120)
      assert hd(plan.retained).role == :user
    end

    test "handles one oversized turn by cutting at an assistant boundary" do
      messages = [
        message(:user, tokens(10)),
        message(:assistant, nil, tool_calls: [%{id: "c1", name: "t", arguments: %{}}]),
        message(:tool, tokens(500), tool_call_id: "c1"),
        message(:assistant, nil, tool_calls: [%{id: "c2", name: "t", arguments: %{}}]),
        message(:tool, tokens(500), tool_call_id: "c2"),
        message(:assistant, tokens(10))
      ]

      assert {:ok, plan} = Plan.select(messages, retain_tokens: 100)
      assert plan.cut_index > 0
      refute match?(%Message{role: :tool}, hd(plan.retained))
      assert length(plan.shadowed) > 0
      assert length(plan.retained) > 0
    end

    test "returns nothing_to_shadow for a single message" do
      assert {:error, :nothing_to_shadow} = Plan.select([message(:user, "hi")])
    end

    test "is deterministic for the same input" do
      messages = [
        message(:user, tokens(50)),
        message(:assistant, tokens(50)),
        message(:user, tokens(50))
      ]

      assert Plan.select(messages, retain_tokens: 60) == Plan.select(messages, retain_tokens: 60)
    end
  end
end
