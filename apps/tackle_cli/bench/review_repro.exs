# Live reproduction of `review_changes` failures, with tracing. NOT a synthetic
# baseline: it uses your real configuration, credentials, and models, and the
# review costs what a normal review costs.
#
#   cd apps/tackle_cli
#   mix run --no-start bench/review_repro.exs [options] 2>&1 | tee /tmp/review_repro.log
#
# It composes the scope the interactive shell composes (same catalog, profiles,
# jail, MCP tools, and limits; root session not durable) and runs one review in
# one of three ways, so the paths can be compared:
#
#   --mode agent  (default) the root agent is prompted to call `review_changes`,
#                 so the tool runs mid-turn exactly as when the agent invokes it
#   --mode tool   `review_changes` is called directly with the root agent's own
#                 tool context, without a root turn
#   --mode cli    `Tackle.Review.run/2` from the root agent ref, as `tackle
#                 review` and `/review` do (concurrency: the root agent's
#                 max_children_per_agent unless --concurrency)
#
# Options:
#   --range RANGE        revision range (default: the branch's changes)
#   --staged             review the index
#   --profile NAME       quiet | default | assertive (default: quiet)
#   --model REF          root model; the review stages inherit it (default: config)
#   --thinking LEVEL     root thinking level (default: config)
#   --no-stream          compose like `tackle review`/`tackle -p` (llm_stream off);
#                        the default streams like the interactive shell
#   --concurrency N      cli mode only: detector/verifier runs in flight
#   --cwd DIR            repository to review (default: the git toplevel)
#   --stall SECONDS      silence before a run's processes are dumped (default 45)
#   --limit SECONDS      give up after this long (default 1200)
#
# What it prints, timestamped from the start:
#
#   * every delegated run (detector, verifier) when it is admitted, with its
#     unit and model, and each of its events: steps, tool calls with their
#     arguments, tool results, retries, errors; streamed deltas are counted;
#   * admission refusals (`max_children_per_agent`, `max_agents_per_fleet`)
#     counted per reason, and a scope status line every 15 seconds;
#   * for a run silent for --stall seconds, and again when its idle timeout
#     fires: the stack of every process of that run (session, turn task, tool
#     tasks), and the OS processes behind any open port, so the dump shows
#     where it waits: a model request, a tool, a bash command;
#   * each run's outcome, then a summary table and the review's result.
#
# Nothing in the harness is modified: runs are observed by tracing
# `Tackle.Runtime.Request`, the helper that owns every delegated run, and
# `Tackle.Runtime.request_agent/4`.

