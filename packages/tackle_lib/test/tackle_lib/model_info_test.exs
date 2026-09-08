defmodule Tackle.Lib.ModelInfoTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.ModelInfo
  alias Tackle.Lib.Usage

  describe "normalize/2" do
    test "normalizes limits and a price card" do
      assert {:ok, info} =
               ModelInfo.normalize("model-a", %{
                 "context_window" => 128_000,
                 "max_output_tokens" => 16_000,
                 "pricing" => %{
                   "input" => 2,
                   "output" => 8,
                   "cache_read" => 0.2,
                   "cache_write" => 2.5
                 }
               })

      assert %ModelInfo{model: "model-a", context_window: 128_000, max_output_tokens: 16_000} =
               info

      assert info.pricing.currency == "USD"
      assert info.pricing.unit_tokens == 1_000_000
    end

    test "rejects malformed limits and pricing" do
      assert {:error, {:invalid_model_info, "model-a", {:context_window, 0}}} =
               ModelInfo.normalize("model-a", %{context_window: 0})

      assert {:error, {:invalid_model_info, "model-a", {:max_output_tokens, 20}}} =
               ModelInfo.normalize("model-a", %{context_window: 10, max_output_tokens: 20})

      assert {:error, {:invalid_model_info, "model-a", {:pricing, %{input: 1}}}} =
               ModelInfo.normalize("model-a", %{pricing: %{input: 1}})
    end
  end

  describe "estimate_cost/2" do
    setup do
      {:ok, info} =
        ModelInfo.normalize("model-a", %{
          context_window: 128_000,
          pricing: %{
            input: 2,
            output: 8,
            cache_read: 0.2,
            cache_write: 2.5,
            currency: "USD",
            unit_tokens: 1_000_000
          }
        })

      %{info: info}
    end

    test "adds itemized estimated cost for the reported token buckets", %{info: info} do
      usage =
        ModelInfo.estimate_cost(info, %Usage{
          input_tokens: 100_000,
          output_tokens: 10_000,
          cache_read_tokens: 50_000,
          cache_write_tokens: 20_000
        })

      assert_in_delta usage.cost_breakdown.input, 0.2, 0.000_001
      assert_in_delta usage.cost_breakdown.output, 0.08, 0.000_001
      assert_in_delta usage.cost_breakdown.cache_read, 0.01, 0.000_001
      assert_in_delta usage.cost_breakdown.cache_write, 0.05, 0.000_001
      assert_in_delta usage.cost_breakdown.total, 0.34, 0.000_001
      assert usage.cost_breakdown.estimated
      assert_in_delta usage.cost, 0.34, 0.000_001
      assert usage.cost_estimated
      assert usage.currency == "USD"
    end

    test "preserves authoritative provider cost while marking derived itemization", %{info: info} do
      usage =
        ModelInfo.estimate_cost(info, %Usage{
          input_tokens: 100_000,
          cost: 0.123,
          currency: "EUR"
        })

      assert usage.cost == 0.123
      assert usage.currency == "EUR"
      assert usage.cost_estimated == nil
      assert usage.cost_breakdown.estimated
      assert_in_delta usage.cost_breakdown.total, 0.2, 0.000_001
    end

    test "does not invent a zero-dollar total when no token bucket was reported", %{info: info} do
      assert %Usage{cost: nil, cost_breakdown: nil} =
               ModelInfo.estimate_cost(info, %Usage{})
    end
  end
end
