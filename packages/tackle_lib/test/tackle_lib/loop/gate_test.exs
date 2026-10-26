defmodule Tackle.Lib.Loop.GateTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Loop.Gate

  test "absent and successful gates proceed" do
    for gate <- [&Gate.before_provider_call/1, &Gate.before_tool_execution/1] do
      assert gate.(nil) == :ok
      assert gate.(fn -> :ok end) == :ok
    end
  end

  test "gate errors remain explicit and name their gate" do
    assert Gate.before_provider_call(fn -> {:error, :unavailable} end) ==
             {:error, :unavailable}

    assert Gate.before_provider_call(fn -> :unexpected end) ==
             {:error, {:invalid_before_provider_call_result, :unexpected}}

    assert Gate.before_tool_execution(fn -> :unexpected end) ==
             {:error, {:invalid_before_tool_execution_result, :unexpected}}
  end

  test "gate exceptions and exits refuse the work" do
    assert Gate.before_provider_call(fn -> raise "unavailable" end) ==
             {:error, {:before_provider_call_failed, "unavailable"}}

    assert Gate.before_provider_call(fn -> exit(:unavailable) end) ==
             {:error, {:before_provider_call_failed, {:exit, :unavailable}}}

    assert Gate.before_tool_execution(fn -> throw(:unavailable) end) ==
             {:error, {:before_tool_execution_failed, {:throw, :unavailable}}}
  end
end
