Code.require_file("../../../bench/support.exs", __DIR__)
Code.require_file("support.exs", __DIR__)

alias Tackle.Runtime.Bench

inputs = Map.new([0, 100, 1_000], &{"#{&1} deltas", Bench.input(10, &1)})

Tackle.Bench.run(
  %{
    "scope + subscribed event burst + await + teardown" => fn config ->
      # The callback executes inside Request. Atomics count delivered events
      # without adding another mailbox hop; terminal delivery follows the burst.
      delivered = :atomics.new(1, [])
      callback = fn _event -> :atomics.add(delivered, 1, 1) end

      Bench.with_scope(config, fn scope ->
        Bench.launch_await(scope, event_callback: callback)
        true = :atomics.get(delivered, 1) == config.events
      end)
    end,
    "scope + unsubscribed (no event production) + await + teardown" => fn config ->
      Bench.with_scope(config, &Bench.launch_await/1)
    end
  },
  inputs: inputs,
  memory_time: 0,
  reduction_time: 0
)
