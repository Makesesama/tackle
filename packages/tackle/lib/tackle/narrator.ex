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
       backs off, and keeps watching. The warning names the failure by error
       kind and HTTP status, never the request, which holds the task and
       assistant text.

  The root agent's own turn is not narrated. Model calls run as unlinked tasks
  under the service task supervisor; their usage is never counted against any
  token budget.
  """

  use GenServer

  require Logger

  import Tackle.AgentService, only: [is_tool_call_end: 1]

  alias Tackle.AgentService
  alias Tackle.AgentService.Call
  alias Tackle.Config.Narration, as: Settings
  alias Tackle.Lib.{Event, LLM}
  alias Tackle.Lib.LLM.Response
  alias Tackle.Narration.Digest
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef
  alias Tackle.StatusRedaction

  @max_chars 100
  @request_timeout_ms 30_000
  @max_backoff_ms 60_000
  @quote_chars ["\"", "'", "`", "“", "”", "‘", "’"]

  @type option ::
          {:agent_ref, AgentRef.t()}
          | {:task_supervisor, Supervisor.supervisor()}
          | {:settings, Settings.t()}
          | {:request_timeout, pos_integer()}

  @doc """
  Starts a narrator for one root agent.

  Options are `:agent_ref`, `:task_supervisor` (the agent's service
  `Task.Supervisor`), `:settings` (`Tackle.Config.Narration`), and
  `:request_timeout`, the milliseconds a model request may take (30 seconds by
  default; anything but a positive integer raises `ArgumentError`). The
  selection already carries its provider's settings, and requests carry the
  harness credential store (`Tackle.Auth`).
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts), do: AgentService.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      agent_ref: Keyword.fetch!(opts, :agent_ref),
      task_supervisor: Keyword.fetch!(opts, :task_supervisor),
      settings: Keyword.fetch!(opts, :settings),
      request_timeout: AgentService.request_timeout!(opts, @request_timeout_ms),
      calls: %{},
      runs: %{},
      timer: nil,
      inflight: nil,
      retry_at: nil,
      backoff_ms: nil,
      warned?: false
    }

    case AgentService.subscribe(state.agent_ref) do
      :ok -> {:ok, state}
      {:error, reason} -> {:stop, {:subscribe_failed, reason}}
    end
  end

  # Tasks, digests of the runs' activity (tool arguments, assistant text), and
  # the model's selection with its provider settings may carry secrets; crash
  # reports and `:sys.get_status/1` show only run and call ids and timing.
  @impl true
  def format_status(status), do: StatusRedaction.format_status(status, &redact_state/1)

  defp redact_state(%{runs: runs, calls: calls, settings: %Settings{} = settings} = state) do
    %{
      state
      | runs: Map.new(runs, fn {id, run} -> {id, Map.delete(run, :digest)} end),
        calls: Map.new(calls, fn {id, call} -> {id, Map.delete(call, :prompt)} end),
        settings: Map.take(settings, [:model_ref, :interval_seconds, :first_after_seconds])
    }
  end

  defp redact_state(state), do: state

  @impl true
  def handle_info(:subscribe, state) do
    case AgentService.subscribe(state.agent_ref) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, {:subscribe_failed, reason}, state}
    end
  end

  def handle_info({:tackle_event, _session_id, _turn_id, %Event{} = event}, state),
    do: {:noreply, event |> observe(state, AgentService.now()) |> schedule()}

  # Foreground runs end with the turn that waits for them; background runs
  # report their own end.
  def handle_info({finished, _session_id, _turn_id, _result}, state)
      when finished in [:tackle_turn_finished, :tackle_turn_failed] do
    runs = Map.filter(state.runs, fn {_id, run} -> run.background? end)
    {:noreply, schedule(%{state | runs: runs, calls: %{}})}
  end

  def handle_info(:narrate, state),
    do: {:noreply, state |> Map.put(:timer, nil) |> narrate(AgentService.now()) |> schedule()}

  def handle_info(message, state) do
    case Call.match(state.inflight, message) do
      {:ok, result} ->
        run_id = state.inflight.meta
        {:noreply, %{state | inflight: nil} |> answered(run_id, result) |> schedule()}

      :error ->
        {:noreply, state}
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
          prompt: AgentService.argument(arguments, "prompt", :prompt),
          background?: AgentService.argument(arguments, "background", :background) == true
        }

        %{state | calls: Map.put(state.calls, id, call)}

      _other ->
        state
    end
  end

  # A finished foreground `subagent` call or `run_workflow` call ends every run
  # it started; background runs outlive their launching call.
  defp observe(%Event{type: type, data: %{tool_call_id: id}}, state, _now)
       when is_tool_call_end(type) and is_binary(id) do
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

    opts = [
      messages: [%{role: :user, content: prompt(observed)}],
      temperature: 0.2,
      tools: [],
      tool_choice: "none",
      reasoning_effort: :none,
      max_tokens: 60,
      credential_store: Tackle.Auth.credential_store(),
      receive_timeout: state.request_timeout
    ]

    # The adapter enforces its receive timeout; the call reaps a request that
    # ignores it.
    generate = fn -> LLM.generate_with(selection, nil, opts) end

    case Call.start(
           state.task_supervisor,
           generate,
           state.request_timeout,
           run.run_id
         ) do
      {:ok, call} ->
        state = update_in(state.runs[run.run_id].digest, &Digest.taken/1)
        %{state | inflight: call}

      {:error, reason} ->
        failed(state, run.run_id, reason)
    end
  end

  defp answered(state, run_id, {:ok, %Response{} = response}) do
    state = %{state | retry_at: nil, backoff_ms: nil}

    case Map.fetch(state.runs, run_id) do
      {:ok, run} -> publish(state, run, text(response))
      # The run finished while the model answered.
      :error -> state
    end
  end

  defp answered(state, run_id, {:error, reason}), do: failed(state, run_id, reason)

  defp text(%Response{tool_calls: [_ | _]}), do: nil
  defp text(%Response{content: content}), do: normalize(content)

  defp prompt(state) do
    "You write the live status line of a coding agent's delegated task. " <>
      "From the task and its recent activity below, write one short present-tense line, " <>
      "at most 12 words, saying what it is doing right now, for example " <>
      "\"reading the session tests to find where titles are stored\". " <>
      "Describe the newest activity. When previous_status is set, say what is new instead " <>
      "of repeating it. Do not use quotes, markdown, or trailing punctuation. " <>
      "Do not address anyone and do not do the task.\n\nActivity:\n" <>
      JSON.encode!(state)
  end

  # A status line is the answer's first non-blank line without wrapping quotes,
  # trailing sentence punctuation, or repeated whitespace, bounded to 100
  # characters; `nil` when nothing remains.
  defp normalize(text) when is_binary(text) do
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

  defp normalize(_text), do: nil

  # Every answer counts as the run's narration attempt, so an empty one waits
  # out the interval instead of being retried at once.
  defp publish(state, run, text) do
    run = %{run | narrated_at: AgentService.now()}

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
            Logger.debug(
              "narrator could not publish for #{run.run_id}: #{StatusRedaction.reason(reason)}"
            )
        end

        %{run | digest: Digest.narrated(run.digest, text)}
      else
        run
      end

    %{state | runs: Map.put(state.runs, run.run_id, run)}
  end

  # The run's state was not narrated, so it stays due once the back-off ends.
  defp failed(state, run_id, reason) do
    state =
      AgentService.warn_once(
        state,
        "narration model #{state.settings.model_ref} failed: #{StatusRedaction.reason(reason)}; " <>
          "delegated runs will not be narrated until it answers"
      )

    backoff = min((state.backoff_ms || Settings.interval_ms(state.settings)) * 2, @max_backoff_ms)
    state = %{state | backoff_ms: backoff, retry_at: AgentService.now() + backoff}

    if Map.has_key?(state.runs, run_id),
      do: update_in(state.runs[run_id].digest, &Digest.changed/1),
      else: state
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

    %{state | timer: AgentService.schedule(state.timer, due, :narrate)}
  end

  defp schedule(state), do: %{state | timer: AgentService.cancel(state.timer)}

  defp trim_quotes(text) do
    trimmed =
      Enum.reduce(@quote_chars, text, fn char, acc ->
        acc |> String.trim_leading(char) |> String.trim_trailing(char)
      end)

    if trimmed == text, do: text, else: trim_quotes(String.trim(trimmed))
  end
end
