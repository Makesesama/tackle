defmodule Tackle.Lib.Compaction.PolicyTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Compaction.Policy
  alias Tackle.Lib.ModelInfo

  describe "resolve/2" do
    test "combines the output reserve and attention limit for a large window" do
      policy = Policy.new!([])

      info = %ModelInfo{model: "m", context_window: 200_000, max_output_tokens: 16_384}

      assert {:ok, resolved} = Policy.resolve(policy, info)
      assert resolved.response_reserve == 16_384
      assert resolved.safety_reserve == 4_096
      assert resolved.hard_safe_limit == 200_000 - 16_384 - 4_096
      assert resolved.attention_limit == 160_000
      assert resolved.trigger_at == min(resolved.hard_safe_limit, resolved.attention_limit)
      assert resolved.retain_tokens == 20_000
      assert resolved.summary_max_tokens == 8_192
      assert resolved.usable?
    end

    test "uses the attention limit when it is below the hard safe limit" do
      policy = Policy.new!(response_reserve: 1_000, safety_reserve: 0)

      info = %ModelInfo{model: "m", context_window: 10_000, max_output_tokens: 1_000}

      assert {:ok, resolved} = Policy.resolve(policy, info)
      assert resolved.hard_safe_limit == 9_000
      assert resolved.attention_limit == 8_000
      assert resolved.trigger_at == 8_000
    end

    test "falls back to 8,192 output reserve when max_output_tokens is unknown" do
      policy = Policy.new!(safety_reserve: 0)

      info = %ModelInfo{model: "m", context_window: 100_000, max_output_tokens: nil}

      assert {:ok, resolved} = Policy.resolve(policy, info)
      assert resolved.response_reserve == 8_192
      assert resolved.hard_safe_limit == 91_808
    end

    test "scales retention with the window and clamps small and large windows" do
      assert {:ok, tiny} =
               Policy.resolve(Policy.new!([]), %ModelInfo{model: "m", context_window: 10_000})

      assert tiny.retain_tokens == 4_096

      assert {:ok, mid} =
               Policy.resolve(Policy.new!([]), %ModelInfo{model: "m", context_window: 100_000})

      assert mid.retain_tokens == 16_000

      assert {:ok, huge} =
               Policy.resolve(Policy.new!([]), %ModelInfo{model: "m", context_window: 1_000_000})

      assert huge.retain_tokens == 20_000
    end

    test "marks a window unusable when the reserves exceed it" do
      policy = Policy.new!([])

      # 4,096 safety reserve + 100 output reserve leave nothing at a 1,000 window.
      info = %ModelInfo{model: "m", context_window: 1_000, max_output_tokens: 100}

      assert {:ok, resolved} = Policy.resolve(policy, info)
      assert resolved.trigger_at == 0
      refute resolved.usable?
      refute Policy.pressure?(resolved, 1_000)
    end

    test "clamps an oversized output reserve to half the window" do
      info = %ModelInfo{model: "m", context_window: 128_000, max_output_tokens: 128_000}

      assert {:ok, resolved} = Policy.resolve(Policy.new!([]), info)
      assert resolved.response_reserve == 64_000
      assert resolved.hard_safe_limit == 128_000 - 64_000 - 4_096
      assert resolved.trigger_at > 0
      assert resolved.usable?
    end

    test "returns no_context_window when the adapter declares none" do
      assert {:error, :no_context_window} =
               Policy.resolve(Policy.new!([]), %ModelInfo{model: "m", context_window: nil})
    end

    test "honours explicit overrides" do
      policy =
        Policy.new!(
          response_reserve: 500,
          safety_reserve: 500,
          attention_ratio: 0.5,
          retain_tokens: 2_000,
          summary_max_tokens: 1_000,
          overflow_retry_limit: 2
        )

      info = %ModelInfo{model: "m", context_window: 100_000, max_output_tokens: 8_192}

      assert {:ok, resolved} = Policy.resolve(policy, info)
      assert resolved.response_reserve == 500
      assert resolved.hard_safe_limit == 99_000
      assert resolved.attention_limit == 50_000
      assert resolved.trigger_at == 50_000
      assert resolved.retain_tokens == 2_000
      assert resolved.summary_max_tokens == 1_000
      assert policy.overflow_retry_limit == 2
    end
  end

  describe "pressure?/2" do
    test "is true exactly at the threshold" do
      {:ok, resolved} =
        Policy.resolve(Policy.new!(response_reserve: 100, safety_reserve: 0), %ModelInfo{
          model: "m",
          context_window: 10_000
        })

      assert Policy.pressure?(resolved, resolved.trigger_at)
      refute Policy.pressure?(resolved, resolved.trigger_at - 1)
      refute Policy.pressure?(resolved, nil)
    end
  end

  describe "new/1" do
    test "rejects invalid values" do
      assert {:error, _reason} = Policy.new(attention_ratio: 2.0)
      assert {:error, _reason} = Policy.new(attention_ratio: 0.0)
      assert {:error, _reason} = Policy.new(safety_reserve: -1)
      assert {:error, _reason} = Policy.new(retain_tokens: 0)
      assert {:error, _reason} = Policy.new(min_retain_tokens: 10, max_retain_tokens: 5)
    end
  end
end
