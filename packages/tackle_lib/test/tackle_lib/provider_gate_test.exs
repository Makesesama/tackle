defmodule Tackle.Lib.ProviderGateTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.ProviderGate

  test "absent and successful gates proceed" do
    assert ProviderGate.await(nil) == :ok
    assert ProviderGate.await(fn -> :ok end) == :ok
  end

  test "gate errors remain explicit" do
    assert ProviderGate.await(fn -> {:error, :unavailable} end) == {:error, :unavailable}

    assert ProviderGate.await(fn -> :unexpected end) ==
             {:error, {:invalid_before_provider_call_result, :unexpected}}
  end

  test "gate exceptions and exits do not dispatch provider work" do
    assert ProviderGate.await(fn -> raise "unavailable" end) ==
             {:error, {:before_provider_call_failed, "unavailable"}}

    assert ProviderGate.await(fn -> exit(:unavailable) end) ==
             {:error, {:before_provider_call_failed, {:exit, :unavailable}}}

    assert ProviderGate.await(fn -> throw(:unavailable) end) ==
             {:error, {:before_provider_call_failed, {:throw, :unavailable}}}
  end
end
