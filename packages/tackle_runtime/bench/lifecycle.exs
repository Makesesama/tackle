Code.require_file("../../../bench/support.exs", __DIR__)
Code.require_file("support.exs", __DIR__)

alias Tackle.Runtime.Bench

inputs = Map.new([10, 100, 1_000, 10_000], &{"#{&1} messages", Bench.input(&1)})

# Fresh scopes prevent asynchronously released admission slots or retained results
# leaking between samples. The workflow uses untimed setup/cleanup hooks so its
# scheduling-dependent post-completion linger cannot dominate execution timing.
Tackle.Bench.run(
  %{
    "scope + launch + await + teardown" =>
      &Bench.with_scope(&1, fn scope -> Bench.launch_await(scope) end),
    "workflow / start + await (one child; cleanup excluded)" =>
      {&Bench.workflow/1, before_each: &Bench.setup/1, after_each: &Bench.finish_workflow/1}
  },
  inputs: inputs,
  memory_time: 0,
  reduction_time: 0
)

# Benchee does not measure worker heaps. Report the retained Request separately,
# after a full GC, rather than mislabeling caller allocations as runtime memory.
Enum.each(inputs, fn {label, config} ->
  Bench.with_scope(config, fn scope ->
    {run, pid} = Bench.retained(scope)
    true = :erlang.garbage_collect(pid)
    info = Map.new(Process.info(pid, [:memory, :reductions, :message_queue_len]))
    IO.puts(JSON.encode!(%{input: label, retained_request: info}))
    :ok = Bench.collect(scope, run, pid)
  end)
end)
