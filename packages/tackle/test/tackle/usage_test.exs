defmodule Tackle.UsageTest do
  use ExUnit.Case, async: true

  alias Tackle.Usage

  describe "normalize/2" do
    test "returns nil for missing usage" do
      assert Usage.normalize(nil) == nil
    end

    test "passes existing usage through while filling context" do
      usage = %Usage{input_tokens: 10}

      assert %Usage{input_tokens: 10, model: "model-a", provider: :provider} =
               Usage.normalize(usage, model: "model-a", provider: :provider)
    end

    test "normalizes common atom-keyed token fields" do
      usage = Usage.normalize(%{prompt_tokens: 12, completion_tokens: 7}, model: "model-a")

      assert usage.input_tokens == 12
      assert usage.output_tokens == 7
      assert usage.total_tokens == 19
      assert usage.model == "model-a"
      assert usage.raw == %{prompt_tokens: 12, completion_tokens: 7}
    end

    test "normalizes string-keyed extended fields and preserves optional cost" do
      usage =
        Usage.normalize(%{
          "input_tokens" => "10",
          "output_tokens" => 5,
          "reasoning_tokens" => 3,
          "cache_read_tokens" => 2,
          "cache_write_tokens" => 1,
          "total_tokens" => 21,
          "cost" => 0.001,
          "currency" => "USD",
          "provider" => "openrouter"
        })

      assert usage.input_tokens == 10
      assert usage.output_tokens == 5
      assert usage.reasoning_tokens == 3
      assert usage.cache_read_tokens == 2
      assert usage.cache_write_tokens == 1
      assert usage.total_tokens == 21
      assert usage.cost == 0.001
      assert usage.currency == "USD"
      assert usage.provider == "openrouter"
    end
  end

  describe "aggregate/1" do
    test "sums token fields across normalized usage entries" do
      usage =
        Usage.aggregate([
          %Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15},
          %{prompt_tokens: 7, completion_tokens: 3, reasoning_tokens: 2},
          nil
        ])

      assert usage.input_tokens == 17
      assert usage.output_tokens == 8
      assert usage.reasoning_tokens == 2
      assert usage.total_tokens == 25
    end

    test "sums cost when every usage entry has numeric cost and compatible currency" do
      usage =
        Usage.aggregate([
          %Usage{input_tokens: 1, output_tokens: 1, cost: 0.01, currency: "USD"},
          %Usage{input_tokens: 1, output_tokens: 1, cost: 0.02, currency: "USD"}
        ])

      assert_in_delta usage.cost, 0.03, 0.000_001
      assert usage.currency == "USD"
    end

    test "does not return partial aggregate cost for missing cost or mixed currency" do
      missing_cost =
        Usage.aggregate([
          %Usage{input_tokens: 1, output_tokens: 1, cost: 0.01, currency: "USD"},
          %Usage{input_tokens: 1, output_tokens: 1, currency: "USD"}
        ])

      mixed_currency =
        Usage.aggregate([
          %Usage{input_tokens: 1, output_tokens: 1, cost: 0.01, currency: "USD"},
          %Usage{input_tokens: 1, output_tokens: 1, cost: 0.02, currency: "EUR"}
        ])

      assert missing_cost.cost == nil
      assert missing_cost.currency == "USD"
      assert mixed_currency.cost == nil
      assert mixed_currency.currency == nil
    end
  end

  describe "to_map/1" do
    test "drops nil fields" do
      assert Usage.to_map(%Usage{input_tokens: 1, output_tokens: nil}) == %{input_tokens: 1}
    end
  end
end
