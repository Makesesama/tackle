# Live watchdog probe against a local Ollama server. NOT a synthetic baseline:
# it needs Ollama (>= 0.35) on localhost:11434 with `tev1:4b` pulled.
#
#   cd apps/tackle_cli && mix run --no-start bench/watchdog_live.exs
#
# Environment knobs (all optional):
#   WATCHDOG_MODEL=tev1:4b      decision model (must be listed below)
#   WATCHDOG_AFTER=10           seconds before the first check
#   WATCHDOG_THRESHOLD=0.85     stop threshold
#   WATCHDOG_RUNS=3             end-to-end runs per scenario
#   WATCHDOG_LIMIT=150          seconds before a run counts as "not stopped"
#   OLLAMA_BASE_URL=http://localhost:11434/v1
#
# Two layers are measured separately so a failure can be attributed:
#
#   1. model  - direct decisions on synthetic tick-loop digests at increasing
#               ages; shows what the model answers, without the harness.
#   2. system - full runs: a scripted chat model makes the agent call the real
#               `bash` tool, and the real watchdog (RootBackend services,
#               Tackle.Watchdog, the local `ollama` provider) must stop the
#               tick loop. A finite control command must NOT be stopped.
#
# Only the chat model is scripted. The decision adapter is a thin recorder that
# delegates every call to Tackle.Plugins.Ollama unchanged.

model = System.get_env("WATCHDOG_MODEL", "tev1:4b")
after_seconds = String.to_integer(System.get_env("WATCHDOG_AFTER", "10"))
threshold = String.to_float(System.get_env("WATCHDOG_THRESHOLD", "0.85"))
runs = String.to_integer(System.get_env("WATCHDOG_RUNS", "3"))
limit_ms = String.to_integer(System.get_env("WATCHDOG_LIMIT", "150")) * 1_000
base_url = System.get_env("OLLAMA_BASE_URL", "http://localhost:11434/v1")

Application.put_env(:tackle_ollama, Tackle.Plugins.Ollama,
  providers: %{"ollama" => %{"base_url" => base_url, "decision_models" => [model]}}
)

{:ok, _apps} = Application.ensure_all_started(:tackle)
{:ok, _apps} = Application.ensure_all_started(:tackle_ollama)

defmodule WatchdogLive.Script do
  @moduledoc false
  # Scripted chat model: the first step calls bash with the scenario command,
  # every later step (after the tool result) answers and ends the turn.
  @behaviour Tackle.Lib.LLM

  @impl true
  def adapter_id, do: "script"

  @impl true
  def models, do: ["bash"]

  @impl true
  def generate(_schema, opts) do
    tool_result? = Enum.any?(Keyword.get(opts, :messages, []), &(Map.get(&1, :role) == :tool))

    data =
      if tool_result?,
        do: %{"content" => "done", "tool_calls" => []},
        else: %{
          "content" => nil,
          "tool_calls" => [
            %{
              "id" => "bench-call",
              "name" => "bash",
              "arguments" => %{"command" => Keyword.fetch!(opts, :bench_command)}
            }
          ]
        }

    {:ok, %{data: data, usage: nil, model: "bash", provider: adapter_id()}}
  end
end

defmodule WatchdogLive.Recorder do
  @moduledoc false
  # Decision adapter offering the local `ollama` provider of
  # Tackle.Plugins.Ollama; it records each call and delegates it unchanged.
  @behaviour Tackle.Lib.LLM
  @behaviour Tackle.Lib.Decision

  alias Tackle.Plugins.Ollama

  @impl Tackle.Lib.LLM
  def adapter_id, do: Ollama.adapter_id()

  @impl Tackle.Lib.LLM
  def default_providers, do: Enum.filter(Ollama.default_providers(), &(elem(&1, 0) == "ollama"))

  @impl Tackle.Lib.LLM
  def models(_settings), do: []

  @impl Tackle.Lib.LLM
  def generate(schema, opts), do: Ollama.generate(schema, opts)

  @impl Tackle.Lib.Decision
  def decision_models(settings), do: Ollama.decision_models(settings)

  @impl Tackle.Lib.Decision
  def local?(settings), do: Ollama.local?(settings)

  @impl Tackle.Lib.Decision
  def decide(request, opts) do
    started = System.monotonic_time(:millisecond)
    result = Ollama.decide(request, opts)
    latency = System.monotonic_time(:millisecond) - started

    if pid = Process.whereis(:watchdog_live), do: send(pid, {:decision, request, result, latency})

    result
  end
