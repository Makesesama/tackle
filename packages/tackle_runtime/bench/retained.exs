Code.require_file("support.exs", __DIR__)

alias Tackle.Runtime.Bench
alias Tackle.Runtime.Registry

# Point-in-time diagnostics, not a Benchee timing or whole-scope memory metric.
# The setup-only blob is not returned in the Outcome, while the 10k-message
# fixture deliberately duplicates its agent state in config and outcome.
inputs = %{
  "small result / small config" => Bench.input(10),
  "small result / large setup config" =>
    Map.put(Bench.input(10), :setup_blob, Enum.map(1..10_000, &Integer.to_string/1)),
  "large result / duplicated config" => Bench.input(10_000)
}

Enum.each(inputs, fn {label, config} ->
  Bench.with_scope(config, fn scope ->
    {run, request} = Bench.retained(scope)
    {:ok, backend} = Registry.whereis(run.agent_ref)
    true = :erlang.garbage_collect(request)
    true = :erlang.garbage_collect(backend)
    state = :sys.get_state(request)

    IO.puts(
      JSON.encode!(%{
        input: label,
        request_bytes: elem(Process.info(request, :memory), 1),
        backend_bytes: elem(Process.info(backend, :memory), 1),
        outcome_words: :erts_debug.size(state.outcome),
        setup_config_words:
          if(state.agent_spec, do: :erts_debug.size(state.agent_spec.config), else: 0)
      })
    )

    :ok = Bench.collect(scope, run, request)
  end)
end)
