Code.require_file("../bench/support.exs", __DIR__)

defmodule Tackle.Runtime.StartWorkTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Tackle.Runtime

  test "start_work places a trusted child under the scope work supervisor" do
    scope = Bench.setup(Bench.input(10))
    parent = self()

    {:ok, pid} =
      Runtime.start_work(scope.root_agent_ref, {Task, fn -> send(parent, :work_started) end})

    assert is_pid(pid)
    assert_receive :work_started, 2_000

    :ok = Bench.teardown(scope)
    assert_eventually(fn -> not Process.alive?(pid) end)
  end

  test "start_work rejects an unknown parent" do
    assert {:error, {:invalid_requester, :nope}} =
             Runtime.start_work(:nope, {Task, fn -> :ok end})
  end

  defp assert_eventually(fun, attempts \\ 200)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met in time")
end
