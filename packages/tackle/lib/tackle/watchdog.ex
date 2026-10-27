defmodule Tackle.Watchdog do
  @moduledoc """
  Per-session service that stops `bash` commands which are stuck.

  `Tackle.Runtime.RootBackend.services/2` starts one watchdog beside every
  session (root, subagent, or workflow child) whose config enables it (see
  `Tackle.Config.Watchdog`). It runs under that agent's
  `Tackle.Runtime.ServiceSupervisor`, so a crashing watchdog never affects the
  agent, and it finds the agent only through its `Tackle.Runtime.AgentRef`.

  ## Behaviour

    1. It subscribes to its session while starting, so it sees the agent's
       first turn. A session refuses subscriptions during a turn; after a
       restart mid-turn the watchdog retries on a timer.
    2. Each `bash` `:tool_start` is tracked with a bounded digest of its output
       (`Tackle.Watchdog.Digest`); `:tool_progress` updates it and the call's
       end drops it. Commands with an explicit `timeout` are skipped: the agent
       already said how long they may run.
    3. After `after_seconds` the decision model answers one choice question:
       `progressing`, `long_running_service`, `waiting_for_input`,
       `infinite_loop`, or `stalled`. Healthy verdicts double the delay before
       the next check, so long builds are rarely re-checked.
    4. A stop verdict at or above `threshold` cancels just that call through
       `Tackle.Runtime.cancel_tool_call/3`; the agent receives the reason as the
       command's error and the turn continues.
    5. A failing decision model never stops anything: the watchdog logs one
       warning and keeps watching, backing off like a healthy verdict.

  Decision calls run as unlinked tasks under the service task supervisor, one
  at a time, so a slow model request never blocks the watchdog.
  `Tackle.Lib.Decision.ask/4` checks every answer and turns a crashing adapter
  into an error, so only a killed task still needs handling.
  Their usage is accumulated for diagnostics only; it is never counted against
  any token budget.
  """

  use GenServer

  require Logger

  alias Tackle.Config.Watchdog, as: Settings
  alias Tackle.Lib.Decision
  alias Tackle.Lib.Decision.{Answer, Question, Result}
  alias Tackle.Lib.{Event, Usage}
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Registry
  alias Tackle.StatusRedaction
  alias Tackle.Watchdog.Digest

  @tool_name "bash"
  @stop_prefix "Command stopped by watchdog after "
  @verdict "verdict"
  @stop_verdicts %{
    "waiting_for_input" => "likely waiting for interactive input",
    "infinite_loop" => "likely infinite loop",
    "stalled" => "likely stalled"
  }
  @end_events [:tool_execution_end, :tool_end, :tool_error]
  @max_interval_ms :timer.minutes(16)
  @subscribe_retry_ms 1_000
  @decision_timeout_ms 60_000
  @decision_grace_ms 5_000

  @type option ::
          {:agent_ref, AgentRef.t()}
          | {:task_supervisor, Supervisor.supervisor()}
          | {:settings, Settings.t()}
          | {:decision_opts, keyword()}

  @doc """
  Starts a watchdog for one agent.

  Options are `:agent_ref`, `:task_supervisor` (the agent's service
  `Task.Supervisor`), `:settings` (`Tackle.Config.Watchdog`), and
  `:decision_opts`, passed to `Tackle.Lib.Decision.ask/4` (for example a
  `:receive_timeout`). The selection already carries its provider's settings.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    agent_ref = Keyword.fetch!(opts, :agent_ref)
    GenServer.start_link(__MODULE__, opts, name: Registry.service_name(agent_ref, __MODULE__))
  end

  @doc "Whether a watchdog is currently running for `agent_ref`."
  @spec running?(AgentRef.t()) :: boolean()
  def running?(%AgentRef{} = agent_ref),
    do: match?({:ok, _pid}, Registry.service(agent_ref, __MODULE__))

  @doc """
  Whether the watchdog watches a tool call with this name and arguments.

  Only `bash` calls are watched, and only without an explicit `timeout`: a
  timeout already says how long the command may run.
  """
  @spec watches?(String.t() | nil, term()) :: boolean()
  def watches?(@tool_name, arguments) when is_map(arguments) do
    is_binary(argument(arguments, "command", :command)) and
      is_nil(argument(arguments, "timeout", :timeout))
  end

  def watches?(_name, _arguments), do: false

  @doc """
  Whether a tool error reports a command stopped by the watchdog.

  The stop message is the last line of the stopped command's error output.
  """
  @spec stopped?(term()) :: boolean()
  def stopped?(text) when is_binary(text) do
    text
    |> String.trim_trailing()
    |> String.split("\n")
    |> List.last()
    |> String.starts_with?(@stop_prefix)
  end

  def stopped?(_text), do: false

  @doc "The question asked of the decision model about one running command."
  @spec question() :: Question.t()
  def question do
    Question.choice(
      @verdict,
      "A coding agent ran this shell command in the foreground and is blocked until it exits. " <>
        "Judge from its runtime and recent output whether it will finish on its own.",
      %{
        "progressing" =>
          "Doing finite work that is advancing toward completion, such as build, test, " <>
            "install, or download output.",
        "long_running_service" =>
          "An intentionally started server, watcher, or daemon that waits for requests or " <>
            "file changes and never exits by itself.",
        "waiting_for_input" =>
          "Blocked on interactive input such as a prompt, menu, pager, editor, or confirmation.",
        "infinite_loop" =>
          "A loop that repeats the same output or retries the same action forever without " <>
            "getting closer to done.",
        "stalled" => "Hung: no output for a long time and no sign of progress."
      }
    )
  end

  @impl true
  def init(opts) do
    state = %{
      agent_ref: Keyword.fetch!(opts, :agent_ref),
      task_supervisor: Keyword.fetch!(opts, :task_supervisor),
      settings: Keyword.fetch!(opts, :settings),
      decision_opts: Keyword.get(opts, :decision_opts, []),
      subscribed?: false,
      calls: %{},
      timer: nil,
      inflight: nil,
      warned?: false,
      usage: nil
    }

    case subscribe(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, {:subscribe_failed, reason}}
    end
  end

  # Tracked commands and their output, the decision model's selection, and
  # the decision options may carry secrets; crash reports and
  # `:sys.get_status/1` show only call ids, timing, and option keys.
  @impl true
  def format_status(status), do: StatusRedaction.format_status(status, &redact_state/1)

  defp redact_state(%{calls: calls, settings: %Settings{} = settings} = state) do
    %{
      state
      | calls: Map.new(calls, fn {id, call} -> {id, Map.delete(call, :digest)} end),
        settings: Map.take(settings, [:model_ref, :after_seconds, :threshold]),
        decision_opts: StatusRedaction.keys(state.decision_opts)
    }
  end

  defp redact_state(state), do: state

  @impl true
  def handle_info(:subscribe, state) do
    case subscribe(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:stop, {:subscribe_failed, reason}, state}
    end
  end

  def handle_info({:tackle_event, _session_id, _turn_id, %Event{} = event}, state),
    do: {:noreply, event |> observe(state) |> schedule()}

  def handle_info({finished, _session_id, _turn_id, _result}, state)
      when finished in [:tackle_turn_finished, :tackle_turn_failed],
      do: {:noreply, schedule(%{state | calls: %{}})}

  def handle_info(:check, state),
    do: {:noreply, state |> Map.put(:timer, nil) |> check() |> schedule()}

  def handle_info({ref, result}, %{inflight: %{task: %Task{ref: ref}} = inflight} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> settle(inflight) |> decided(inflight.call_id, result) |> schedule()}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{inflight: %{task: %Task{ref: ref}} = inflight} = state
      ) do
    state = state |> settle(inflight) |> decided(inflight.call_id, {:error, {:crashed, reason}})
    {:noreply, schedule(state)}
  end

  def handle_info(
        {:decision_timeout, ref},
        %{inflight: %{task: %Task{ref: ref}} = inflight} = state
      ) do
    Task.shutdown(inflight.task, :brutal_kill)
    state = state |> settle(inflight) |> decided(inflight.call_id, {:error, :timeout})
    {:noreply, schedule(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Subscription ──────────────────────────────────────────────────────

  defp subscribe(state) do
    case Runtime.subscribe(state.agent_ref) do
      {:ok, _snapshot} ->
        {:ok, %{state | subscribed?: true}}

      :ok ->
        {:ok, %{state | subscribed?: true}}

      {:error, :turn_in_progress} ->
        Process.send_after(self(), :subscribe, @subscribe_retry_ms)
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Tracking ──────────────────────────────────────────────────────────

  defp observe(%Event{type: :tool_start, data: %{name: name} = data}, state) do
    arguments = Map.get(data, :arguments) || %{}
    id = Map.get(data, :tool_call_id)

    if is_binary(id) and watches?(name, arguments),
      do: track(state, id, argument(arguments, "command", :command)),
      else: state
  end

  defp observe(%Event{type: :tool_progress, data: %{tool_call_id: id, delta: delta}}, state)
       when is_map_key(state.calls, id) and is_binary(delta) do
    update_in(state.calls[id].digest, &Digest.append(&1, delta, now()))
  end

  defp observe(%Event{type: type, data: %{tool_call_id: id}}, state) when type in @end_events,
    do: %{state | calls: Map.delete(state.calls, id)}

  defp observe(%Event{}, state), do: state

  defp track(state, id, command) do
    interval = Settings.after_ms(state.settings)
    now = now()

    call = %{
      digest: Digest.new(command, now),
      interval_ms: interval,
      next_check_at: now + interval
    }

    %{state | calls: Map.put(state.calls, id, call)}
  end

  # Provider arguments are decoded JSON with string keys; accept atom keys from
  # hosts that build calls by hand.
  defp argument(arguments, key, atom_key),
    do: Map.get(arguments, key, Map.get(arguments, atom_key))

  # ── Checks ────────────────────────────────────────────────────────────

  defp check(%{inflight: nil} = state) do
    now = now()

    state.calls
    |> Enum.filter(fn {_id, call} -> call.next_check_at <= now end)
    |> Enum.min_by(fn {_id, call} -> call.next_check_at end, fn -> nil end)
    |> case do
      nil -> state
      {id, call} -> start_decision(state, id, Digest.state(call.digest, now))
    end
  end

  defp check(state), do: state

  defp start_decision(state, id, observed) do
    %Settings{selection: selection} = state.settings
    opts = Keyword.put_new(state.decision_opts, :receive_timeout, @decision_timeout_ms)

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Decision.ask(selection, observed, [question()], opts)
      end)

    # The adapter enforces its receive timeout; the timer only reaps a request
    # that ignores it, after a grace no longer than the timeout itself.
    timeout = Keyword.fetch!(opts, :receive_timeout)

    timer =
      Process.send_after(
        self(),
        {:decision_timeout, task.ref},
        timeout + min(timeout, @decision_grace_ms)
      )

    %{state | inflight: %{task: task, timer: timer, call_id: id}}
  catch
    :exit, reason -> decided(state, id, {:error, {:task_supervisor_unavailable, reason}})
  end

  defp settle(state, inflight) do
    Process.cancel_timer(inflight.timer)
    %{state | inflight: nil}
  end

  # `Tackle.Lib.Decision.ask/4` returns only results that answer the verdict
  # question with one of its options and probabilities in 0..1, and turns
  # adapter crashes into errors.
  defp decided(state, id, {:ok, %Result{answers: %{@verdict => answer}, usage: usage}}) do
    state = %{state | usage: Usage.aggregate([state.usage, usage])}
    # Without a reported probability the verdict cannot reach the threshold.
    verdict(state, id, answer.choice, Answer.choice_probability(answer) || 0)
  end

  defp decided(state, id, {:error, reason}) do
    state |> warn_once(reason) |> back_off(id)
  end

  defp verdict(state, id, choice, probability) do
    cond do
      not Map.has_key?(state.calls, id) ->
        state

      Map.has_key?(@stop_verdicts, choice) and probability >= state.settings.threshold ->
        stop(state, id, choice, probability)

      Map.has_key?(@stop_verdicts, choice) ->
        # A suspicious but uncertain verdict is re-checked without backing off.
        reschedule(state, id, state.calls[id].interval_ms)

      true ->
        back_off(state, id)
    end
  end

  defp back_off(state, id) do
    case Map.fetch(state.calls, id) do
      {:ok, call} -> reschedule(state, id, min(call.interval_ms * 2, @max_interval_ms))
      :error -> state
    end
  end

  defp reschedule(state, id, interval) do
    update_in(state.calls[id], &%{&1 | interval_ms: interval, next_check_at: now() + interval})
  end

  defp stop(state, id, choice, probability) do
    %{digest: digest} = Map.fetch!(state.calls, id)
    message = stop_message(digest, choice, probability)

    case Runtime.cancel_tool_call(state.agent_ref, id, message) do
      # Commands may carry secrets, such as a bearer token; log the call id.
      :ok ->
        Logger.info("watchdog stopped tool call #{id} for #{inspect(state.agent_ref)}: #{choice}")

      {:error, reason} ->
        Logger.warning(
          "watchdog could not stop tool call #{id}: #{StatusRedaction.reason(reason)}"
        )
    end

    %{state | calls: Map.delete(state.calls, id)}
  end

  @doc false
  @spec stop_message(Digest.t(), String.t(), number(), integer()) :: String.t()
  def stop_message(%Digest{} = digest, choice, probability, now \\ now()) do
    @stop_prefix <>
      "#{format_duration(Digest.elapsed_ms(digest, now))}: " <>
      "#{Map.fetch!(@stop_verdicts, choice)} (p=#{format_probability(probability)}). " <>
      "If this is expected to run long, re-run it with an explicit timeout or in the background."
  end

  defp warn_once(%{warned?: true} = state, _reason), do: state

  defp warn_once(state, reason) do
    Logger.warning(
      "watchdog decision model #{state.settings.model_ref} failed: " <>
        "#{StatusRedaction.reason(reason)}; " <>
        "commands will not be stopped until it answers"
    )

    %{state | warned?: true}
  end

  # One timer for the earliest due check; none while a decision is in flight,
  # because its result reschedules.
  defp schedule(%{inflight: nil} = state) do
    state = cancel_timer(state)

    case Enum.min_by(Map.values(state.calls), & &1.next_check_at, fn -> nil end) do
      nil ->
        state

      call ->
        delay = max(call.next_check_at - now(), 0)
        %{state | timer: Process.send_after(self(), :check, delay)}
    end
  end

  defp schedule(state), do: cancel_timer(state)

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp format_duration(ms) do
    seconds = div(ms, 1_000)

    cond do
      seconds >= 3_600 -> "#{div(seconds, 3_600)}h#{pad(div(rem(seconds, 3_600), 60))}m"
      seconds >= 60 -> "#{div(seconds, 60)}m#{pad(rem(seconds, 60))}s"
      true -> "#{seconds}s"
    end
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp format_probability(probability),
    do: :erlang.float_to_binary(probability / 1, decimals: 2)

  defp now, do: System.monotonic_time(:millisecond)
end
