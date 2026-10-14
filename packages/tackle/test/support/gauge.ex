defmodule Tackle.Test.Gauge do
  @moduledoc false
  # Measures how many callers are inside `hold/2` at the same time.
  #
  # Each caller waits until `expected` callers have been inside together (or
  # `wait` milliseconds pass), then stays a while longer before leaving.
  # Holding the first wave open makes a lower concurrency show as a lower peak,
  # and staying on gives any caller beyond `expected` time to arrive and raise
  # the peak.

  @stay_ms 250

  def start_link, do: Agent.start_link(fn -> %{now: 0, peak: 0} end)

  def hold(gauge, expected, wait \\ 3_000) do
    Agent.update(gauge, fn %{now: now, peak: peak} ->
      %{now: now + 1, peak: max(peak, now + 1)}
    end)

    await_peak(gauge, expected, System.monotonic_time(:millisecond) + wait)
    Process.sleep(@stay_ms)
    Agent.update(gauge, &%{&1 | now: &1.now - 1})
  end

  def peak(gauge), do: Agent.get(gauge, & &1.peak)

  defp await_peak(gauge, expected, deadline) do
    cond do
      peak(gauge) >= expected ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :ok

      true ->
        Process.sleep(5)
        await_peak(gauge, expected, deadline)
    end
  end
end
