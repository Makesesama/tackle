defmodule Tackle.ThinkingTest do
  use ExUnit.Case, async: true

  alias Tackle.Thinking

  test "levels include max above xhigh" do
    assert Thinking.levels() == ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    assert Thinking.validate("max") == :ok
  end

  test "max is retained in adapter options" do
    assert {:ok, opts} = Thinking.put_llm_opts([model: "test"], "max")
    assert opts == [model: "test", reasoning_effort: "max", reasoning_summary: "auto"]
    assert Thinking.from_llm_opts(opts) == "max"
  end
end
