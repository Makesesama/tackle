defmodule Tackle.Lib.RetryTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Retry

  test "uses validated defaults and deterministic capped exponential delays" do
    retry = Retry.new!()

    assert retry.max_retries == 3
    assert retry.base_delay_ms == 2_000
    assert retry.max_delay_ms == 60_000

    assert Enum.map(1..7, &Retry.delay(retry, &1)) == [
             2_000,
             4_000,
             8_000,
             16_000,
             32_000,
             60_000,
             60_000
           ]

    refute Retry.available?(Retry.new!(false), 0)
    assert_raise ArgumentError, ~r/invalid retry config/, fn -> Retry.new!(max_retries: -1) end

    assert {:error, {:unknown_retry_options, [:extra]}} = Retry.new(extra: true)
    assert {:error, {:invalid_retry_config, ["not keyword"]}} = Retry.new(["not keyword"])
  end

  test "classifies structured transient failures conservatively" do
    assert Retry.retryable?({:http_error, 429, "slow down"})
    assert Retry.retryable?({:http_error, 503, "unavailable"})
    assert Retry.retryable?({:request_failed, :timeout})

    assert Retry.retryable?({:websocket_transport_failed, :before_stream, :connection_refused})

    assert Retry.retryable?({:request_failed, "socket connection was closed"})
  end

  test "never retries permanent, overflow, or unknown failures" do
    refute Retry.retryable?(:context_window_exceeded)
    refute Retry.retryable?({:http_error, 401, "unauthorized"})
    refute Retry.retryable?({:http_error, 400, "server error is not enough to retry a 400"})
    refute Retry.retryable?({:http_error, 403, "rate limit permissions"})
    refute Retry.retryable?({:http_error, 429, ~s({"code":"insufficient_quota"})})
    refute Retry.retryable?({:request_failed, "billing limit reached"})
    refute Retry.retryable?({:http_error, 429, "requests quota has been exhausted"})
    refute Retry.retryable?(:cancelled)
    refute Retry.retryable?(:something_unexpected)
  end

  test "wait is cooperatively cancellable" do
    signal = Cancellation.new_signal()
    test_pid = self()

    task =
      Task.async(fn ->
        send(test_pid, :waiting)
        Retry.wait(5_000, signal)
      end)

    assert_receive :waiting
    Cancellation.cancel(signal, "stopped")
    assert Task.await(task, 500) == {:cancelled, "stopped"}
  end
end
