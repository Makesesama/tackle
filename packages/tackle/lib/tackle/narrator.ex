defmodule Tackle.Narrator do
  @moduledoc """
  Root-session service that writes a short live status line for each running
  delegated run.

  `Tackle.Runtime.RootBackend.services/2` starts one narrator beside the root
  session (never beside a subagent or workflow child) when its config enables
  narration (see `Tackle.Config.Narration`). It runs under the root agent's
  `Tackle.Runtime.ServiceSupervisor`, so a crashing narrator never affects the
  agent, and it finds the agent only through its `Tackle.Runtime.AgentRef`.

  ## Behaviour

    1. It subscribes to the root session while starting, retrying on a timer
       when a restart happens mid-turn, like `Tackle.Watchdog`.
    2. It follows the delegated runs the root session forwards: subagents
       (`:subagent_started`, `:subagent_progress`, `:subagent_finished`, with
       the task taken from the `subagent` tool's `prompt` argument) and
       workflow children (`:workflow_progress` `:run_started`, `:run_event`,
       `:run_finished`). Progress of nested runs (a subagent's own subagents
       or workflows) counts toward the top-level run that carries it. Each
       run keeps a bounded `Tackle.Narration.Digest`.
    3. A run is due when it is older than `first_after_seconds`, changed since
       its last narration, and was last narrated at least `interval_seconds`
       ago. The due run narrated longest ago goes first, so concurrent runs
       share the model fairly. At most one model call is in flight; its digest
       is taken when the call starts, so only the newest state is ever sent.
    4. The model's answer is cleaned to one line of at most 100 characters and
       published on the root agent through `Tackle.Runtime.publish_event/2` as
       an auxiliary `:narration` event: `%{run_id: id, tool_call_id: id | nil,
       text: text, auxiliary: true}`. Empty answers and answers with tool calls
       are dropped. Answers for runs that finished meanwhile are discarded.
    5. A failing model never touches the agent: the narrator logs one warning,
       backs off, and keeps watching.

  The root agent's own turn is not narrated. Model calls run as unlinked tasks
  under the service task supervisor; their usage is accumulated for
  diagnostics only and never counted against any token budget.
  """

  use GenServer

  require Logger

  alias Tackle.Config.Narration, as: Settings
  alias Tackle.Lib.{Event, LLM, Usage}
  alias Tackle.Narration.Digest
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Registry

  @max_chars 100
  @end_events [:tool_execution_end, :tool_end, :tool_error]
  @subscribe_retry_ms 1_000
  @request_timeout_ms 30_000
  @request_grace_ms 5_000
  @max_backoff_ms 60_000
  @quote_chars ["\"", "'", "`", "“", "”", "‘", "’"]

  @type option ::
          {:agent_ref, AgentRef.t()}
          | {:task_supervisor, Supervisor.supervisor()}
          | {:settings, Settings.t()}
          | {:llm_opts, keyword()}

  @doc """
  Starts a narrator for one root agent.

  Options are `:agent_ref`, `:task_supervisor` (the agent's service
  `Task.Supervisor`), `:settings` (`Tackle.Config.Narration`), and `:llm_opts`,
  merged into the model call (for example a `:receive_timeout`). The
  selection already carries its provider's settings.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    agent_ref = Keyword.fetch!(opts, :agent_ref)
    GenServer.start_link(__MODULE__, opts, name: Registry.service_name(agent_ref, __MODULE__))
  end

  @doc "Whether a narrator is currently running for `agent_ref`."
  @spec running?(AgentRef.t()) :: boolean()
  def running?(%AgentRef{} = agent_ref),
    do: match?({:ok, _pid}, Registry.service(agent_ref, __MODULE__))

  @doc """
  The prompt sent to the narration model for one run's digest state
  (`Tackle.Narration.Digest.state/1`).
  """
  @spec prompt(map()) :: String.t()
  def prompt(state) when is_map(state) do
    "You write the live status line of a coding agent's delegated task. " <>
      "From the task and its recent activity below, write one short present-tense line, " <>
      "at most 12 words, saying what it is doing right now, for example " <>
      "\"reading the session tests to find where titles are stored\". " <>
      "Describe the newest activity. When previous_status is set, say what is new instead " <>
      "of repeating it. Do not use quotes, markdown, or trailing punctuation. " <>
      "Do not address anyone and do not do the task.\n\nActivity:\n" <>
      JSON.encode!(state)
  end

  @doc """
  Cleans a model answer into a status line.

  Keeps the first non-blank line, strips wrapping quotes and trailing
  sentence punctuation, collapses whitespace, and bounds it to 100 characters.
  Returns `nil` when nothing remains.
  """
  @spec normalize(term()) :: String.t() | nil
  def normalize(text) when is_binary(text) do
    line =
      text
      |> String.replace_invalid("")
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.find("", &(&1 != ""))
      |> trim_quotes()
      |> String.split()
      |> Enum.join(" ")
      |> String.trim_trailing(".")
      |> String.trim()

    cond do
      line == "" -> nil
      String.length(line) <= @max_chars -> line
      true -> String.slice(line, 0, @max_chars - 1) <> "…"
    end
  end

  def normalize(_text), do: nil

  @impl true
  def init(opts) do
    state = %{
      agent_ref: Keyword.fetch!(opts, :agent_ref),
      task_supervisor: Keyword.fetch!(opts, :task_supervisor),
      settings: Keyword.fetch!(opts, :settings),
      llm_opts: Keyword.get(opts, :llm_opts, []),
      subscribed?: false,
      calls: %{},
      runs: %{},
      timer: nil,
      inflight: nil,
      retry_at: nil,
      backoff_ms: nil,
      warned?: false,
      usage: nil
    }

    case subscribe(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, {:subscribe_failed, reason}}
    end
  end

  @impl true
  def handle_info(:subscribe, state) do
    case subscribe(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:stop, {:subscribe_failed, reason}, state}
    end
  end

  def handle_info({:tackle_event, _session_id, _turn_id, %Event{} = event}, state),
    do: {:noreply, event |> observe(state, now()) |> schedule()}

  # Foreground runs end with the turn that waits for them; background runs
  # report their own end.
  def handle_info({finished, _session_id, _turn_id, _result}, state)
      when finished in [:tackle_turn_finished, :tackle_turn_failed] do
    runs = Map.filter(state.runs, fn {_id, run} -> run.background? end)
    {:noreply, schedule(%{state | runs: runs, calls: %{}})}
  end

  def handle_info(:narrate, state),
    do: {:noreply, state |> Map.put(:timer, nil) |> narrate(now()) |> schedule()}

  def handle_info({ref, result}, %{inflight: %{task: %Task{ref: ref}} = inflight} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> settle(inflight) |> answered(inflight, result) |> schedule()}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{inflight: %{task: %Task{ref: ref}} = inflight} = state
      ) do
    state = state |> settle(inflight) |> answered(inflight, {:error, {:crashed, reason}})
    {:noreply, schedule(state)}
  end

  def handle_info(
        {:narration_timeout, ref},
        %{inflight: %{task: %Task{ref: ref}} = inflight} = state
      ) do
    Task.shutdown(inflight.task, :brutal_kill)
    state = state |> settle(inflight) |> answered(inflight, {:error, :timeout})
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

  # The task of a subagent run is the prompt of the `subagent` call that
  # started it; remember it until the run opens.
  defp observe(%Event{type: :tool_start, data: %{name: "subagent"} = data}, state, _now) do
    arguments = Map.get(data, :arguments)

    case Map.get(data, :tool_call_id) do
      id when is_binary(id) and is_map(arguments) ->
        call = %{
          prompt: argument(arguments, "prompt", :prompt),
          background?: argument(arguments, "background", :background) == true
        }

        %{state | calls: Map.put(state.calls, id, call)}

      _other ->
        state
    end
  end

  # A finished foreground `subagent` call or `run_workflow` call ends every run
  # it started; background runs outlive their launching call.
  defp observe(%Event{type: type, data: %{tool_call_id: id}}, state, _now)
       when type in @end_events and is_binary(id) do
    runs =
      Map.reject(state.runs, fn {_run_id, run} ->
        run.tool_call_id == id and not run.background?
      end)

    %{state | runs: runs}
  end

  defp observe(%Event{type: :subagent_started, data: data}, state, now),
    do: open(state, data, :subagent, now)

  defp observe(%Event{type: :subagent_progress, data: data}, state, now) do
    state
    |> open(data, :subagent, now)
    |> feed(Map.get(data, :run_id), Map.get(data, :event))
  end

  defp observe(%Event{type: :subagent_finished, data: data}, state, _now),
    do: close(state, Map.get(data, :run_id))

  defp observe(%Event{type: :workflow_progress, data: %{kind: :run_started} = data}, state, now),
    do: open(state, Map.put(data, :background, false), :workflow, now)

  defp observe(%Event{type: :workflow_progress, data: %{kind: :run_event} = data}, state, now) do
    state
    |> open(Map.put(data, :background, false), :workflow, now)
    |> feed(Map.get(data, :run_id), Map.get(data, :event))
  end

  defp observe(
         %Event{type: :workflow_progress, data: %{kind: :run_finished} = data},
         state,
         _now
       ),
       do: close(state, Map.get(data, :run_id))

  defp observe(%Event{}, state, _now), do: state

  # Progress may arrive before the run's start event, so either opens the run;
  # later events only fill in what is still missing.
  defp open(state, data, kind, now) do
    case Map.get(data, :run_id) do
      run_id when is_binary(run_id) ->
        tool_call_id = Map.get(data, :tool_call_id)
        call = Map.get(state.calls, tool_call_id, %{})

        run =
          Map.get(state.runs, run_id) ||
            %{
              run_id: run_id,
              tool_call_id: tool_call_id,
              kind: kind,
              background?: false,
              digest: Digest.new(),
              opened_at: now,
              narrated_at: nil
            }

        digest =
          run.digest
          |> Digest.put_task(Map.get(data, :prompt) || Map.get(call, :prompt))
          |> Digest.put_profile(Map.get(data, :profile))

        background? =
          run.background? or Map.get(data, :background) == true or
            Map.get(call, :background?, false)

        run = %{run | digest: digest, background?: background?}
        %{state | runs: Map.put(state.runs, run_id, run)}

      _missing ->
        state
    end
  end

  defp close(state, run_id) when is_binary(run_id),
    do: %{state | runs: Map.delete(state.runs, run_id)}

  defp close(state, _run_id), do: state

  defp feed(state, run_id, %Event{} = event) when is_map_key(state.runs, run_id),
    do: update_in(state.runs[run_id].digest, &observe_child(&1, event))

  defp feed(state, _run_id, _event), do: state

  # Nested runs arrive wrapped in their parent's progress; their work counts
  # toward the top-level run.
  defp observe_child(digest, %Event{type: :subagent_progress, data: %{event: %Event{} = inner}}),
    do: observe_child(digest, inner)

  defp observe_child(
         digest,
         %Event{type: :workflow_progress, data: %{kind: :run_event, event: %Event{} = inner}}
       ),
       do: observe_child(digest, inner)

  defp observe_child(digest, %Event{} = event), do: Digest.observe(digest, event)

  # Provider arguments are decoded JSON with string keys; accept atom keys from
  # hosts that build calls by hand.
  defp argument(arguments, key, atom_key),
    do: Map.get(arguments, key, Map.get(arguments, atom_key))

  # ── Narration ─────────────────────────────────────────────────────────

  defp narrate(%{inflight: nil} = state, now) do
    state.runs
    |> Map.values()
    |> Enum.filter(&(due_at(state, &1) <= now))
    |> Enum.min_by(&{&1.narrated_at || &1.opened_at, &1.opened_at}, fn -> nil end)
    |> case do
      nil -> state
      run -> start_request(state, run)
    end
  end

  defp narrate(state, _now), do: state

  # Monotonic times may be negative, so absent constraints are left out rather
  # than defaulted to zero. An unchanged run never becomes due: `:infinity`
  # sorts after every integer time.
  defp due_at(state, run) do
    if Digest.changed?(run.digest) do
      [
        run.opened_at + Settings.first_after_ms(state.settings),
        run.narrated_at && run.narrated_at + Settings.interval_ms(state.settings),
        state.retry_at
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.max()
    else
      :infinity
    end
  end

  defp start_request(state, run) do
    %Settings{selection: selection} = state.settings
    observed = Digest.state(run.digest)

    opts =
      [
        messages: [%{role: :user, content: prompt(observed)}],
        temperature: 0.2,
        tools: [],
        tool_choice: "none",
        reasoning_effort: :none,
        max_tokens: 60,
        credential_store: Tackle.Auth.credential_store()
      ]
      |> Keyword.merge(state.llm_opts)
      |> Keyword.put_new(:receive_timeout, @request_timeout_ms)

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        LLM.generate_with(selection, nil, opts)
      end)

    # The adapter enforces its receive timeout; the timer only reaps a request
    # that ignores it, after a grace no longer than the timeout itself.
    timeout = Keyword.fetch!(opts, :receive_timeout)

    timer =
      Process.send_after(
        self(),
        {:narration_timeout, task.ref},
        timeout + min(timeout, @request_grace_ms)
      )

    state = update_in(state.runs[run.run_id].digest, &Digest.taken/1)
    %{state | inflight: %{task: task, timer: timer, run_id: run.run_id}}
  catch
    :exit, reason ->
      failed(state, run.run_id, {:task_supervisor_unavailable, reason})
  end

  defp settle(state, inflight) do
    Process.cancel_timer(inflight.timer)
    %{state | inflight: nil}
  end

  defp answered(state, inflight, {:ok, %{data: data} = response}) do
    state = %{state | usage: Usage.aggregate([state.usage, Map.get(response, :usage)])}
    state = %{state | retry_at: nil, backoff_ms: nil}

    case Map.fetch(state.runs, inflight.run_id) do
      {:ok, run} -> publish(state, run, text(data))
      # The run finished while the model answered.
      :error -> state
    end
  end

  defp answered(state, inflight, {:error, reason}), do: failed(state, inflight.run_id, reason)

  defp answered(state, inflight, other),
    do: failed(state, inflight.run_id, {:invalid_response, other})

  defp text(%{"tool_calls" => [_ | _]}), do: nil
  defp text(%{"content" => content}), do: normalize(content)
  defp text(_data), do: nil

  # Every answer counts as the run's narration attempt, so an empty one waits
  # out the interval instead of being retried at once.
  defp publish(state, run, text) do
    run = %{run | narrated_at: now()}

    run =
      if is_binary(text) and text != run.digest.previous do
        event =
          Event.new(:narration, %{
            run_id: run.run_id,
            tool_call_id: run.tool_call_id,
            text: text,
            auxiliary: true
          })

        case Runtime.publish_event(state.agent_ref, event) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.debug("narrator could not publish for #{run.run_id}: #{inspect(reason)}")
        end

        %{run | digest: Digest.narrated(run.digest, text)}
      else
        run
      end

    %{state | runs: Map.put(state.runs, run.run_id, run)}
  end

  # The run's state was not narrated, so it stays due once the back-off ends.
  defp failed(state, run_id, reason) do
    state = warn_once(state, reason)
    backoff = min((state.backoff_ms || Settings.interval_ms(state.settings)) * 2, @max_backoff_ms)
    state = %{state | backoff_ms: backoff, retry_at: now() + backoff}

    if Map.has_key?(state.runs, run_id),
      do: update_in(state.runs[run_id].digest, &Digest.changed/1),
      else: state
  end

  defp warn_once(%{warned?: true} = state, _reason), do: state

  defp warn_once(state, reason) do
    Logger.warning(
      "narration model #{state.settings.model_ref} failed: #{inspect(reason)}; " <>
        "delegated runs will not be narrated until it answers"
    )

    %{state | warned?: true}
  end

  # One timer for the earliest due run; none while a request is in flight,
  # because its answer reschedules. An unchanged due time keeps its timer, so
  # a stream of child deltas does not churn timers.
  defp schedule(%{inflight: nil} = state) do
    due =
      state.runs
      |> Map.values()
      |> Enum.map(&due_at(state, &1))
      |> Enum.min(fn -> :infinity end)

    case {due, state.timer} do
      {:infinity, _timer} ->
        cancel_timer(state)

      {at, {_ref, at}} ->
        state

      {at, _timer} ->
        state = cancel_timer(state)
        ref = Process.send_after(self(), :narrate, max(at - now(), 0))
        %{state | timer: {ref, at}}
    end
  end

  defp schedule(state), do: cancel_timer(state)

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: {ref, _at}} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end

  defp trim_quotes(text) do
    trimmed =
      Enum.reduce(@quote_chars, text, fn char, acc ->
        acc |> String.trim_leading(char) |> String.trim_trailing(char)
      end)

    if trimmed == text, do: text, else: trim_quotes(String.trim(trimmed))
  end

  defp now, do: System.monotonic_time(:millisecond)
end
