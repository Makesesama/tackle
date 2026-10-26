defmodule Tackle.Lib.RetryTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.LLM.Error
  alias Tackle.Lib.Retry

  test "uses validated defaults and capped exponential delays" do
    retry = Retry.new!()

    assert retry.max_retries == 3
    assert retry.base_delay_ms == 2_000
    assert retry.max_delay_ms == 60_000
    assert retry.jitter?

    deterministic = Retry.new!(jitter?: false)

    assert Enum.map(1..7, &Retry.delay(deterministic, &1)) == [
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

    assert {:error, {:invalid_retry_config, {:jitter?, "yes"}}} = Retry.new(jitter?: "yes")
    assert {:error, {:unknown_retry_options, [:extra]}} = Retry.new(extra: true)
    assert {:error, {:invalid_retry_config, ["not keyword"]}} = Retry.new(["not keyword"])
  end

  test "jitter draws each delay from the upper half of the backoff" do
    retry = Retry.new!(base_delay_ms: 1_000, max_delay_ms: 60_000)

    for attempt <- 1..4 do
      backoff = 1_000 * Integer.pow(2, attempt - 1)
      delays = for _sample <- 1..200, do: Retry.delay(retry, attempt)

      assert Enum.all?(delays, &(&1 >= div(backoff, 2) and &1 <= backoff))
      assert length(Enum.uniq(delays)) > 1
    end

    capped = for _sample <- 1..50, do: Retry.delay(retry, 10)
    assert Enum.all?(capped, &(&1 >= 30_000 and &1 <= 60_000))
  end

  test "a Retry-After hint lengthens the delay up to the cap" do
    retry = Retry.new!(base_delay_ms: 1_000, max_delay_ms: 10_000, jitter?: false)

    assert Retry.delay(retry, 1, Error.new(:rate_limited, retry_after_ms: 5_000)) == 5_000
    assert Retry.delay(retry, 4, Error.new(:rate_limited, retry_after_ms: 5_000)) == 8_000
    assert Retry.delay(retry, 1, Error.new(:rate_limited, retry_after_ms: 120_000)) == 10_000
    assert Retry.delay(retry, 1, Error.new(:rate_limited)) == 1_000
    assert Retry.delay(retry, 1, :not_an_error) == 1_000

    jittered = Retry.new!(base_delay_ms: 1_000, max_delay_ms: 10_000)
    hint = Error.new(:overloaded, retry_after_ms: 3_000)
    assert Enum.all?(1..50, fn _sample -> Retry.delay(jittered, 1, hint) == 3_000 end)
  end

  test "retries transient error kinds" do
    for kind <- [:transport, :timeout, :rate_limited, :overloaded, :server] do
      assert Retry.retryable?(Error.new(kind)), "expected #{kind} to be retried"
    end

    assert Retry.retryable?(Error.from_response(429, "slow down", []))
    assert Retry.retryable?(Error.from_response(529, %{"type" => "error"}, []))
    assert Retry.retryable?(Error.from_response(503, "unavailable", []))
  end

  # Shaped like `Req.TransportError` and `Mint.TransportError`, which this
  # package does not depend on; the adapters' tests use the real ones.
  defmodule TransportError do
    defexception [:reason]

    @impl true
    def message(%{reason: reason}), do: inspect(reason)
  end

  test "retries transport exceptions and bare transport reasons" do
    for reason <- [:closed, :econnrefused, :econnreset, :nxdomain, :timeout] do
      assert Retry.retryable?(Error.from_transport(%TransportError{reason: reason}))
      assert Retry.retryable?(Error.from_transport(reason))
    end
  end

  test "never retries permanent, overflow, or unknown failures" do
    for kind <- [
          :context_window_exceeded,
          :quota_exceeded,
          :auth,
          :invalid_request,
          :invalid_response,
          :unknown
        ] do
      refute Retry.retryable?(Error.new(kind)), "expected #{kind} not to be retried"
    end

    refute Retry.retryable?(Error.from_response(401, "unauthorized", []))
    refute Retry.retryable?(Error.from_response(400, "server error is not enough", []))

    refute Retry.retryable?(
             Error.from_response(429, %{"error" => %{"code" => "insufficient_quota"}}, [])
           )

    # Reasons that are not provider errors are never retried, whatever they say.
    refute Retry.retryable?({:http_error, 503, "unavailable"})
    refute Retry.retryable?({:request_failed, :timeout})
    refute Retry.retryable?(:timeout)
    refute Retry.retryable?("connection timed out")
    refute Retry.retryable?(:cancelled)
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
