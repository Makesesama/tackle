defmodule Tackle.Lib.ThinkingTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Thinking

  doctest Thinking

  test "levels include max above xhigh" do
    assert Thinking.levels() == ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    assert Thinking.validate("max") == :ok
  end

  test "put_llm_opts sets only the effort, leaving provider options to adapters" do
    assert {:ok, opts} = Thinking.put_llm_opts([model: "test"], "max")
    assert opts == [model: "test", reasoning_effort: "max"]
    assert Thinking.from_llm_opts(opts) == "max"

    assert {:ok, [model: "test"]} = Thinking.put_llm_opts(opts, "off")
    assert {:error, {:invalid_thinking_level, "ultra"}} = Thinking.put_llm_opts(opts, "ultra")
  end

  test "from_llm_opts returns only known levels" do
    for level <- Thinking.levels() do
      assert Thinking.from_llm_opts(reasoning_effort: level) == level
      assert Thinking.from_llm_opts(reasoning_effort: String.to_atom(level)) == level
    end

    assert Thinking.from_llm_opts([]) == "off"
    assert Thinking.from_llm_opts(reasoning_effort: :none) == "off"
    assert Thinking.from_llm_opts(reasoning_effort: "none") == "off"
    assert Thinking.from_llm_opts(reasoning_effort: :bogus) == "off"
    assert Thinking.from_llm_opts(reasoning_effort: "ultra") == "off"
    assert Thinking.from_llm_opts(reasoning_effort: 3) == "off"
  end

  test "parse reads levels, disabled values, and absence" do
    assert Thinking.parse(nil) == {:ok, nil}
    assert Thinking.parse(:off) == {:ok, "off"}
    assert Thinking.parse("medium") == {:ok, "medium"}
    assert Thinking.parse(:xhigh) == {:ok, "xhigh"}
    assert Thinking.parse(:bogus) == {:error, {:invalid_reasoning_effort, :bogus}}
    assert Thinking.parse(%{}) == {:error, {:invalid_reasoning_effort, %{}}}
  end

  test "nearest keeps supported levels and rounds ties down" do
    assert Thinking.nearest("high", ["low", "high", "max"]) == "high"
    assert Thinking.nearest("medium", ["low", "high", "max"]) == "low"
    assert Thinking.nearest("xhigh", ["low", "high", "max"]) == "high"
    assert Thinking.nearest("max", ["low", "medium", "high", "xhigh"]) == "xhigh"
    assert Thinking.nearest("minimal", ["max", "low"]) == "low"
    assert Thinking.nearest("minimal", ["high"]) == "high"
  end

  test "nearest rejects levels that are not reasoning levels" do
    assert_raise FunctionClauseError, fn -> Thinking.nearest("off", ["low"]) end
    assert_raise ArgumentError, fn -> Thinking.nearest("high", ["off", "low"]) end
  end
end
