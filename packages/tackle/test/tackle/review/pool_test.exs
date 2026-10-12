defmodule Tackle.Review.PoolTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Cancellation
  alias Tackle.Review.Pool

  test "returns results in input order with at most `limit` items in flight" do
    counter = :counters.new(2, [])

    fun = fn item ->
      :counters.add(counter, 1, 1)
      :counters.put(counter, 2, max(:counters.get(counter, 2), :counters.get(counter, 1)))
      Process.sleep(10 * (5 - item))
      :counters.sub(counter, 1, 1)
      item * 10
    end

    assert {:ok, [10, 20, 30, 40]} = Pool.map([1, 2, 3, 4], 2, fun)
    assert :counters.get(counter, 2) <= 2
  end

  test "reports a raising item as an error and calls the callbacks in order" do
    parent = self()

    fun = fn
      2 -> raise "boom"
      item -> item
    end

    assert {:ok, [1, {:error, {:crashed, "boom"}}, 3]} =
             Pool.map([1, 2, 3], 1, fun,
               on_start: &send(parent, {:start, &1}),
               on_result: &send(parent, {:result, &1, &2})
             )

    assert_received {:start, 1}
    assert_received {:result, 1, 1}
    assert_received {:result, 2, {:error, {:crashed, "boom"}}}
    assert_received {:result, 3, 3}
  end

  test "a cancelled signal stops the batch and shuts its tasks down" do
    signal = Cancellation.new_signal()
    parent = self()

    fun = fn item ->
      send(parent, {:running, item, self()})
      Process.sleep(:infinity)
    end

    task = Task.async(fn -> Pool.map([1, 2, 3], 2, fun, cancellation: signal) end)
    assert_receive {:running, 1, pid}
    ref = Process.monitor(pid)
    Cancellation.cancel(signal)

    assert Task.await(task) == {:error, :cancelled}
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    refute_received {:running, 3, _pid}
  end

  test "a result matching :cancelled? stops the batch" do
    fun = fn
      1 -> {:error, :cancelled}
      _item -> Process.sleep(:infinity)
    end

    assert {:error, :cancelled} =
             Pool.map([1, 2], 2, fun, cancelled?: &match?({:error, :cancelled}, &1))
  end

  test "an empty batch returns no results" do
    assert {:ok, []} = Pool.map([], 3, & &1)
  end
end
