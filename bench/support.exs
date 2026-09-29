defmodule Tackle.Bench do
  @moduledoc false

  # Shared only by repository benchmark scripts, never compiled into a package.
  def run(jobs, opts \\ []) do
    smoke? = System.get_env("BENCH_SMOKE") == "1"

    config =
      if smoke? do
        [warmup: 0, time: 0.05, memory_time: 0, reduction_time: 0]
      else
        [warmup: 2, time: 5, memory_time: 1, reduction_time: 1]
      end

    config =
      Keyword.merge(config,
        pre_check: true,
        parallel: 1,
        formatters: [{Benchee.Formatters.Console, comparison: false}]
      )

    config = Keyword.merge(config, opts)

    config =
      case System.get_env("BENCH_SAVE") do
        nil ->
          config

        path ->
          Keyword.put(config, :save, path: path, tag: System.get_env("BENCH_TAG", "baseline"))
      end

    config =
      case System.get_env("BENCH_LOAD") do
        nil -> config
        path -> Keyword.put(config, :load, path)
      end

    Benchee.run(jobs, config)
  end
end
