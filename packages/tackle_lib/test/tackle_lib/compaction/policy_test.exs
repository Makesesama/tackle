defmodule Tackle.Lib.Compaction.PolicyTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Compaction.Policy
  alias Tackle.Lib.ModelInfo

  describe "resolve/3" do
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

    test "caps the default output reserve instead of reserving the model's maximum" do
      # Codex models declare 128,000 output tokens of a 272,000 window; the
      # threshold must not drop to half the window.
      info = %ModelInfo{model: "m", context_window: 272_000, max_output_tokens: 128_000}

      assert {:ok, resolved} = Policy.resolve(Policy.new!([]), info)
      assert resolved.response_reserve == 32_768
      assert resolved.hard_safe_limit == 272_000 - 32_768 - 4_096
      assert resolved.trigger_at == resolved.attention_limit
      assert resolved.trigger_at == 217_600

      assert {:ok, capped} = Policy.resolve(Policy.new!(max_response_reserve: 16_000), info)
      assert capped.response_reserve == 16_000
    end

    test "reserves the output limit the requests ask for" do
      info = %ModelInfo{model: "m", context_window: 128_000, max_output_tokens: 128_000}

      assert {:ok, resolved} = Policy.resolve(Policy.new!([]), info, max_tokens: 50_000)
      assert resolved.response_reserve == 50_000

      # Still at most half the window.
      assert {:ok, clamped} = Policy.resolve(Policy.new!([]), info, max_tokens: 100_000)
      assert clamped.response_reserve == 64_000
      assert clamped.usable?
    end

    test "keeps the retention target below what a compaction can leave" do
      policy = Policy.new!(response_reserve: 1_000, safety_reserve: 0, summary_max_tokens: 1_000)
      info = %ModelInfo{model: "m", context_window: 20_000}

      assert {:ok, resolved} = Policy.resolve(policy, info, fixed_tokens: 9_000)
      # trigger 16,000 less 9,000 fixed and a 1,000-token summary.
      assert resolved.max_retained_tokens == 6_000
      assert resolved.retain_tokens == 3_000
      assert resolved.usable?

      assert {:ok, explicit} =
               Policy.resolve(Policy.new!(retain_tokens: 10_000, safety_reserve: 0), info,
                 fixed_tokens: 9_000
               )

      assert explicit.retain_tokens < explicit.max_retained_tokens
    end

    test "is unusable when the fixed request and a summary leave no room below the threshold" do
      policy = Policy.new!(response_reserve: 1_000, safety_reserve: 0, summary_max_tokens: 1_000)
      info = %ModelInfo{model: "m", context_window: 20_000}

      assert {:ok, resolved} = Policy.resolve(policy, info, fixed_tokens: 15_000)
      assert resolved.trigger_at == 16_000
      refute resolved.usable?
      assert resolved.max_retained_tokens == nil
      refute Policy.pressure?(resolved, 19_000)
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
        Policy.resolve(
          Policy.new!(response_reserve: 100, safety_reserve: 0, summary_max_tokens: 1_000),
          %ModelInfo{
            model: "m",
            context_window: 10_000
          }
        )

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
      assert {:error, _reason} = Policy.new(max_response_reserve: 0)
    end
  end
end
