defmodule Tackle.Review.Delegation do
  @moduledoc """
  Starts and awaits the delegated runs of the review stages.

  Each run uses a trusted profile spec (normally from the scope's profiles)
  with the stage's per-run data placed under `:review` in the session
  context, where the stage's output tool reads it. The run is requested from
  the review's requester through `Tackle.Runtime.request_agent/4`, so it is
  admitted, limited, and cancelled like any other delegated run and shows up
  among the scope's tasks.

  The calling process owns the run: if it exits, the runtime cancels the run.
  The runtime refuses rather than queues work at capacity, so a capacity
  refusal is retried until `:capacity_wait` passes.

  A run that fails after doing useful work still returns its transcript, so
  a stage can keep what the run reported: the final state's messages when
  the run settled with one (an agent error such as the step limit, or the
  run alone being cancelled), otherwise the messages the run had finished
  when it timed out or crashed, mirrored from its events while it ran.

  Only the cancellation of the requester (its branch or scope) cancels the
  stage (`{:error, :cancelled}`); a run cancelled on its own is a failed run
  (`:run_cancelled`) like any other.

  ## Stopping a run that has reported everything

  A stage's run has done its work once its output tool recorded its last
  report. The model call the loop then makes to close the turn adds a few
  seconds and a full prompt to every run without changing what the run
  reported. With `:done?`, the caller checks
  the run's transcript as it arrives, after each tool result; once the
  predicate holds, the run is stopped (`Tackle.Runtime.cancel_run/3`, as its
  owner) and returns `{:ok, state}` like a run that settled normally. The
  run then shows up as cancelled among the scope's tasks.
  """

  alias Tackle.Config
  alias Tackle.Lib.{Event, Message, State, Usage}
  alias Tackle.Runtime
  alias Tackle.Runtime.{AgentRef, AgentSpec, Outcome, Registry, RootBackend, ScopeRef}

  # Transient capacity refusals of `Tackle.AgentScope.Coordinator`.
  @capacity_reasons [:max_children_per_agent, :max_agents_per_fleet]
  @capacity_poll_ms 20
  @default_capacity_wait :timer.seconds(60)
  # How long to wait for a settled run's request process to stop, while
  # collecting the messages it mirrored last.
  @mirror_grace_ms 5_000

  @typedoc "The agent the review's runs are delegated from."
  @type requester :: AgentRef.t()

  @typedoc """
  Why a run produced no usable result:

    * `:cancelled` - the requester's branch or scope was cancelled, which
      cancels the review;
    * `:run_cancelled` - the run alone was cancelled;
    * `{:agent_error, message}` - the agent loop ended with an error;
    * `:timeout` - the run was inactive for too long;
    * `{:runtime_error, reason}` - the run crashed;
    * `{:rejected, reason}` - the runtime refused to start it;
    * `{:request_failed, reason}` - the request could not be made, for
      example for an unavailable model;
    * `{:unavailable, reason}` - the run's outcome could not be collected.
  """
  @type error ::
          :cancelled
          | :run_cancelled
          | {:agent_error, String.t()}
          | :timeout
          | {:runtime_error, term()}
          | {:rejected, term()}
          | {:request_failed, term()}
          | {:unavailable, term()}

  @typedoc """
  Run options:

    * `:model` - a `"provider/model"` reference overriding the profile's model;
    * `:capacity_wait` - how long to retry capacity refusals, in milliseconds
      (default 60 seconds);
    * `:done?` - `fn messages -> boolean end`, called with the run's
      finished messages so far, in order, after each tool result; when it
      returns `true` the run has nothing left to do and is stopped (see
      "Stopping a run that has reported everything"). It runs in the
      calling process and must not raise.
  """
  @type option ::
          {:model, String.t() | nil}
          | {:capacity_wait, non_neg_integer()}
          | {:done?, ([Message.t()] -> boolean())}

  @doc """
  Returns `spec` with `review` stored under `:review` in its session context.

  Only harness configurations (`Tackle.Config`) are supported.
  """
  @spec put_review_context(AgentSpec.t(), map()) ::
          {:ok, AgentSpec.t()} | {:error, {:unsupported_agent_config, String.t()}}
  def put_review_context(%AgentSpec{config: %Config{} = config} = spec, review)
      when is_map(review) do
    {:ok, %{spec | config: %{config | context: Map.put(config.context, :review, review)}}}
  end

  def put_review_context(%AgentSpec{name: name}, _review),
    do: {:error, {:unsupported_agent_config, name}}

  @doc """
  Returns the configuration a run of `spec` requested from `requester`
  starts with, before any `:model` override, without starting a run.

  A profile that inherits its model (`model_source: :parent`) runs on the
  requester's current model and thinking level, as `Tackle.Runtime` applies
  them when a run starts; any other profile keeps its own configuration.
  """
  @spec base_config(requester(), AgentSpec.t()) ::
          {:ok, Config.t()}
          | {:error,
             {:requester_model_unavailable, term()} | {:unsupported_agent_config, String.t()}}
  def base_config(requester, %AgentSpec{config: %Config{} = config, model_source: :parent}) do
    with {:ok, %{agent_state: %State{} = state}} <-
           Runtime.session_snapshot(requester),
         {:ok, config} <- RootBackend.inherit_model(config, state) do
      {:ok, config}
    else
      {:error, reason} -> {:error, {:requester_model_unavailable, reason}}
      other -> {:error, {:requester_model_unavailable, other}}
    end
  end

  def base_config(_requester, %AgentSpec{config: %Config{} = config}), do: {:ok, config}

  def base_config(_requester, %AgentSpec{name: name}),
    do: {:error, {:unsupported_agent_config, name}}

  @doc """
  Runs one delegated agent to completion and returns its final state.

  Blocks until the run settles. A run that settles normally, or that was
  stopped because `:done?` held, returns `{:ok, state}`. A run that started and then failed returns
  `{:error, reason, messages}` with its transcript so far (see the module
  documentation), which may still hold what the run reported before it
  failed. `{:error, :cancelled}` means the requester was cancelled; a run
  that could not start, or was refused, returns `{:error, reason}`. See
  `t:error/0`.
  """
  @spec run(requester(), AgentSpec.t(), String.t(), [option()]) ::
          {:ok, State.t()}
          | {:error, error(), [Message.t()]}
          | {:error, error()}
  def run(requester, %AgentSpec{} = spec, prompt, opts \\ []) when is_binary(prompt) do
    mirror = make_ref()
    model_opts = if model = Keyword.get(opts, :model), do: [model: model], else: []
    request_opts = [event_callback: mirror_callback(self(), mirror)] ++ model_opts
    wait = Keyword.get(opts, :capacity_wait, @default_capacity_wait)
    deadline = System.monotonic_time(:millisecond) + wait

    result =
      with {:ok, run_ref} <- request(requester, spec, prompt, request_opts, deadline) do
        monitor = monitor_request(run_ref)
        follow = %{requester: requester, run_ref: run_ref, mirror: mirror}
        {outcome, seen, stopped?} = follow(follow, Keyword.get(opts, :done?))
        settle(outcome, mirrored(mirror, monitor, seen), stopped?)
      end

    cancellation(result, requester)
  end

  @doc "Sums the token usage of a run's assistant messages."
  @spec usage(State.t() | [Message.t()]) :: Usage.t()
  def usage(%State{messages: messages}), do: usage(messages)

  def usage(messages) when is_list(messages) do
    messages
    |> Enum.filter(&(&1.role == :assistant))
    |> Enum.map(& &1.token_usage)
    |> Usage.aggregate()
  end

  @doc "Describes a run error for people."
  @spec format_error(error()) :: String.t()
  def format_error(:cancelled), do: "cancelled"
  def format_error(:run_cancelled), do: "cancelled"
  def format_error(:timeout), do: "timed out"
  def format_error({:agent_error, message}), do: "agent failed: #{message}"
  def format_error({:runtime_error, reason}), do: "agent crashed: #{inspect(reason)}"
  def format_error({:rejected, reason}), do: "run refused: #{inspect(reason)}"
  def format_error({:request_failed, reason}), do: "could not start the run: #{inspect(reason)}"
  def format_error({:unavailable, reason}), do: "result unavailable: #{inspect(reason)}"
  def format_error(other), do: inspect(other)

  defp request(requester, spec, prompt, opts, deadline) do
    case Runtime.request_agent(requester, spec, prompt, opts) do
      {:ok, run_ref} ->
        {:ok, run_ref}

      {:error, {:rejected, reason}} when reason in @capacity_reasons ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@capacity_poll_ms)
          request(requester, spec, prompt, opts, deadline)
        else
          {:error, {:rejected, reason}}
        end

      {:error, {:rejected, reason}} ->
        if cancelled_refusal?(reason),
          do: {:error, :cancelled},
          else: {:error, {:rejected, reason}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp cancelled_refusal?(:cancelled), do: true
  defp cancelled_refusal?({:scope_cancelled, _reason}), do: true
  defp cancelled_refusal?(_reason), do: false

  # The request process calls this for each event of the run, in order. It
  # stops once the run is collected, so every message it mirrored is in the
  # caller's mailbox before its `:DOWN`.
  defp mirror_callback(owner, mirror) do
    fn
      _run_ref, %Event{type: :message_end, data: %{message: %Message{role: role} = message}}
      when role in [:assistant, :tool] ->
        send(owner, {mirror, message})

      _run_ref, _event ->
        :ok
    end
  end

  defp monitor_request(run_ref) do
    case Registry.whereis(run_ref) do
      {:ok, pid} -> Process.monitor(pid)
      {:error, _reason} -> nil
    end
  end

  # Awaits the run's outcome. With a `done?` predicate, the run's mirrored
  # messages are collected while it runs and checked after each tool result,
  # and the run is stopped once the predicate holds. Returns the outcome, the
  # messages seen so far (newest first), and whether the run was stopped.
  defp follow(follow, nil), do: {Runtime.await(follow.run_ref, :infinity), [], false}

  defp follow(follow, done?) do
    # `Runtime.await/2` turns exits into error tuples, so the waiter does not
    # crash.
    waiter = Task.async(fn -> Runtime.await(follow.run_ref, :infinity) end)
    follow = Map.merge(follow, %{done?: done?, waiter: waiter.ref})
    await_outcome(follow, [], nil)
  end

  defp await_outcome(follow, seen, stop) do
    mirror = follow.mirror
    waiter = follow.waiter

    receive do
      {^mirror, message} ->
        seen = [message | seen]
        await_outcome(follow, seen, stop || stop_when_done(follow, message, seen))

      {^waiter, outcome} ->
        Process.demonitor(waiter, [:flush])
        {stop_outcome(outcome, stop), seen, stop != nil}
    end
  end

  defp stop_when_done(follow, %Message{role: :tool}, seen) do
    if follow.done?.(transcript(seen)) do
      case Runtime.cancel_run(follow.requester, follow.run_ref, :review_complete) do
        {:ok, :cancelling} -> :cancelling
        {:ok, {:completed, outcome}} -> {:completed, outcome}
        # The run settled and was collected in between; its outcome reaches
        # the waiter.
        {:error, _reason} -> nil
      end
    end
  end

  defp stop_when_done(_follow, _message, _seen), do: nil

  # Stopping a run that had already settled consumes its outcome, so the
  # waiter may find the run gone.
  defp stop_outcome({:error, _reason}, {:completed, outcome}), do: outcome
  defp stop_outcome(outcome, _stop), do: outcome

  defp mirrored(mirror, monitor, acc) do
    receive do
      {^mirror, message} ->
        mirrored(mirror, monitor, [message | acc])

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        transcript(acc)
    after
      if(monitor, do: @mirror_grace_ms, else: 0) ->
        if monitor, do: Process.demonitor(monitor, [:flush])
        transcript(acc)
    end
  end

  defp transcript(reversed), do: reversed |> Enum.reverse() |> Enum.uniq_by(& &1.id)

  defp settle(%Outcome{status: :ok, agent_state: %State{} = state}, _mirrored, _stopped?),
    do: {:ok, state}

  # Stopped once it had nothing left to do: the run is complete.
  defp settle(%Outcome{status: :cancelled, agent_state: %State{} = state}, _mirrored, true),
    do: {:ok, state}

  defp settle(outcome, mirrored, _stopped?), do: settle(outcome, mirrored)

  defp settle(%Outcome{status: :cancelled, agent_state: %State{} = state}, _mirrored),
    do: {:error, :run_cancelled, state.messages}

  defp settle(%Outcome{status: :timeout}, mirrored), do: {:error, :timeout, mirrored}

  defp settle(%Outcome{status: :error, agent_state: %State{} = state} = outcome, _mirrored),
    do: {:error, {:agent_error, Outcome.message(outcome)}, state.messages}

  defp settle(%Outcome{status: :runtime_error, reason: reason}, mirrored),
    do: {:error, {:runtime_error, reason}, mirrored}

  defp settle(%Outcome{status: :rejected, reason: reason}, _mirrored),
    do: {:error, {:rejected, reason}}

  defp settle({:error, reason}, mirrored), do: {:error, {:unavailable, reason}, mirrored}

  # A run fails with its requester's branch or scope (cancelled, or stopped
  # so that the run is torn down), or on its own. Only the former cancels
  # the review. A run that settled normally, with an agent error, failed on
  # its own.
  defp cancellation({:ok, _state} = result, _requester), do: result
  defp cancellation({:error, :cancelled} = result, _requester), do: result

  defp cancellation({:error, {:agent_error, _message}, _messages} = result, _requester),
    do: result

  defp cancellation(result, requester) do
    if requester_cancelled?(requester), do: {:error, :cancelled}, else: result
  end

  # An unreachable requester counts as cancelled: its scope is gone.
  defp requester_cancelled?(%AgentRef{scope_id: scope_id} = requester) do
    not (match?({:ok, %{cancelled: false}}, Runtime.agent_snapshot(requester)) and
           match?({:ok, %{cancelled: nil}}, Runtime.scope_snapshot(%ScopeRef{scope_id: scope_id})))
  catch
    :exit, _reason -> true
  end
end