defmodule ReviewRepro.Tracer do
  @moduledoc false
  # Receives call traces of the request helpers and keeps one record per run.

  use GenServer

  alias Tackle.AgentScope.Coordinator
  alias Tackle.Lib.Event
  alias Tackle.Runtime.Request

  @tick_ms 2_000
  @status_ms 15_000
  @redump_ms 60_000
  @stream_report_ms 15_000
  @counted [:message_delta, :provider_event, :tool_progress, :usage, :narration]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Prints the per-run summary table."
  def summary, do: GenServer.call(__MODULE__, :summary, 30_000)

  @doc "Stops tracing."
  def stop do
    :erlang.trace_pattern({:_, :_, :_}, false, [:local])
    :erlang.trace(:all, false, [:call])
    GenServer.stop(__MODULE__)
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    state = %{
      t0: Keyword.fetch!(opts, :t0),
      scope_ref: Keyword.get(opts, :scope_ref),
      stall_ms: Keyword.fetch!(opts, :stall_ms),
      runs: %{},
      order: [],
      requests: %{},
      refusals: %{},
      refusals_reported: %{},
      last_status: 0
    }

    me = self()
    # trace_pattern only applies to loaded modules, and `mix run` loads lazily.
    Code.ensure_loaded!(Request)
    Code.ensure_loaded!(Tackle.Runtime)
    :erlang.trace(:all, true, [:call, {:tracer, me}])
    :erlang.trace(me, false, [:call])

    matched =
      [
        :erlang.trace_pattern({Request, :handle_continue, 2}, true, [:local]),
        :erlang.trace_pattern({Request, :handle_info, 2}, true, [:local]),
        :erlang.trace_pattern({Request, :settle, 2}, true, [:local]),
        :erlang.trace_pattern(
          {Tackle.Runtime, :request_agent, 4},
          [{:_, [], [{:return_trace}]}],
          [:local]
        )
      ]

    if Enum.any?(matched, &(&1 == 0)),
      do: IO.puts("WARNING: some trace patterns matched nothing: #{inspect(matched)}")

    :timer.send_interval(@tick_ms, :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:summary, _from, state) do
    print_refusals(state, true)
    log(state, "SUMMARY of #{length(state.order)} delegated run(s)")

    for pid <- Enum.reverse(state.order) do
      run = state.runs[pid]
      ended = run.ended_at || now()

      IO.puts(
        "  #{pad(run.label, 44)} #{pad(run.model || "?", 28)} " <>
          "#{pad(seconds(ended - run.started_at), 7)} events=#{pad(run.events, 4)} " <>
          "deltas=#{pad(run.counts[:message_delta] || 0, 5)} " <>
          "outcome=#{run.outcome || "(still running)"}  last: #{run.last_desc}"
      )
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:trace, pid, :call, {Request, :handle_continue, [:setup, rstate]}}, state) do
    {:noreply, ensure_run(state, pid, rstate)}
  end

  def handle_info({:trace, pid, :call, {Request, :handle_info, [message, rstate]}}, state) do
    state = ensure_run(state, pid, rstate)

    state =
      case message do
        {:tackle_event, _session_id, _turn_id, %Event{} = event} -> event(state, pid, event)
        {:tackle_runtime_event, %Event{} = event} -> event(state, pid, event)
        {:timeout, _timer, {:request_timeout, :idle}} -> idle_timeout(state, pid)
        {:timeout, _timer, {:request_timeout, :await}} -> note(state, pid, "await timeout fired")
        {:tackle_runtime_terminal, _run_id, _result} -> note(state, pid, "terminal result")
        {:DOWN, _ref, :process, _down, reason} -> note(state, pid, "DOWN #{short(reason)}")
        {:runtime_cancel, reason} -> note(state, pid, "cancel requested: #{short(reason)}")
        _other -> state
      end

    {:noreply, state}
  end

  def handle_info({:trace, pid, :call, {Request, :settle, [rstate, outcome]}}, state) do
    state = ensure_run(state, pid, rstate)
    run = state.runs[pid]

    if run.outcome do
      {:noreply, state}
    else
      text = outcome_text(outcome)
      log(state, "#{run.label}  SETTLED #{text}  (#{seconds(now() - run.started_at)})")
      run = %{run | outcome: text, ended_at: now()}
      {:noreply, put_in(state.runs[pid], run)}
    end
  end

  def handle_info(
        {:trace, pid, :call, {Tackle.Runtime, :request_agent, [_req, spec, _p, _o]}},
        state
      ) do
    name = if is_binary(spec), do: spec, else: Map.get(spec, :name)
    {:noreply, put_in(state.requests[pid], name)}
  end

  def handle_info(
        {:trace, pid, :return_from, {Tackle.Runtime, :request_agent, 4}, result},
        state
      ) do
    name = Map.get(state.requests, pid, "?")
    state = %{state | requests: Map.delete(state.requests, pid)}

    state =
      case result do
        {:ok, _run_ref} ->
          state

        {:error, reason} ->
          key = {name, refusal_key(reason)}
          count = Map.get(state.refusals, key, 0)
          if count == 0, do: log(state, "request for #{name} refused: #{short(reason)}")
          %{state | refusals: Map.put(state.refusals, key, count + 1)}
      end

    {:noreply, state}
  end

  def handle_info(:tick, state) do
    state = state |> report_streams() |> check_stalls()
    state = print_refusals(state, false)

    if now() - state.last_status >= @status_ms do
      print_status(state)
      {:noreply, %{state | last_status: now()}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- runs -------------------------------------------------------------------

  defp ensure_run(state, pid, rstate) do
    case state.runs do
      %{^pid => run} ->
        put_in(state.runs[pid], %{
          run
          | session_pid: Map.get(rstate, :session_pid) || run.session_pid
        })

      _runs ->
        run = %{
          label: label(rstate),
          model: rstate.run_ref && rstate.run_ref.model_ref,
          agent_id: rstate.agent_ref && rstate.agent_ref.agent_id,
          session_pid: Map.get(rstate, :session_pid),
          started_at: now(),
          last_at: now(),
          last_desc: "(admitted)",
          events: 0,
          counts: %{},
          stream_reported_at: now(),
          stream_reported: %{},
          dumped_at: nil,
          outcome: nil,
          ended_at: nil
        }

        log(
          state,
          "#{run.label}  ADMITTED model=#{run.model || "?"} timeout=#{timeout_text(rstate)} " <>
            "agent=#{run.agent_id} helper=#{inspect(pid)}"
        )

        %{state | runs: Map.put(state.runs, pid, run), order: [pid | state.order]}
    end
  end

  defp label(rstate) do
    profile = Map.get(rstate, :profile) || "run"
    prompt = Map.get(rstate, :prompt) || ""

    detail =
      case Regex.scan(~r/<unit id="([^"]+)"/, prompt) do
        [] -> if String.starts_with?(prompt, "Verify"), do: "verify", else: nil
        [[_match, id]] -> id
        many -> "#{length(many)} units: " <> Enum.map_join(many, ",", &List.last/1)
      end

    if detail, do: "#{profile}[#{detail}]", else: profile
  end

  defp timeout_text(%{timeout: ms}) when is_integer(ms), do: seconds(ms)
  defp timeout_text(%{timeout: other}), do: inspect(other)
  defp timeout_text(_rstate), do: "?"

  defp event(state, pid, %Event{type: type} = event) do
    run = state.runs[pid]
    auxiliary? = Event.auxiliary?(event)
    run = %{run | events: run.events + 1, counts: Map.update(run.counts, type, 1, &(&1 + 1))}

    run =
      if type in @counted do
        if auxiliary?, do: run, else: %{run | last_at: now(), last_desc: "#{type}"}
      else
        desc = describe(event)
        log(state, "#{run.label}  #{desc}#{if auxiliary?, do: " (auxiliary)", else: ""}")
        if auxiliary?, do: run, else: %{run | last_at: now(), last_desc: desc, dumped_at: nil}
      end

    put_in(state.runs[pid], run)
  end

  defp note(state, pid, text) do
    log(state, "#{state.runs[pid].label}  #{text}")
    state
  end

  defp idle_timeout(state, pid) do
    run = state.runs[pid]

    log(
      state,
      "#{run.label}  IDLE TIMEOUT fired; silent #{seconds(now() - run.last_at)} since: #{run.last_desc}"
    )

    dump(state, pid, run)
    put_in(state.runs[pid].dumped_at, now())
  end

  defp report_streams(state) do
    Enum.reduce(state.runs, state, fn {pid, run}, state ->
      if is_nil(run.outcome) and now() - run.stream_reported_at >= @stream_report_ms do
        new =
          for type <- @counted,
              delta = Map.get(run.counts, type, 0) - Map.get(run.stream_reported, type, 0),
              delta > 0,
              do: "#{type}×#{delta}"

        if new != [], do: log(state, "#{run.label}  … #{Enum.join(new, " ")}")
        run = %{run | stream_reported_at: now(), stream_reported: run.counts}
        put_in(state.runs[pid], run)
      else
        state
      end
    end)
  end

  defp check_stalls(state) do
    Enum.reduce(state.runs, state, fn {pid, run}, state ->
      silent = now() - run.last_at

      due? =
        is_nil(run.outcome) and silent >= state.stall_ms and
          (is_nil(run.dumped_at) or now() - run.dumped_at >= @redump_ms)

      if due? do
        log(state, "#{run.label}  STALLED: silent #{seconds(silent)} since: #{run.last_desc}")
        dump(state, pid, run)
        put_in(state.runs[pid].dumped_at, now())
      else
        state
      end
    end)
  end

  defp print_refusals(state, final?) do
    changed =
      Enum.filter(state.refusals, fn {key, count} ->
        count != Map.get(state.refusals_reported, key, 0)
      end)

    if changed != [] and (final? or rem(div(now(), @tick_ms), 5) == 0) do
      text = Enum.map_join(changed, ", ", fn {{name, reason}, n} -> "#{name} #{reason}×#{n}" end)
      log(state, "admission refusals so far: #{text}")
      %{state | refusals_reported: state.refusals}
    else
      state
    end
  end

  defp print_status(%{scope_ref: nil}), do: :ok

  defp print_status(state) do
    with {:ok, coordinator} <- Tackle.Runtime.Registry.coordinator(state.scope_ref),
         %{} = snapshot <- Coordinator.snapshot(coordinator) do
      agents =
        snapshot.agents
        |> Map.values()
        |> Enum.frequencies_by(&"#{&1.name}:#{&1.status}")
        |> Enum.map_join(" ", fn {key, n} -> "#{key}×#{n}" end)

      live = Enum.count(state.runs, fn {_pid, run} -> is_nil(run.outcome) end)

      log(
        state,
        "scope: agents=#{snapshot.agent_count} active_turns=#{snapshot.active_turns} " <>
          "live_runs=#{live} limits=#{limits_text(snapshot.limits)} [#{agents}]"
      )
    end
  catch
    kind, reason ->
      log(state, "scope status unavailable: #{Exception.format_banner(kind, reason)}")
  end

  defp limits_text(%{} = limits) do
    "children≤#{limits.max_children_per_agent} fleet≤#{limits.max_agents_per_fleet} " <>
      "turns≤#{limits.max_concurrent_turns}"
  end

  defp limits_text(other), do: inspect(other)

  # -- dumps ------------------------------------------------------------------

  defp dump(state, pid, run) do
    family = family([pid, run.session_pid, turn_task(run.session_pid)])
    log(state, "#{run.label}  ── dump: #{length(family)} process(es) ──")

    for process <- family, info = process_info(process), info != nil do
      IO.puts("    #{inspect(process)} #{info.name} status=#{info.status} queue=#{info.queue}")

      info.stack
      |> Enum.take(12)
      |> Enum.each(&IO.puts("        " <> Exception.format_stacktrace_entry(&1)))

      for port <- info.ports, do: dump_port(port)
    end

    IO.puts("    ── end of dump ──")
  end

  # The turn runs in a task under the scope's work supervisor, so its
  # `$ancestors` name the supervisor, not the session; the session's state
  # holds it. Tool tasks list the turn task among their `$callers`.
  defp turn_task(nil), do: nil

  defp turn_task(session_pid) do
    case :sys.get_state(session_pid, 2_000) do
      %{active_turn: %{task: %{pid: pid}}} when is_pid(pid) -> pid
      _other -> nil
    end
  catch
    :exit, _reason -> nil
  end

  # The run's helper and session, and every process started on their behalf
  # (`$callers`/`$ancestors`), transitively: turn task, tool tasks, review
  # pool tasks.
  defp family(roots) do
    roots = roots |> Enum.reject(&is_nil/1) |> MapSet.new()
    dictionaries = Map.new(Process.list(), &{&1, relatives(&1)})
    grow(roots, dictionaries, 8) |> Enum.sort()
  end

  defp grow(set, _dictionaries, 0), do: set

  defp grow(set, dictionaries, rounds) do
    next =
      Enum.reduce(dictionaries, set, fn {pid, relatives}, acc ->
        if not MapSet.member?(acc, pid) and Enum.any?(relatives, &MapSet.member?(acc, &1)),
          do: MapSet.put(acc, pid),
          else: acc
      end)

    if MapSet.size(next) == MapSet.size(set), do: set, else: grow(next, dictionaries, rounds - 1)
  end

  defp relatives(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        (Keyword.get(dictionary, :"$callers", []) ++ Keyword.get(dictionary, :"$ancestors", []))
        |> Enum.filter(&is_pid/1)

      nil ->
        []
    end
  end

  defp process_info(pid) do
    keys = [
      :registered_name,
      :current_stacktrace,
      :message_queue_len,
      :status,
      :dictionary,
      :links
    ]

    case Process.info(pid, keys) do
      nil ->
        nil

      info ->
        initial = Keyword.get(info[:dictionary], :"$initial_call")

        name =
          case info[:registered_name] do
            [] -> if initial, do: inspect(initial), else: ""
            name -> inspect(name)
          end

        %{
          name: name,
          status: info[:status],
          queue: info[:message_queue_len],
          stack: info[:current_stacktrace],
          ports: Enum.filter(info[:links], &is_port/1)
        }
    end
  end

  defp dump_port(port) do
    case Port.info(port) do
      nil ->
        :ok

      info ->
        os_pid = info[:os_pid]
        IO.puts("        port #{inspect(port)} #{inspect(info[:name])} os_pid=#{inspect(os_pid)}")
        if is_integer(os_pid), do: dump_os_tree(os_pid)
    end
  end

  defp dump_os_tree(os_pid) do
    case System.cmd("ps", ["-eo", "pid=,ppid=,etimes=,stat=,args="], stderr_to_stdout: true) do
      {output, 0} ->
        rows =
          for line <- String.split(output, "\n", trim: true),
              [pid, ppid, etime, stat, args] <- [
                String.split(String.trim(line), ~r/\s+/, parts: 5)
              ],
              do: %{pid: pid, ppid: ppid, etime: etime, stat: stat, args: args}

        tree = descendants(rows, MapSet.new([to_string(os_pid)]))

        for row <- rows, MapSet.member?(tree, row.pid) do
          IO.puts(
            "          os #{row.pid} (#{row.etime}s, #{row.stat}) #{String.slice(row.args, 0, 200)}"
          )
        end

      {output, _status} ->
        IO.puts("          ps failed: #{String.trim(output)}")
    end
  rescue
    error -> IO.puts("          ps unavailable: #{Exception.message(error)}")
  end

  defp descendants(rows, set) do
    next =
      Enum.reduce(
        rows,
        set,
        &if(MapSet.member?(&2, &1.ppid), do: MapSet.put(&2, &1.pid), else: &2)
      )

    if MapSet.size(next) == MapSet.size(set), do: set, else: descendants(rows, next)
  end

  # -- formatting -------------------------------------------------------------

  defp describe(%Event{type: :tool_start, data: data}),
    do: "tool_start #{data[:name]} #{short(data[:arguments], 300)}"

  defp describe(%Event{type: :tool_end, data: data}) do
    result = to_string(data[:result] || "")
    "tool_end #{data[:name]} (#{byte_size(result)} B) #{short(first_line(result), 120)}"
  end

  defp describe(%Event{type: :tool_error, data: data}),
    do: "tool_error #{data[:name]} reason=#{short(data[:reason])} #{short(data[:error], 300)}"

  defp describe(%Event{type: :tool_execution_end, data: data}),
    do: "tool_execution_end #{data[:name] || ""} #{short(Map.drop(data, [:result, :raw]), 160)}"

  defp describe(%Event{type: :step_end, data: data}),
    do:
      "step_end iteration=#{data[:iteration]} model=#{data[:model]} usage=#{short(data[:usage], 200)}"

  defp describe(%Event{type: :message_end, data: data}) do
    message = data[:message]

    case message do
      %{role: role, content: content} = message ->
        calls =
          message |> Map.get(:tool_calls, []) |> List.wrap() |> Enum.map(&Map.get(&1, :name))

        "message_end #{role} #{short(first_line(to_string(content || "")), 120)} calls=#{inspect(calls)}"

      _other ->
        "message_end #{short(Map.keys(data))}"
    end
  end

  defp describe(%Event{type: type, data: data}), do: "#{type} #{short(data, 300)}"

  defp outcome_text(%{status: status, reason: reason} = outcome) do
    message =
      case outcome do
        %{agent_state: %{error: error}} when not is_nil(error) -> " error=#{short(error, 200)}"
        _other -> ""
      end

    "#{status}#{if reason, do: " reason=#{short(reason, 200)}", else: ""}#{message}"
  end

  defp outcome_text(other), do: short(other, 300)

  defp refusal_key({:rejected, reason}), do: inspect(reason)
  defp refusal_key(reason), do: short(reason, 80)

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp short(term, max \\ 160) do
    text = if is_binary(term), do: term, else: inspect(term, limit: 12, printable_limit: max)
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp log(state, text), do: IO.puts("[#{pad(seconds(now() - state.t0), 7)}] #{text}")

  defp now, do: System.monotonic_time(:millisecond)
  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"
  defp pad(value, width), do: value |> to_string() |> String.pad_trailing(width)
end

defmodule ReviewRepro do
  @moduledoc false

  alias Tackle.Lib.Event

  @switches [
    mode: :string,
    range: :string,
    staged: :boolean,
    profile: :string,
    model: :string,
    thinking: :string,
    stream: :boolean,
    concurrency: :integer,
    cwd: :string,
    stall: :integer,
    limit: :integer
  ]

  def main(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if rest != [] or invalid != [] do
      IO.puts(:stderr, "unexpected arguments: #{inspect(rest ++ invalid)}")
      System.halt(2)
    end

    mode = Keyword.get(opts, :mode, "agent")

    unless mode in ["agent", "tool", "cli"] do
      IO.puts(:stderr, "--mode must be agent, tool, or cli")
      System.halt(2)
    end

    File.cd!(Keyword.get_lazy(opts, :cwd, &git_toplevel/0))
    t0 = System.monotonic_time(:millisecond)
    stream? = Keyword.get(opts, :stream, true)

    IO.puts("review_repro mode=#{mode} cwd=#{File.cwd!()} llm_stream=#{stream?}")

    IO.puts(
      "TACKLE_EXEC_LAUNCHER=#{System.get_env("TACKLE_EXEC_LAUNCHER") || "(unset: not jailed)"}"
    )

    case Tackle.CLI.Run.start_ephemeral_scope(opts[:model], opts[:thinking], llm_stream: stream?) do
      {:ok, scope, scope_spec} ->
        try do
          run(mode, scope, scope_spec, opts, t0)
        after
          ReviewRepro.Tracer.stop()
          Tackle.CLI.Run.stop_scope(scope.scope_ref)
        end

      {:error, reason} ->
        IO.puts(:stderr, "could not start the scope: #{inspect(reason)}")
        System.halt(2)
    end
  end

  def run(mode, scope, scope_spec, opts, t0) do
    describe_scope(scope, scope_spec)

    {:ok, _tracer} =
      ReviewRepro.Tracer.start_link(
        t0: t0,
        scope_ref: scope.scope_ref,
        stall_ms: Keyword.get(opts, :stall, 45) * 1_000
      )

    limit = Keyword.get(opts, :limit, 1_200) * 1_000
    args = tool_args(opts)
    IO.puts("review arguments: #{inspect(args)}\n")

    started = System.monotonic_time(:millisecond)
    result = run_mode(mode, scope, scope_spec, args, opts, limit)
    elapsed = System.monotonic_time(:millisecond) - started

    IO.puts("")
    ReviewRepro.Tracer.summary()
    IO.puts("\n=== review finished in #{Float.round(elapsed / 1000, 1)}s ===")
    IO.puts(result)
  end

  defp run_mode("agent", scope, _scope_spec, args, _opts, limit) do
    root = scope.root_agent_ref
    {:ok, snapshot} = Tackle.subscribe(root)
    session_id = snapshot.session_id

    prompt =
      "Call the review_changes tool exactly once with these arguments: " <>
        JSON.encode!(args) <>
        ". Do not call any other tool and do not fix anything. " <>
        "When it returns, reply with exactly: done."

    {:ok, turn_id} = Tackle.submit(root, prompt)
    await_root(session_id, turn_id, System.monotonic_time(:millisecond) + limit, nil)
  end

  defp run_mode("tool", scope, _scope_spec, args, _opts, limit) do
    {:ok, snapshot} = Tackle.Runtime.session_snapshot(scope.root_agent_ref)
    context = snapshot.agent_state.context
    IO.puts("root tool context keys: #{inspect(Map.keys(context) |> Enum.sort())}")

    task = Task.async(fn -> Tackle.Tools.Review.run(args, context) end)

    case Task.yield(task, limit) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, text}} -> text
      {:ok, {:error, message}} -> "TOOL ERROR: " <> message
      {:exit, reason} -> "TOOL CRASHED: #{inspect(reason)}"
      nil -> "GAVE UP after the limit"
    end
  end

  defp run_mode("cli", scope, scope_spec, args, opts, limit) do
    workspace =
      scope_spec.root_spec.config.context
      |> Tackle.Executor.from_context()
      |> Tackle.Executor.workspace()

    {:ok, change} =
      Tackle.Review.Change.load(
        cwd: File.cwd!(),
        workspace: workspace,
        staged: Map.get(args, "staged", false),
        range: Map.get(args, "range")
      )

    review_opts =
      [
        requester: scope.root_agent_ref,
        profiles: scope_spec.profiles,
        profile: String.to_existing_atom(args["profile"]),
        history: nil,
        on_event: &IO.puts("  review event: #{inspect(&1, limit: 6, printable_limit: 160)}")
      ] ++ if(opts[:concurrency], do: [max_concurrency: opts[:concurrency]], else: [])

    task = Task.async(fn -> Tackle.Review.run(change, review_opts) end)

    case Task.yield(task, limit) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} ->
        "blocking=#{length(result.blocking)} optional=#{length(result.optional)} " <>
          "failed_units=#{inspect(result.summary.failed_units, limit: 20)}"

      {:ok, {:error, reason}} ->
        "REVIEW ERROR: #{inspect(reason)}"

      {:exit, reason} ->
        "REVIEW CRASHED: #{inspect(reason)}"

      nil ->
        "GAVE UP after the limit"
    end
  end

  # The root turn's own events: the review_changes call and its result.
  defp await_root(session_id, turn_id, deadline, tool_result) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:tackle_event, ^session_id, ^turn_id, %Event{type: :tool_start, data: data}} ->
        IO.puts("ROOT tool_start #{data[:name]} #{inspect(data[:arguments])}")
        await_root(session_id, turn_id, deadline, tool_result)

      {:tackle_event, ^session_id, ^turn_id, %Event{type: type, data: data}}
      when type in [:tool_end, :tool_error] ->
        IO.puts("ROOT #{type} #{data[:name]}")
        await_root(session_id, turn_id, deadline, data[:result] || data[:error])

      {:tackle_event, ^session_id, ^turn_id, %Event{type: type, data: data}}
      when type in [:error, :retry_scheduled, :retry_start, :retry_end] ->
        IO.puts("ROOT #{type} #{inspect(data, limit: 8)}")
        await_root(session_id, turn_id, deadline, tool_result)

      {:tackle_turn_finished, ^session_id, ^turn_id, {status, _state}} ->
        "root turn #{status}\n\ntool result:\n#{tool_result || "(the root never got a result)"}"

      {:tackle_turn_failed, ^session_id, ^turn_id, reason} ->
        "root turn FAILED: #{inspect(reason)}\n\ntool result:\n#{tool_result}"
    after
      remaining -> "GAVE UP after the limit; tool result so far: #{inspect(tool_result)}"
    end
  end

  defp describe_scope(scope, scope_spec) do
    {:ok, snapshot} = Tackle.Runtime.session_snapshot(scope.root_agent_ref)
    state = snapshot.agent_state
    thinking = Tackle.Thinking.from_llm_opts(state.llm_opts)
    IO.puts("root model=#{state.llm.ref} thinking=#{inspect(thinking)}")

    for {name, profile} <- Enum.sort(scope_spec.profiles),
        name in ["review-detector", "review-verifier"] do
      case if(is_function(profile, 0), do: profile.(), else: {:ok, profile}) do
        {:ok, spec} ->
          IO.puts(
            "profile #{name}: model_source=#{spec.model_source} timeout=#{spec.timeout}ms " <>
              "tools=#{inspect(Enum.map(spec.config.tools, & &1.name()))}"
          )

        other ->
          IO.puts("profile #{name}: unresolved #{inspect(other)}")
      end
    end

    IO.puts("scope limits: #{inspect(scope_spec.limits)}")
  end

  defp tool_args(opts) do
    %{"profile" => Keyword.get(opts, :profile, "quiet")}
    |> then(&if(opts[:range], do: Map.put(&1, "range", opts[:range]), else: &1))
    |> then(&if(opts[:staged], do: Map.put(&1, "staged", true), else: &1))
  end

  defp git_toplevel do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {path, 0} -> String.trim(path)
      _other -> File.cwd!()
    end
  end
end

unless System.get_env("REVIEW_REPRO_NO_MAIN") == "1" do
  ReviewRepro.main(System.argv())
end
