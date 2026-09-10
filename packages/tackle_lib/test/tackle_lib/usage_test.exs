defmodule Tackle.Lib.UsageTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Usage

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

  describe "prompt cache metrics" do
    test "calculates prompt volume and its raw cached share" do
      usage = %Usage{
        input_tokens: 100,
        output_tokens: 10,
        cache_read_tokens: 50,
        cache_write_tokens: 50
      }

      assert Usage.prompt_tokens(usage) == 200
      assert_in_delta Usage.cache_hit_rate(usage), 0.25, 0.000_001
    end

    test "distinguishes an uncached request from unsupported cache reporting" do
      assert Usage.cache_hit_rate(%Usage{input_tokens: 100}) == nil
      assert Usage.cache_hit_rate(%Usage{input_tokens: 100, cache_read_tokens: 0}) == 0.0
      assert Usage.cache_hit_rate(%Usage{cache_read_tokens: 0, cache_write_tokens: 0}) == nil
    end

    test "measures reuse against the preceding prompt rather than new content" do
      usages = [
        %Usage{input_tokens: 10, cache_read_tokens: 0},
        %Usage{input_tokens: 10, cache_read_tokens: 10},
        %Usage{input_tokens: 10, cache_read_tokens: 20}
      ]

      aggregate = Usage.aggregate(usages)
      assert_in_delta Usage.cache_hit_rate(aggregate), 0.5, 0.000_001

      assert Usage.cache_reuse(usages) == %{
               reusable_tokens: 30,
               reused_tokens: 30,
               missed_tokens: 0,
               rate: 1.0
             }

      assert Usage.cache_reuse_rate(usages) == 1.0
    end

    test "reports tokens from reusable prefixes that missed the cache" do
      usages = [
        %Usage{input_tokens: 100, cache_read_tokens: 0},
        %Usage{input_tokens: 150, cache_read_tokens: 50},
        %Usage{input_tokens: 50, cache_read_tokens: 200}
      ]

      assert Usage.cache_reuse(usages) == %{
               reusable_tokens: 300,
               reused_tokens: 250,
               missed_tokens: 50,
               rate: 250 / 300
             }
    end

    test "requires consecutive prompt checkpoints with cache reporting" do
      assert Usage.cache_reuse([]) == nil
      assert Usage.cache_reuse([%Usage{input_tokens: 100}]) == nil

      assert Usage.cache_reuse([
               %Usage{input_tokens: 100},
               %Usage{input_tokens: 100}
             ]) == nil

      assert Usage.cache_reuse([
               %Usage{input_tokens: 100},
               %Usage{input_tokens: 100, cache_read_tokens: 0}
             ]) == %{
               reusable_tokens: 100,
               reused_tokens: 0,
               missed_tokens: 100,
               rate: 0.0
             }
    end

    test "includes cache buckets when deriving a missing total" do
      usage =
        Usage.normalize(%{
          input_tokens: 10,
          output_tokens: 5,
          cache_read_tokens: 20,
          cache_write_tokens: 2
        })

      assert usage.total_tokens == 37
      assert Usage.context_tokens(usage) == 37
      assert Usage.context_tokens(%Usage{}) == nil
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

    test "marks a mixed authoritative and estimated aggregate as estimated" do
      usage =
        Usage.aggregate([
          %Usage{
            cost: 0.01,
            cost_breakdown: %{input: 0.01, total: 0.01, estimated: false},
            cost_estimated: false,
            currency: "USD"
          },
          %Usage{
            cost: 0.02,
            cost_breakdown: %{output: 0.02, total: 0.02, estimated: true},
            cost_estimated: true,
            currency: "USD"
          }
        ])

      assert_in_delta usage.cost, 0.03, 0.000_001
      assert usage.cost_estimated
      assert usage.cost_breakdown.estimated
      assert_in_delta usage.cost_breakdown.total, 0.03, 0.000_001
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
