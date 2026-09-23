defmodule Tackle.Phoenix.Runner do
  @moduledoc """
  Generic per-session GenServer that runs Tackle agent turns inside OTP.

  Hosts provide infrastructure and a `Tackle.Phoenix.Store` implementation. The
  runner owns only the framework glue: task supervision, cancellation signals,
  event fan-out, usage aggregation, and turn settlement.
  """

  # Session runners are created on demand and reload their state from the host
  # store. They must not be restarted after an intentional stop (for example,
  # session switching or test cleanup), or the DynamicSupervisor's restart
  # intensity can be exhausted by otherwise healthy lifecycle events.
  use GenServer, restart: :temporary

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.Message
  alias Tackle.Lib.State
  alias Tackle.Lib.Telemetry
  alias Tackle.Lib.Usage
  alias Tackle.Phoenix.EventReducer
  alias Tackle.Phoenix.PubSub
  alias Tackle.Runtime.AgentContext

  @timeout :timer.minutes(30)
  @termination_grace_period 1_000
  @max_message_id_bytes 255
  @max_turn_kind_bytes 64
  @max_source_session_id_bytes 255
  @runner_internal_turn_opts [
    :agent_state,
    :host_state,
    :telemetry_metadata,
    :turn_started_at,
    :turn_telemetry_ref
  ]

  @typedoc "Runner configuration injected by the host."
  @type config :: %{
          required(:registry) => module(),
          required(:dynamic_supervisor) => module(),
          required(:task_supervisor) => module(),
          required(:pubsub) => module(),
          required(:store) => module(),
          required(:agent) => module()
        }

  @doc "Starts or returns an existing runner for a user/session pair."
  def get_or_start(%{} = config, user_id, opts \\ []) when is_binary(user_id) do
    session_id = Keyword.get(opts, :session_id)
    registry_key = build_registry_key(user_id, session_id)

    case Registry.lookup(config.registry, registry_key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(
          config.dynamic_supervisor,
          {__MODULE__,
           {config, user_id, session_id, Keyword.get(opts, :agent_state),
            Keyword.get(opts, :host_state)}}
        )
    end
  end

  @doc "Gets the current in-memory agent state."
  def get_state(%{} = config, user_id, opts \\ []) do
    with {:ok, pid} <- get_or_start(config, user_id, opts) do
      GenServer.call(pid, :get_state)
    end
  end

  @doc """
  Returns one atomic snapshot of the runner state and active turn.

  The snapshot also contains `:streaming_messages`, a map of provisional
  visible answer text keyed by message ID. It is cleared on retry, settlement,
  or turn termination; reasoning and tool-input deltas are never stored there.
  Hosts can use this alongside `:agent_state` to hydrate a newly joined view.
  """
  def snapshot(%{} = config, user_id, opts \\ []) do
    with {:ok, pid} <- get_or_start(config, user_id, opts) do
      snapshot(pid)
    end
  end

  def snapshot(pid) when is_pid(pid), do: GenServer.call(pid, :snapshot)

  @doc "Replaces the runner's host and agent state."
  def replace_state(pid, %State{} = agent_state, host_state) when is_pid(pid) do
    GenServer.call(pid, {:replace_state, agent_state, host_state})
  end

  @doc "Updates the in-memory agent state without starting a turn."
  def update_state(%{} = config, user_id, %State{} = agent_state, opts \\ []) do
    with {:ok, pid} <- get_or_start(config, user_id, opts) do
      GenServer.call(pid, {:update_state, agent_state})
    end
  end

  @doc "Returns the current host session id via the store."
  def get_session_id(%{} = config, user_id, opts \\ []) do
    with {:ok, pid} <- get_or_start(config, user_id, opts) do
      GenServer.call(pid, :get_session_id)
    end
  end

  @doc "Subscribes the caller to the runner's session topic."
  def subscribe(%{} = config, user_id, session_id) when is_binary(user_id) do
    PubSub.subscribe(config.pubsub, user_id, session_id)
  end

  @doc "Returns the PubSub topic for a user/session pair."
  defdelegate topic(user_id, session_id), to: PubSub

  @doc """
  Starts a turn by appending a user message.

  Hosts may supply correlation for a message that was durably written before
  delivery:

    * `:user_message_id` — a non-empty stable id of at most 255 bytes.
    * `:turn_metadata` — either an empty map or an exact map containing bounded
      binary `:kind` and `:source_session_id` values.
    * `:pre_persisted_message?` — when `true`, the Runner skips
      `Store.persist_user_message/3`; this requires `:user_message_id`.

  The normalized values are forwarded to the Store callbacks for the active
  turn. Ordinary turns may omit all three options.
  """
  def run_turn(%{} = config, user_id, %State{} = agent_state, input, opts \\ [])
      when is_binary(user_id) and is_binary(input) do
    with {:ok, opts} <- normalize_run_turn_opts(opts) do
      start_public_turn(config, user_id, {:run_turn, agent_state, input}, opts)
    end
  end

  @doc "Restarts a turn without appending a user message."
  def continue_turn(%{} = config, user_id, %State{} = agent_state, opts \\ [])
      when is_binary(user_id) do
    start_public_turn(config, user_id, {:continue_turn, agent_state}, opts)
  end

  @doc "Requests cancellation for the turn currently owned by `pid`."
  def cancel_turn(pid, reason \\ :user_cancelled)

  def cancel_turn(pid, reason) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.cast(pid, {:cancel_turn, reason})
    :ok
  end

  def cancel_turn(_pid, _reason), do: :ok

  @doc false
  def runtime_submit(pid, input) when is_pid(pid) and is_binary(input) do
    GenServer.call(pid, {:runtime_submit, input}, :infinity)
  end

  @doc false
  def runtime_continue(pid) when is_pid(pid) do
    GenServer.call(pid, :runtime_continue, :infinity)
  end

  @doc false
  def runtime_subscribe(pid, subscriber \\ self()) when is_pid(pid) and is_pid(subscriber) do
    GenServer.call(pid, {:runtime_subscribe, subscriber})
  end

  @doc false
  def runtime_unsubscribe(pid, subscriber \\ self()) when is_pid(pid) and is_pid(subscriber) do
    GenServer.call(pid, {:runtime_unsubscribe, subscriber})
  end

  def start_link({config, user_id, session_id, agent_state, host_state}) do
    registry_key = build_registry_key(user_id, session_id)

    GenServer.start_link(
      __MODULE__,
      {config, user_id, session_id, agent_state, host_state},
      name: {:via, Registry, {config.registry, registry_key}}
    )
  end

  @impl true
  def init({config, user_id, session_id, %State{} = agent_state, host_state}) do
    # DynamicSupervisor stops children by sending an exit signal. Trapping exits
    # lets the GenServer transition through `terminate/2`, where an active turn
    # is cancelled and its task is awaited before the cancellation signal is
    # removed.
    Process.flag(:trap_exit, true)

    case register_runtime(config) do
      :ok ->
        host_state = init_host_state(config.store, host_state)

        state = %{
          config: config,
          user_id: user_id,
          initial_session_id: session_id,
          host_state: host_state,
          agent_state: agent_state,
          runtime_subscribers: MapSet.new(),
          turn_task: nil,
          streaming_messages: %{},
          turn_signal: nil,
          turn_usage: empty_turn_usage(),
          turn_telemetry_ref: nil,
          turn_operation: nil,
          turn_started_at: nil,
          turn_metadata: %{},
          turn_opts: [],
          turn_stats: empty_turn_stats()
        }

        {:ok, state, @timeout}

      {:error, reason} ->
        {:stop, {:runtime_registration_failed, reason}}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state.agent_state, state, @timeout}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_value(state), state, @timeout}
  end

  def handle_call({:update_state, %State{} = agent_state}, _from, state) do
    {:reply, :ok, %{state | agent_state: agent_state}, @timeout}
  end

  def handle_call({:replace_state, %State{} = _agent_state, _host_state}, _from, state)
      when not is_nil(state.turn_task) do
    {:reply, {:error, :turn_in_progress}, state, @timeout}
  end

  def handle_call({:replace_state, %State{} = agent_state, host_state}, _from, state) do
    {:reply, :ok, %{state | agent_state: agent_state, host_state: host_state}, @timeout}
  end

  def handle_call(:get_session_id, _from, state) do
    {:reply, current_session_id(state), state, @timeout}
  end

  def handle_call({:runtime_subscribe, subscriber}, _from, state) do
    subscribers = MapSet.put(state.runtime_subscribers, subscriber)
    {:reply, {:ok, snapshot_value(state)}, %{state | runtime_subscribers: subscribers}, @timeout}
  end

  def handle_call({:runtime_unsubscribe, subscriber}, _from, state) do
    subscribers = MapSet.delete(state.runtime_subscribers, subscriber)
    {:reply, :ok, %{state | runtime_subscribers: subscribers}, @timeout}
  end

  def handle_call({:runtime_submit, input}, _from, state) do
    case runtime_turn_opts(state, :run) do
      {:ok, opts} -> start_turn(:run, state, state.agent_state, input, opts)
      {:error, reason} -> {:reply, {:error, reason}, state, @timeout}
    end
  end

  def handle_call(:runtime_continue, _from, state) do
    case runtime_turn_opts(state, :continue) do
      {:ok, opts} -> start_turn(:continue, state, state.agent_state, nil, opts)
      {:error, reason} -> {:reply, {:error, reason}, state, @timeout}
    end
  end

  def handle_call({:run_turn, %State{} = agent_state, input, opts}, _from, state)
      when is_binary(input) do
    start_turn(:run, state, agent_state, input, opts)
  end

  def handle_call({:continue_turn, %State{} = agent_state, opts}, _from, state) do
    start_turn(:continue, state, agent_state, nil, opts)
  end

  @impl true
  def handle_cast({:cancel_turn, reason}, state) do
    if state.turn_signal, do: Cancellation.cancel(state.turn_signal, reason)
    {:noreply, state, @timeout}
  end

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info({:tackle_event, %Event{} = event}, state) do
    {:noreply, process_tackle_event(state, event), @timeout}
  end

  def handle_info({ref, result}, %{turn_task: %Task{ref: ref}, turn_signal: signal} = state) do
    Process.demonitor(ref, [:flush])
    Cancellation.delete(signal)

    {state, result} = settle_completed_turn(state, result)
    notify_runtime_terminal(state, result)
    state = clear_turn(state)
    broadcast(state, {:agent_turn_done, result})

    {:noreply, state, @timeout}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{turn_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    if state.turn_signal, do: Cancellation.delete(state.turn_signal)

    state = fail_turn(state, reason)
    notify_runtime_terminal(state, {:runtime_error, reason})
    state = clear_turn(state)

    broadcast(state, {:agent_turn_failed, reason})
    {:noreply, state, @timeout}
  end

  @impl true
  def handle_info(message, state), do: handle_host_message(state, message)

  @impl true
  def terminate(_reason, state) do
    # Give cooperative loops a bounded opportunity to observe cancellation before
    # forcing their supervised task down. The signal stays available until that
    # task has settled so adapters and tools do not observe a cleared signal.
    if state.turn_signal, do: Cancellation.cancel(state.turn_signal, :runner_terminated)

    task_result = shutdown_turn_task(state.turn_task)
    state = drain_tackle_events(state)

    if state.turn_signal, do: Cancellation.delete(state.turn_signal)
    settle_terminated_turn(state, task_result)
    :ok
  end

  defp shutdown_turn_task(nil), do: :no_turn

  defp shutdown_turn_task(%Task{} = task) do
    case Task.yield(task, @termination_grace_period) do
      {:ok, result} ->
        {:ok, result}

      {:exit, reason} ->
        {:exit, reason}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:exit, :runner_terminated}
    end
  after
    Process.demonitor(task.ref, [:flush])
  end

  defp settle_terminated_turn(state, :no_turn) do
    with_turn_context(state, fn -> exception_turn_telemetry(state, :runner_terminated) end)
    :ok
  end

  defp settle_terminated_turn(state, {:ok, result}) do
    {state, result} = settle_completed_turn(state, result)
    notify_runtime_terminal(state, result)
    broadcast(state, {:agent_turn_done, result})
  end

  defp settle_terminated_turn(state, {:exit, reason}) do
    state = fail_turn(state, reason)
    notify_runtime_terminal(state, {:runtime_error, reason})
    broadcast(state, {:agent_turn_failed, reason})
  end

  defp drain_tackle_events(state) do
    receive do
      {:tackle_event, %Event{} = event} ->
        state |> process_tackle_event(event) |> drain_tackle_events()
    after
      0 -> state
    end
  end

  defp start_turn(:run, state, %State{} = agent_state, input, opts) do
    cond do
      state.turn_task ->
        reject_turn(state, opts, :run, :turn_in_progress)

      (reason = gate_turn(state, opts)) != :ok ->
        reject_turn(state, opts, :run, reason)

      true ->
        signal = Cancellation.new_signal()
        session_pid = self()
        enriched_state = state.config.store.enrich_state(state.host_state, agent_state, opts)

        user_message =
          Message.user(input,
            id: Keyword.get(opts, :user_message_id),
            id_generator: enriched_state.id_generator
          )

        enriched_state = State.add_message(enriched_state, user_message)

        host_state =
          if Keyword.fetch!(opts, :pre_persisted_message?) do
            state.host_state
          else
            state.config.store.persist_user_message(
              state.host_state,
              enriched_state,
              user_message
            )
          end

        enriched_state =
          enriched_state
          |> put_persisted_session_id(state.config.store.current_session_id(host_state))
          |> mark_message_persisted(user_message.id)

        turn_opts = opts |> Keyword.put(:user_message_id, user_message.id) |> store_turn_opts()
        state = %{state | host_state: host_state, agent_state: enriched_state}
        user_event = Event.message_end(user_message)
        broadcast(state, {:agent_event, user_event})
        notify_runtime_event(state, user_event)

        task = start_agent_task(state, enriched_state, signal, opts, session_pid)

        {:reply, {:ok, self()},
         %{
           state
           | turn_task: task,
             turn_signal: signal,
             turn_usage: %{},
             turn_telemetry_ref: Keyword.get(opts, :turn_telemetry_ref),
             turn_operation: :run,
             turn_started_at: Keyword.get(opts, :turn_started_at),
             turn_metadata: Keyword.fetch!(opts, :turn_metadata),
             turn_opts: turn_opts,
             turn_stats: empty_turn_stats()
         }, @timeout}
    end
  end

  defp start_turn(:continue, state, %State{} = agent_state, _input, opts) do
    cond do
      state.turn_task ->
        reject_turn(state, opts, :continue, :turn_in_progress)

      (reason = gate_turn(state, opts)) != :ok ->
        reject_turn(state, opts, :continue, reason)

      true ->
        signal = Cancellation.new_signal()
        session_pid = self()
        enriched_state = state.config.store.enrich_state(state.host_state, agent_state, opts)
        task = start_agent_task(state, enriched_state, signal, opts, session_pid)

        {:reply, {:ok, self()},
         %{
           state
           | agent_state: enriched_state,
             turn_task: task,
             turn_signal: signal,
             turn_usage: %{},
             turn_telemetry_ref: Keyword.get(opts, :turn_telemetry_ref),
             turn_operation: :continue,
             turn_started_at: Keyword.get(opts, :turn_started_at),
             turn_metadata: %{},
             turn_opts: store_turn_opts(opts),
             turn_stats: empty_turn_stats()
         }, @timeout}
    end
  end

  # Runs the host's before_turn gate and normalizes its result. Returns `:ok`
  # to proceed, or the actual abort reason to reply with. The runner stays
  # agnostic about host-specific reasons (e.g. `:insufficient_credits`,
  # `{:usage_limited, _}`) and forwards them verbatim; anything that isn't `:ok`
  # or `{:error, reason}` fails safe as `:turn_rejected`.
  defp gate_turn(state, opts) do
    case state.config.store.before_turn(state.host_state, opts) do
      :ok -> :ok
      {:error, reason} -> reason
      _ -> :turn_rejected
    end
  end

  defp start_agent_task(state, enriched_state, signal, opts, session_pid) do
    telemetry_ref = Keyword.get(opts, :turn_telemetry_ref)

    Task.Supervisor.async_nolink(state.config.task_supervisor, fn ->
      with_telemetry_context(state.config, telemetry_ref, fn ->
        state.config.agent.continue(
          enriched_state,
          build_run_opts(state.config, session_pid, signal, opts)
        )
      end)
    end)
  end

  defp build_run_opts(config, session_pid, signal, opts) do
    event_callback = fn event -> send(session_pid, {:tackle_event, event}) end

    [
      event_callback: event_callback,
      event_context: %{event_callback: event_callback},
      cancellation_signal: signal
    ]
    |> maybe_put(:tool_supervisor, Map.get(config, :tool_supervisor))
    |> maybe_put(:extra_hooks, Keyword.get(opts, :extra_hooks))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp handle_host_message(state, message) do
    store = state.config.store

    if function_exported?(store, :handle_host_message, 2) do
      case store.handle_host_message(state.host_state, message) do
        :unhandled ->
          {:noreply, state, @timeout}

        {:noreply, host_state} ->
          {:noreply, %{state | host_state: host_state}, @timeout}

        {:run_turn, host_state, input, opts}
        when is_binary(input) and is_list(opts) ->
          start_host_turn(state, host_state, input, opts)

        _invalid ->
          {:noreply, state, @timeout}
      end
    else
      {:noreply, state, @timeout}
    end
  end

  defp start_host_turn(state, host_state, input, opts) do
    case normalize_run_turn_opts(opts) do
      {:ok, opts} ->
        metadata = Keyword.get(opts, :telemetry_metadata, %{})

        telemetry_ref =
          Telemetry.start([:tackle, :phoenix, :turn], Map.put(metadata, :operation, :run))

        opts =
          opts
          |> Keyword.put(:turn_telemetry_ref, telemetry_ref)
          |> Keyword.put(:turn_started_at, System.monotonic_time())

        candidate_state = %{state | host_state: host_state}

        case start_turn(:run, candidate_state, state.agent_state, input, opts) do
          {:reply, {:ok, _pid}, started_state, timeout} ->
            {:noreply, started_state, timeout}

          {:reply, {:error, _reason}, rejected_state, timeout} ->
            {:noreply, %{rejected_state | host_state: state.host_state}, timeout}
        end

      {:error, _field} ->
        {:noreply, state, @timeout}
    end
  end

  defp start_public_turn(config, user_id, request, opts) do
    with {:ok, pid} <- get_or_start(config, user_id, opts) do
      operation = if match?({:run_turn, _, _}, request), do: :run, else: :continue
      metadata = Keyword.get(opts, :telemetry_metadata, %{})

      telemetry_ref =
        Telemetry.start([:tackle, :phoenix, :turn], Map.put(metadata, :operation, operation))

      opts =
        opts
        |> Keyword.put(:turn_telemetry_ref, telemetry_ref)
        |> Keyword.put(:turn_started_at, System.monotonic_time())

      try do
        GenServer.call(pid, Tuple.insert_at(request, tuple_size(request), opts), :infinity)
      catch
        kind, reason ->
          Telemetry.exception(
            [:tackle, :phoenix, :turn],
            telemetry_ref,
            %{
              duration: Telemetry.monotonic_duration(Keyword.fetch!(opts, :turn_started_at)),
              count: 1
            },
            %{operation: operation, error_type: exception_type(kind)}
          )

          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp reject_turn(state, opts, operation, reason) do
    rejected_turn = %{
      state
      | turn_telemetry_ref: Keyword.get(opts, :turn_telemetry_ref),
        turn_operation: operation,
        turn_started_at: Keyword.get(opts, :turn_started_at),
        turn_stats: empty_turn_stats()
    }

    with_telemetry_context(state.config, rejected_turn.turn_telemetry_ref, fn ->
      stop_turn_telemetry(rejected_turn, :rejected)
    end)

    # A rejected concurrent request owns its own telemetry lifecycle. Keep the
    # accepted task's state untouched so it can settle its original ref.
    {:reply, {:error, reason}, state, @timeout}
  end

  defp stop_turn_telemetry(%{turn_telemetry_ref: telemetry_ref} = state, outcome)
       when is_reference(telemetry_ref) do
    started_at = state.turn_started_at || System.monotonic_time()

    Telemetry.stop(
      [:tackle, :phoenix, :turn],
      telemetry_ref,
      %{
        duration: Telemetry.monotonic_duration(started_at),
        count: 1,
        iterations: state.turn_stats.iterations,
        tool_call_count: state.turn_stats.tool_call_count
      },
      %{operation: state.turn_operation || :unknown, outcome: outcome}
    )

    state
  end

  defp stop_turn_telemetry(state, _outcome), do: state

  defp exception_turn_telemetry(%{turn_telemetry_ref: telemetry_ref} = state, error_type)
       when is_reference(telemetry_ref) do
    started_at = state.turn_started_at || System.monotonic_time()

    Telemetry.exception(
      [:tackle, :phoenix, :turn],
      telemetry_ref,
      %{duration: Telemetry.monotonic_duration(started_at), count: 1},
      %{operation: state.turn_operation || :unknown, error_type: error_type}
    )

    state
  end

  defp exception_turn_telemetry(state, _error_type), do: state

  defp turn_outcome({:ok, %State{}}), do: :success
  defp turn_outcome({:cancelled, %State{}}), do: :cancelled
  defp turn_outcome(_result), do: :error

  defp clear_turn(state) do
    %{
      state
      | turn_task: nil,
        streaming_messages: %{},
        turn_signal: nil,
        turn_usage: empty_turn_usage(),
        turn_telemetry_ref: nil,
        turn_operation: nil,
        turn_started_at: nil,
        turn_metadata: %{},
        turn_opts: [],
        turn_stats: empty_turn_stats()
    }
  end

  defp with_turn_context(%{turn_telemetry_ref: telemetry_ref, config: config}, fun),
    do: with_telemetry_context(config, telemetry_ref, fun)

  defp with_telemetry_context(%{telemetry_adapter: adapter}, telemetry_ref, fun)
       when is_atom(adapter) and is_reference(telemetry_ref),
       do: adapter.with_context(telemetry_ref, fun)

  defp with_telemetry_context(_config, _telemetry_ref, fun), do: fun.()

  defp empty_turn_stats, do: %{iterations: 0, tool_call_count: 0}

  defp collect_turn_stats(state, %Event{type: :step_start}),
    do: update_in(state.turn_stats.iterations, &(&1 + 1))

  defp collect_turn_stats(state, %Event{type: :tool_start}),
    do: update_in(state.turn_stats.tool_call_count, &(&1 + 1))

  defp collect_turn_stats(state, %Event{}), do: state

  defp exception_type(kind) when kind in [:error, :exit, :throw], do: kind

  defp normalize_result(result, fallback_state, turn_usage) do
    case result do
      {status, %State{} = final_state} when status in [:ok, :error, :cancelled] ->
        final_state = attach_turn_usage(final_state, turn_usage)
        {{status, final_state}, final_state}

      _ ->
        {result, fallback_state}
    end
  end

  defp process_tackle_event(state, %Event{type: :message_start, data: data} = event) do
    state
    |> persist_pending_message(data)
    |> update_streaming(event)
    |> collect_turn_usage(event)
    |> collect_turn_stats(event)
    |> tap(&broadcast(&1, {:agent_event, event}))
    |> tap(&notify_runtime_event(&1, event))
  end

  defp process_tackle_event(
         state,
         %Event{type: :message_end, data: %{message: %Message{} = message}} = event
       ) do
    state
    |> update_snapshot_message(message)
    |> forward_event(event)
  end

  defp process_tackle_event(state, %Event{} = event), do: forward_event(state, event)

  defp forward_event(state, event) do
    state
    |> update_streaming(event)
    |> collect_turn_usage(event)
    |> collect_turn_stats(event)
    |> tap(&broadcast(&1, {:agent_event, event}))
    |> tap(&notify_runtime_event(&1, event))
  end

  defp update_snapshot_message(%{agent_state: %State{} = agent_state} = state, message) do
    if Enum.any?(agent_state.messages, &(&1.id == message.id)) do
      state
    else
      %{state | agent_state: State.add_message(agent_state, message)}
    end
  end

  defp update_snapshot_message(state, _message), do: state

  defp update_streaming(state, event) do
    Map.update(
      state,
      :streaming_messages,
      EventReducer.project_streaming(%{}, event),
      fn messages ->
        EventReducer.project_streaming(messages, event)
      end
    )
  end

  defp persist_pending_message(state, data) do
    store = state.config.store

    cond do
      function_exported?(store, :persist_pending_message, 3) ->
        update_host(state, &store.persist_pending_message(&1, data, state.turn_opts))

      function_exported?(store, :persist_pending_message, 2) ->
        update_host(state, &store.persist_pending_message(&1, data))

      true ->
        state
    end
  end

  defp settle_completed_turn(state, result) do
    turn_usage = aggregate_turn_usage(state.turn_usage)
    {result, agent_state} = normalize_result(result, state.agent_state, turn_usage)
    state = %{state | agent_state: agent_state}

    state =
      with_turn_context(state, fn ->
        state
        |> update_host(&state.config.store.settle_turn(&1, result, turn_usage, state.turn_opts))
        |> update_host(&state.config.store.after_turn(&1, result, state.turn_opts))
        |> stop_turn_telemetry(turn_outcome(result))
      end)

    {state, result}
  end

  defp fail_turn(state, reason) do
    turn_usage = aggregate_turn_usage(state.turn_usage)
    failure_opts = Keyword.put(state.turn_opts, :turn_usage, turn_usage)

    {host_state, agent_state} =
      state.config.store.handle_turn_failed(state.host_state, reason, failure_opts)

    state = %{state | host_state: host_state, agent_state: agent_state || state.agent_state}
    with_turn_context(state, fn -> exception_turn_telemetry(state, :task_exit) end)
  end

  defp update_host(state, fun), do: %{state | host_state: fun.(state.host_state)}

  defp init_host_state(store, host_state) do
    if function_exported?(store, :init_host, 1) do
      store.init_host(host_state)
    else
      host_state
    end
  end

  defp register_runtime(%{runtime_context: %AgentContext{} = context}) do
    AgentContext.register(context)
  end

  defp register_runtime(_config), do: :ok

  defp runtime_turn_opts(state, operation) do
    with {:ok, opts} <- normalize_run_turn_opts(Map.get(state.config, :runtime_turn_opts, [])) do
      metadata = Keyword.get(opts, :telemetry_metadata, %{})

      telemetry_ref =
        Telemetry.start([:tackle, :phoenix, :turn], Map.put(metadata, :operation, operation))

      {:ok,
       opts
       |> Keyword.put(:turn_telemetry_ref, telemetry_ref)
       |> Keyword.put(:turn_started_at, System.monotonic_time())}
    end
  end

  defp snapshot_value(state) do
    turn_active? = not is_nil(state.turn_task)

    %{
      agent_state: state.agent_state,
      session_id: current_session_id(state),
      turn_active?: turn_active?,
      streaming_messages: state.streaming_messages,
      runner_pid: if(turn_active?, do: self())
    }
  end

  defp notify_runtime_event(state, %Event{} = event) do
    state
    |> Map.get(:runtime_subscribers, MapSet.new())
    |> Enum.each(&send(&1, {:tackle_runtime_event, event}))

    :ok
  end

  defp notify_runtime_terminal(
         %{config: %{runtime_context: %AgentContext{terminal: terminal}}},
         result
       )
       when is_map(terminal) do
    send(terminal.destination, {:tackle_runtime_terminal, terminal.run_id, result})
    :ok
  end

  defp notify_runtime_terminal(_state, _result), do: :ok

  defp current_session_id(state), do: state.config.store.current_session_id(state.host_state)

  defp broadcast(%{initial_session_id: nil} = state, message) do
    PubSub.broadcast_turn(state.config.pubsub, state.user_id, current_session_id(state), message)
  end

  defp broadcast(state, message) do
    PubSub.broadcast(state.config.pubsub, state.user_id, current_session_id(state), message)
  end

  defp empty_turn_usage, do: %{}

  defp collect_turn_usage(state, %Event{type: :usage, data: data}) do
    case normalize_usage(Map.get(data, :usage)) do
      %Usage{} = usage ->
        Map.update!(state, :turn_usage, &Map.put(&1, :pending_step, usage))

      nil ->
        state
    end
  end

  defp collect_turn_usage(state, %Event{type: :step_end, data: data}) do
    settled_usage = Map.delete(state.turn_usage, :pending_step)
    usage = normalize_usage(Map.get(data, :usage)) || Map.get(state.turn_usage, :pending_step)

    case usage do
      %Usage{} = usage ->
        iteration = Map.get(data, :iteration) || map_size(settled_usage)
        %{state | turn_usage: Map.put(settled_usage, iteration, usage)}

      nil ->
        %{state | turn_usage: settled_usage}
    end
  end

  defp collect_turn_usage(state, %Event{}), do: state

  defp normalize_usage(nil), do: nil
  defp normalize_usage(%Usage{} = usage), do: nonzero_usage(usage)
  defp normalize_usage(%{} = usage), do: usage |> Usage.normalize() |> nonzero_usage()
  defp normalize_usage(_other), do: nil

  defp nonzero_usage(%Usage{} = usage), do: if(usage_total_tokens(usage) > 0, do: usage)

  defp usage_total_tokens(%Usage{} = usage) do
    input_and_output = (usage.input_tokens || 0) + (usage.output_tokens || 0)
    max(input_and_output, usage.total_tokens || 0)
  end

  defp aggregate_turn_usage(turn_usage) when is_map(turn_usage),
    do: Usage.aggregate(Map.values(turn_usage))

  defp attach_turn_usage(%State{} = final_state, %Usage{} = usage) do
    if usage_total_tokens(usage) > 0 and no_message_usage?(final_state.messages) do
      %{final_state | messages: attach_usage_to_final_assistant(final_state.messages, usage)}
    else
      final_state
    end
  end

  defp no_message_usage?(messages),
    do: Enum.all?(messages, &(normalize_usage(&1.token_usage) == nil))

  defp attach_usage_to_final_assistant(messages, %Usage{} = usage) do
    case find_final_assistant_index(messages) do
      nil -> messages
      index -> List.update_at(messages, index, &%{&1 | token_usage: Usage.to_map(usage)})
    end
  end

  defp find_final_assistant_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {message, index} -> if final_assistant_message?(message), do: index end)
  end

  defp final_assistant_message?(%Message{
         role: :assistant,
         content: content,
         tool_calls: tool_calls
       }) do
    content not in [nil, ""] and tool_calls in [nil, []]
  end

  defp final_assistant_message?(_message), do: false

  defp put_persisted_session_id(%State{} = state, session_id) when is_binary(session_id) do
    %{state | context: put_in(state.context, [:persistence, :session_id], session_id)}
  end

  defp put_persisted_session_id(%State{} = state, _session_id), do: state

  defp mark_message_persisted(%State{} = state, message_id) do
    context =
      update_in(state.context, [:persistence, :persisted_ids], fn
        %MapSet{} = persisted_ids ->
          MapSet.put(persisted_ids, message_id)

        persisted_ids when is_list(persisted_ids) ->
          persisted_ids |> MapSet.new() |> MapSet.put(message_id)

        _ ->
          MapSet.new([message_id])
      end)

    %{state | context: context}
  end

  defp store_turn_opts(opts), do: Keyword.drop(opts, @runner_internal_turn_opts)

  defp normalize_run_turn_opts(opts) when is_list(opts) do
    user_message_id = Keyword.get(opts, :user_message_id)
    pre_persisted_message? = Keyword.get(opts, :pre_persisted_message?, false)

    with :ok <- validate_user_message_id(user_message_id),
         {:ok, turn_metadata} <- normalize_turn_metadata(Keyword.get(opts, :turn_metadata, %{})),
         :ok <- validate_pre_persisted_message(pre_persisted_message?, user_message_id) do
      {:ok,
       opts
       |> Keyword.put(:turn_metadata, turn_metadata)
       |> Keyword.put(:pre_persisted_message?, pre_persisted_message?)}
    else
      {:error, field} -> {:error, {:invalid_turn_option, field}}
    end
  end

  defp normalize_run_turn_opts(_opts), do: {:error, {:invalid_turn_option, :options}}

  defp normalize_turn_metadata(metadata) when map_size(metadata) == 0, do: {:ok, %{}}

  defp normalize_turn_metadata(metadata) when is_map(metadata) and map_size(metadata) == 2 do
    with {:ok, kind} <- fetch_metadata_value(metadata, :kind),
         :ok <- validate_bounded_binary(kind, @max_turn_kind_bytes),
         {:ok, source_session_id} <- fetch_metadata_value(metadata, :source_session_id),
         :ok <- validate_bounded_binary(source_session_id, @max_source_session_id_bytes) do
      {:ok, %{kind: kind, source_session_id: source_session_id}}
    else
      _ -> {:error, :turn_metadata}
    end
  end

  defp normalize_turn_metadata(_metadata), do: {:error, :turn_metadata}

  defp fetch_metadata_value(metadata, key) do
    string_key = Atom.to_string(key)

    case {Map.fetch(metadata, key), Map.fetch(metadata, string_key)} do
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      _ -> :error
    end
  end

  defp validate_user_message_id(nil), do: :ok

  defp validate_user_message_id(value) do
    case validate_bounded_binary(value, @max_message_id_bytes) do
      :ok -> :ok
      {:error, _reason} -> {:error, :user_message_id}
    end
  end

  defp validate_bounded_binary(value, max_bytes)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes,
       do: :ok

  defp validate_bounded_binary(_value, _max_bytes), do: {:error, :bounded_binary}

  defp validate_pre_persisted_message(false, _user_message_id), do: :ok

  defp validate_pre_persisted_message(true, user_message_id) when is_binary(user_message_id),
    do: :ok

  defp validate_pre_persisted_message(true, _user_message_id), do: {:error, :user_message_id}

  defp validate_pre_persisted_message(_value, _user_message_id),
    do: {:error, :pre_persisted_message?}

  defp build_registry_key(user_id, nil), do: {:current, user_id}
  defp build_registry_key(user_id, session_id), do: {:session, user_id, session_id}
end