end

defmodule WatchdogLive do
  @moduledoc false

  alias Tackle.Lib.Decision
  alias Tackle.Lib.Decision.Answer
  alias Tackle.Lib.Event
  alias Tackle.Runtime.{AgentSpec, ScopeSpec}
  alias Tackle.Watchdog.Digest

  @stop_verdicts ~w(waiting_for_input infinite_loop stalled)

  # ── Layer 1: the model alone ────────────────────────────────────────

  def model_layer(model_ref, ages, threshold) do
    {:ok, selection} = Decision.select([WatchdogLive.Recorder], model_ref)
    command = "while true; do echo tick; sleep 1; done"
    IO.puts("\n== model: #{command}")

    rows =
      for age <- ages do
        digest =
          Enum.reduce(1..age, Digest.new(command, 0), fn second, digest ->
            Digest.append(digest, "tick\n", second * 1_000)
          end)

        state = Digest.state(digest, age * 1_000 + 500)
        started = System.monotonic_time(:millisecond)
        result = Decision.decide(selection, state, [Tackle.Watchdog.question()], [])
        latency = System.monotonic_time(:millisecond) - started
        flush_decisions()

        {verdict, p, top} = summarize(result)
        stop? = verdict in @stop_verdicts and p >= threshold

        IO.puts(
          "  age=#{pad(age, 4)}s  #{pad(verdict, 21)} p=#{fmt(p)}  " <>
            "#{if stop?, do: "STOP", else: "keep"}  #{pad(latency, 5)}ms  #{top}"
        )

        %{stop?: stop?, latency: latency, error?: match?({:error, _}, result)}
      end

    stops = Enum.count(rows, & &1.stop?)
    errors = Enum.count(rows, & &1.error?)
    latencies = rows |> Enum.map(& &1.latency) |> Enum.sort()

    IO.puts(
      "  -> stop verdicts #{stops}/#{length(rows)}, errors #{errors}, " <>
        "latency p50=#{median(latencies)}ms max=#{List.last(latencies)}ms"
    )
  end

  # ── Layer 2: the whole system ───────────────────────────────────────

  def system_layer(label, command, expect, opts) do
    IO.puts("\n== system: #{label} (expect #{expect}): #{command}")

    results =
      for run <- 1..opts[:runs] do
        result = run_once(command, opts)
        print_run(run, result, expect)
        result
      end

    passed = Enum.count(results, &(&1.outcome == expect))
    IO.puts("  -> #{passed}/#{length(results)} runs as expected (#{expect})")
    passed == length(results)
  end

  defp run_once(command, opts) do
    {:ok, config} =
      Tackle.Config.new(
        providers: [WatchdogLive.Script, WatchdogLive.Recorder],
        model: "script/bash",
        tools: [Tackle.Tools.Bash],
        system_prompt: "Benchmark agent.",
        context: %{cwd: File.cwd!()},
        llm_opts: [bench_command: command],
        watchdog: [
          model: opts[:model_ref],
          after_seconds: opts[:after_seconds],
          threshold: opts[:threshold]
        ]
      )

    {:ok, scope} =
      Tackle.Runtime.start_scope(
        ScopeSpec.new!(
          backend: Tackle.Runtime.RootBackend,
          root_spec: AgentSpec.new!(name: "root", config: config)
        )
      )

    try do
      {:ok, snapshot} = Tackle.Runtime.subscribe(scope.root_agent_ref)
      {:ok, turn_id} = Tackle.Runtime.submit(scope.root_agent_ref, "run it")
      started = System.monotonic_time(:millisecond)
      deadline = started + opts[:limit_ms]
      observe(snapshot.session_id, turn_id, started, deadline, scope, %{decisions: []})
    after
      Tackle.Runtime.stop_scope(scope.scope_ref)
    end
  end

  defp observe(session_id, turn_id, started, deadline, scope, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:decision, _request, result, latency} ->
        at = System.monotonic_time(:millisecond) - started
        {verdict, p, top} = summarize(result)
        decision = %{at: at, latency: latency, verdict: verdict, p: p, top: top}

        observe(session_id, turn_id, started, deadline, scope, %{
          acc
          | decisions: [decision | acc.decisions]
        })

      {:tackle_event, ^session_id, ^turn_id, %Event{type: :tool_error, data: data}} ->
        at = System.monotonic_time(:millisecond) - started
        message = if is_binary(data[:error]), do: data.error, else: inspect(data)
        outcome = if message =~ "stopped by watchdog", do: :stopped, else: :tool_error
        finish(acc, outcome, at, message)

      {:tackle_event, ^session_id, ^turn_id, %Event{type: :tool_end}} ->
        finish(acc, :completed, System.monotonic_time(:millisecond) - started, nil)

      _other ->
        observe(session_id, turn_id, started, deadline, scope, acc)
    after
      remaining ->
        Tackle.Runtime.cancel_turn(scope.root_agent_ref)
        finish(acc, :not_stopped, System.monotonic_time(:millisecond) - started, nil)
    end
  end

  defp finish(acc, outcome, at, message) do
    %{outcome: outcome, at: at, message: message, decisions: Enum.reverse(acc.decisions)}
  end

  defp print_run(run, result, expect) do
    mark = if result.outcome == expect, do: "ok  ", else: "FAIL"

    IO.puts(
      "  run #{run}: #{mark} #{result.outcome} after #{Float.round(result.at / 1_000, 1)}s, " <>
        "#{length(result.decisions)} decision(s)"
    )

    for d <- result.decisions do
      IO.puts(
        "    check at #{pad(Float.round(d.at / 1_000, 1), 6)}s  #{pad(d.verdict, 21)} " <>
          "p=#{fmt(d.p)}  #{pad(d.latency, 5)}ms  #{d.top}"
      )
    end

    if result.message,
      do: IO.puts("    message: #{result.message |> String.split("\n") |> List.last()}")
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  def flush_decisions do
    receive do
      {:decision, _request, _result, _latency} -> flush_decisions()
    after
      0 -> :ok
    end
  end

  defp summarize({:ok, %{answers: %{"verdict" => %Answer{} = answer}}}) do
    top =
      answer.probabilities
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(3)
      |> Enum.map_join(" ", fn {choice, p} -> "#{choice}=#{fmt(p)}" end)

    {answer.choice, Answer.choice_probability(answer) || 0.0, top}
  end

  defp summarize({:error, reason}), do: {"ERROR", 0.0, inspect(reason, limit: 5)}
  defp summarize(other), do: {"ERROR", 0.0, inspect(other, limit: 5)}

  defp median([]), do: 0
  defp median(sorted), do: Enum.at(sorted, div(length(sorted), 2))
  defp fmt(p), do: :erlang.float_to_binary(p / 1, decimals: 2)
  defp pad(value, width), do: value |> to_string() |> String.pad_trailing(width)
end

Process.register(self(), :watchdog_live)
model_ref = "ollama/#{model}"

IO.puts(
  "Elixir #{System.version()}, OTP #{System.otp_release()}; model #{model_ref} at #{base_url}; " <>
    "after=#{after_seconds}s threshold=#{threshold} runs=#{runs}"
)

WatchdogLive.model_layer(model_ref, [5, 10, 20, 30, 60, 120, 300], threshold)

opts = [
  model_ref: model_ref,
  after_seconds: after_seconds,
  threshold: threshold,
  runs: runs,
  limit_ms: limit_ms
]

tick_ok? =
  WatchdogLive.system_layer(
    "tick loop",
    "while true; do echo tick; sleep 1; done",
    :stopped,
    opts
  )

control_ok? =
  WatchdogLive.system_layer(
    "finite control",
    "for i in $(seq 1 #{after_seconds * 2}); do echo \"step $i\"; sleep 1; done",
    :completed,
    opts
  )

IO.puts(
  "\nRESULT: tick loop #{if tick_ok?, do: "PASS", else: "FAIL"}, " <>
    "control #{if control_ok?, do: "PASS", else: "FAIL"}"
)
