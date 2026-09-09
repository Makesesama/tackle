defmodule Tackle.Session do
  @moduledoc """
  Frontend-independent ownership of one in-memory agent session.

  A session owns settled `Tackle.Lib.State`, permits one active turn, runs that
  turn under a supervised task, forwards correlated library events to
  subscribers, and owns cancellation-signal cleanup.

  ## Scoped sessions

  A session started with a `Tackle.Runtime.ScopeRef` runs its turn tasks under
  the scope's shared `Tackle.AgentScope.WorkSupervisor`, registers itself in the
  runtime Registry, and accounts for its turn through the scope coordinator.
  The legacy `start_child/1` path keeps the original global task supervisor for
  compatibility while callers migrate to scoped references.

  An `:ephemeral` session delivers one correlated terminal outcome to its
  request helper and then stops. A session process is never reset for another
  agent identity.

  Subscription during an active turn is deliberately rejected because events
  are not replayed. Subscribe before submitting a turn to avoid a
  snapshot/event ordering gap.
  """

  use GenServer, restart: :temporary

  alias Tackle.AgentScope.Coordinator
  alias Tackle.Auth
  alias Tackle.Config
  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Event
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Handle
  alias Tackle.Runtime.Limits
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.Registry
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.Task, as: TurnTask

  @task_shutdown_timeout 1_000

  defmodule Stats do
    @moduledoc "Derived, immutable token, cost, model, and context statistics."

    alias Tackle.Lib.ContextUsage
    alias Tackle.Lib.Message
    alias Tackle.Lib.State
    alias Tackle.Lib.Usage

    @enforce_keys [:usage]
    defstruct [:usage, :latest_usage, :model_info, :context_usage]

    @type t :: %__MODULE__{
            usage: Usage.t(),
            latest_usage: Usage.t() | nil,
            model_info: Tackle.Lib.ModelInfo.t() | nil,
            context_usage: ContextUsage.t() | nil
          }

    @doc "Derives statistics from assistant-message usage and the selected model."
    @spec from_agent_state(State.t()) :: t()
    def from_agent_state(%State{} = state) do
      %__MODULE__{
        usage: State.usage(state),
        latest_usage: latest_usage(state.messages),
        model_info: model_info(state),
        context_usage: ContextUsage.estimate(state)
      }
    end

    defp model_info(%State{llm: %{model_info: model_info}}), do: model_info
    defp model_info(%State{}), do: nil

    defp latest_usage(messages) do
      Enum.find_value(Enum.reverse(messages), fn
        %Message{role: :assistant, token_usage: usage} when not is_nil(usage) ->
          Usage.normalize(usage)

        _message ->
          nil
      end)
    end
  end

  defmodule Snapshot do
    @moduledoc "An atomic view of a Tackle session and its active turn."

    @enforce_keys [:session_id, :agent_state]
    defstruct [:session_id, :agent_state, :active_turn, :stats, :agent_ref, :scope_ref]

    @type active_turn :: %{
            required(:id) => String.t(),
            required(:operation) => :run | :continue,
            required(:cancellation_requested?) => boolean()
          }

    @type t :: %__MODULE__{
            session_id: String.t(),
            agent_state: Tackle.Lib.State.t(),
            active_turn: active_turn() | nil,
            stats: Tackle.Session.Stats.t() | nil,
            agent_ref: AgentRef.t() | nil,
            scope_ref: ScopeRef.t() | nil
          }
  end

  @type turn_result ::
          {:ok, AgentState.t()} | {:error, AgentState.t()} | {:cancelled, AgentState.t()}

  @doc false
  @spec start_child(Config.t()) :: DynamicSupervisor.on_start_child()
  def start_child(%Config{} = config) do
    DynamicSupervisor.start_child(Tackle.SessionSupervisor, {__MODULE__, config})
  end

  @doc false
  @spec start_link(Config.t() | {Config.t(), keyword()}) :: GenServer.on_start()
  def start_link(%Config{} = config), do: start_link(config, [])
  def start_link({%Config{} = config, opts}), do: start_link(config, opts)

  def start_link(%Config{} = config, opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, {config, opts}, session_name(opts))
  end

  @doc false
  def child_spec(%Config{} = config), do: child_spec({config, []})

  def child_spec({%Config{} = config, opts}) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [config, opts]},
      restart: Keyword.get(opts, :restart, :temporary)
    }
  end

  @doc "Starts a turn and appends `input` as one user message."
  @spec submit(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def submit(session, input) when is_binary(input), do: GenServer.call(session, {:submit, input})
  def submit(_session, input), do: {:error, {:invalid_input, input}}

  @doc "Continues the current conversation without appending another user message."
  @spec continue(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def continue(session), do: GenServer.call(session, :continue)

  @doc "Requests cooperative cancellation of the active turn."
  @spec cancel(GenServer.server()) :: :ok
  def cancel(session), do: GenServer.call(session, :cancel)

  @doc "Updates model and thinking settings while the session is idle."
  @spec reconfigure(GenServer.server(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def reconfigure(session, opts) when is_list(opts),
    do: GenServer.call(session, {:reconfigure, opts})

  def reconfigure(_session, opts), do: {:error, {:invalid_config, opts}}

  @doc "Returns an atomic session snapshot."
  @spec snapshot(GenServer.server()) :: Snapshot.t()
  def snapshot(session), do: GenServer.call(session, :snapshot)

  @doc """
  Subscribes the caller and returns the snapshot at the subscription boundary.

  Active-turn attachment is not supported until replay or event projection is
  defined, so this returns `{:error, :turn_in_progress}` during a turn.
  """
  @spec subscribe(GenServer.server()) :: {:ok, Snapshot.t()} | {:error, :turn_in_progress}
  def subscribe(session), do: GenServer.call(session, :subscribe)

  @doc "Unsubscribes the caller from session deliveries."
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(session), do: GenServer.call(session, :unsubscribe)

  @doc "Closes the session and cleans up an active turn."
  @spec close(GenServer.server()) :: :ok
  def close(session), do: GenServer.call(session, :close, :infinity)

  @impl true
  def init({%Config{} = config, opts}) do
    Process.flag(:trap_exit, true)

    scope_ref = Keyword.get(opts, :scope_ref)
    agent_ref = Keyword.get(opts, :agent_ref)

    agent_state =
      config
      |> Config.to_agent_state(credential_store: Auth.credential_store())
      |> put_runtime_context(scope_ref, agent_ref, opts)

    with :ok <- register(scope_ref, agent_ref) do
      state = %{
        config: config,
        agent_state: agent_state,
        active_turn: nil,
        subscribers: %{},
        scope_ref: scope_ref,
        agent_ref: agent_ref,
        coordinator: Keyword.get(opts, :coordinator) || coordinator_pid(scope_ref),
        lifetime: Keyword.get(opts, :lifetime, :explicit),
        parent: Keyword.get(opts, :parent),
        terminal: Keyword.get(opts, :terminal),
        work_supervisor: Keyword.get(opts, :work_supervisor) || work_supervisor(scope_ref)
      }

      register_with_coordinator(state)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:submit, input}, _from, state) do
    start_turn(:run, input, state)
  end

  def handle_call(:continue, _from, state) do
    start_turn(:continue, nil, state)
  end

  def handle_call(:cancel, _from, %{active_turn: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:cancel, _from, state) do
    Cancellation.cancel(state.active_turn.signal, :user_cancelled)
    active_turn = %{state.active_turn | cancellation_requested?: true}
    {:reply, :ok, %{state | active_turn: active_turn}}
  end

  def handle_call({:reconfigure, _opts}, _from, %{active_turn: active_turn} = state)
      when not is_nil(active_turn) do
    {:reply, {:error, :turn_in_progress}, state}
  end

  def handle_call({:reconfigure, opts}, _from, state) do
    case Config.reconfigure(state.config, opts) do
      {:ok, config} ->
        agent_state = apply_configuration(state.agent_state, config)
        state = %{state | config: config, agent_state: agent_state}
        snapshot = build_snapshot(state)
        broadcast(state, {:tackle_session_reconfigured, snapshot.session_id, snapshot})
        {:reply, {:ok, snapshot}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_call(:subscribe, _from, %{active_turn: active_turn} = state)
      when not is_nil(active_turn) do
    {:reply, {:error, :turn_in_progress}, state}
  end

  def handle_call(:subscribe, {subscriber, _tag}, state) do
    subscribers = put_subscriber(state.subscribers, subscriber)
    state = %{state | subscribers: subscribers}
    {:reply, {:ok, build_snapshot(state)}, state}
  end

  def handle_call(:unsubscribe, {subscriber, _tag}, state) do
    {:reply, :ok, %{state | subscribers: drop_subscriber(state.subscribers, subscriber)}}
  end

  def handle_call(:close, _from, state) do
    broadcast(state, {:tackle_session_closed, state.agent_state.session_id})
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info(
        {:tackle_event, turn_id, %Event{} = event},
        %{active_turn: %{id: turn_id}} = state
      ) do
    event = project_usage_event(event, state.agent_state)

    broadcast(
      state,
      {:tackle_event, state.agent_state.session_id, turn_id, event}
    )

    {:noreply, state}
  end

  def handle_info({:tackle_event, _turn_id, %Event{}}, state), do: {:noreply, state}

  def handle_info(
        {ref, result},
        %{active_turn: %{task: %TurnTask{ref: ref}} = active_turn} = state
      ) do
    Process.demonitor(active_turn.task.monitor, [:flush])
    Cancellation.delete(active_turn.signal)
    release_turn(state)

    case result do
      {outcome, %AgentState{} = agent_state}
      when outcome in [:ok, :error, :cancelled] ->
        state = %{state | agent_state: agent_state, active_turn: nil}

        broadcast(
          state,
          {:tackle_turn_finished, agent_state.session_id, active_turn.id, result}
        )

        settle(state, result)

      invalid_result ->
        reason = {:invalid_turn_result, invalid_result}
        state = %{state | active_turn: nil}
        broadcast_turn_failure(state, active_turn.id, reason)
        settle(state, {:runtime_error, reason})
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{active_turn: %{task: %TurnTask{monitor: monitor}} = active_turn} = state
      ) do
    Cancellation.delete(active_turn.signal)
    release_turn(state)
    state = %{state | active_turn: nil}
    broadcast_turn_failure(state, active_turn.id, reason)
    settle(state, {:runtime_error, reason})
  end

  def handle_info({:runtime_cancel, reason}, state) do
    {:noreply, cancel_active_turn(state, reason)}
  end

  def handle_info({:DOWN, monitor_ref, :process, subscriber, _reason}, state) do
    subscribers =
      case Map.get(state.subscribers, subscriber) do
        ^monitor_ref -> Map.delete(state.subscribers, subscriber)
        _other -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl true
  def terminate(_reason, state) do
    cleanup_active_turn(state.active_turn)
    :ok
  end

  defp start_turn(_operation, _input, %{active_turn: active_turn} = state)
       when not is_nil(active_turn) do
    {:reply, {:error, :turn_in_progress}, state}
  end

  defp start_turn(operation, input, state) do
    case acquire_turn(state) do
      :ok ->
        do_start_turn(operation, input, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp do_start_turn(operation, input, state) do
    signal = Cancellation.new_signal()
    turn_id = state.config.id_generator.()
    session_pid = self()
    agent_state = state.agent_state
    run_opts = turn_opts(state.config, session_pid, turn_id, signal)

    case start_turn_task(state.work_supervisor, fn ->
           case operation do
             :run -> Tackle.Lib.run(agent_state, input, run_opts)
             :continue -> Tackle.Lib.continue(agent_state, run_opts)
           end
         end) do
      {:ok, task} ->
        active_turn = %{
          id: turn_id,
          operation: operation,
          task: task,
          signal: signal,
          cancellation_requested?: false
        }

        {:reply, {:ok, turn_id}, %{state | active_turn: active_turn}}

      {:error, reason} ->
        Cancellation.delete(signal)
        release_turn(state)
        {:reply, {:error, {:turn_task_failed, reason}}, state}
    end
  end

  defp start_turn_task(nil, fun) do
    task = Task.Supervisor.async_nolink(Tackle.TaskSupervisor, fun)
    {:ok, %TurnTask{pid: task.pid, ref: task.ref, monitor: task.ref, supervisor: nil}}
  end

  defp start_turn_task(work_supervisor, fun), do: TurnTask.start(work_supervisor, fun)

  defp turn_opts(config, session_pid, turn_id, signal) do
    [
      event_callback: fn event -> send(session_pid, {:tackle_event, turn_id, event}) end,
      cancellation_signal: signal,
      llm_stream: config.llm_stream
    ]
  end

  defp acquire_turn(%{coordinator: nil}), do: :ok

  defp acquire_turn(%{coordinator: coordinator, agent_ref: %AgentRef{} = agent_ref}) do
    Coordinator.acquire_turn(coordinator, agent_ref)
  catch
    :exit, _reason -> {:error, :runtime_unavailable}
  end

  defp acquire_turn(_state), do: :ok

  defp release_turn(%{coordinator: nil}), do: :ok

  defp release_turn(%{coordinator: coordinator, agent_ref: %AgentRef{} = agent_ref}) do
    Coordinator.release_turn(coordinator, agent_ref)
  catch
    :exit, _reason -> :ok
  end

  defp release_turn(_state), do: :ok

  defp settle(state, result) do
    deliver_terminal(state, result)

    if state.lifetime == :ephemeral do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp deliver_terminal(%{terminal: nil}, _result), do: :ok

  defp deliver_terminal(%{terminal: terminal} = state, result) do
    outcome = outcome_from_result(result, state)
    send(terminal.destination, {:tackle_runtime_terminal, terminal.run_id, outcome})
    :ok
  end

  defp outcome_from_result({:ok, %AgentState{} = agent_state}, state),
    do: Outcome.new(:ok, agent_state: agent_state, agent_ref: state.agent_ref)

  defp outcome_from_result({:error, %AgentState{} = agent_state}, state),
    do: Outcome.new(:error, agent_state: agent_state, agent_ref: state.agent_ref)

  defp outcome_from_result({:cancelled, %AgentState{} = agent_state}, state),
    do: Outcome.new(:cancelled, agent_state: agent_state, agent_ref: state.agent_ref)

  defp outcome_from_result({:runtime_error, reason}, state),
    do: Outcome.new(:runtime_error, reason: reason, agent_ref: state.agent_ref)

  defp cancel_active_turn(%{active_turn: nil} = state, _reason), do: state

  defp cancel_active_turn(%{active_turn: active_turn} = state, reason) do
    Cancellation.cancel(active_turn.signal, reason)
    %{state | active_turn: %{active_turn | cancellation_requested?: true}}
  end

  defp apply_configuration(agent_state, config) do
    llm_opts = Keyword.put(config.llm_opts, :credential_store, Auth.credential_store())

    %{agent_state | llm: config.llm, model: config.llm.model, llm_opts: llm_opts}
  end

  defp put_runtime_context(agent_state, %ScopeRef{} = scope_ref, %AgentRef{} = agent_ref, opts) do
    handle =
      Handle.new(scope_ref, agent_ref,
        allow_recursion: Keyword.get(opts, :allow_recursion, false),
        limits: Keyword.get(opts, :limits, Limits.default())
      )

    context =
      agent_state.context
      |> Map.put(:runtime, handle)
      |> Map.merge(Keyword.get(opts, :context_overrides, %{}))

    %{agent_state | context: context}
  end

  defp put_runtime_context(agent_state, _scope_ref, _agent_ref, _opts), do: agent_state

  defp register(nil, _agent_ref), do: :ok
  defp register(_scope_ref, nil), do: :ok

  defp register(%ScopeRef{} = scope_ref, %AgentRef{scope_id: scope_id} = agent_ref)
       when scope_ref.scope_id == scope_id do
    case Registry.register(agent_ref, :agent) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :already_registered}
    end
  end

  defp register(%ScopeRef{}, %AgentRef{}), do: {:error, :scope_mismatch}

  defp register_with_coordinator(%{coordinator: nil}), do: :ok

  defp register_with_coordinator(%{coordinator: coordinator, agent_ref: %AgentRef{} = agent_ref}) do
    Coordinator.register_agent(coordinator, agent_ref, self())
  catch
    :exit, _reason -> :ok
  end

  defp register_with_coordinator(_state), do: :ok

  defp coordinator_pid(%ScopeRef{} = scope_ref) do
    case Registry.coordinator(scope_ref) do
      {:ok, pid} -> pid
      {:error, :not_found} -> nil
    end
  end

  defp coordinator_pid(_scope_ref), do: nil

  defp work_supervisor(%ScopeRef{} = scope_ref) do
    case Registry.work_supervisor(scope_ref) do
      {:ok, pid} -> pid
      {:error, :not_found} -> nil
    end
  end

  defp work_supervisor(_scope_ref), do: nil

  defp session_name(opts) do
    case Keyword.get(opts, :name) do
      nil -> []
      name -> [name: name]
    end
  end

  defp build_snapshot(state) do
    active_turn =
      case state.active_turn do
        nil ->
          nil

        active_turn ->
          Map.take(active_turn, [:id, :operation, :cancellation_requested?])
      end

    %Snapshot{
      session_id: state.agent_state.session_id,
      agent_state: state.agent_state,
      active_turn: active_turn,
      stats: Stats.from_agent_state(state.agent_state),
      agent_ref: state.agent_ref,
      scope_ref: state.scope_ref
    }
  end

  defp project_usage_event(
         %Event{type: :usage, data: %{usage: usage} = data} = event,
         %AgentState{} = state
       ) do
    model_info = if state.llm, do: state.llm.model_info

    data =
      data
      |> Map.put_new(:model_info, model_info)
      |> Map.put_new(:context_usage, ContextUsage.from_usage(usage, model_info))

    %{event | data: data}
  end

  defp project_usage_event(%Event{} = event, _state), do: event

  defp put_subscriber(subscribers, subscriber) do
    case Map.fetch(subscribers, subscriber) do
      {:ok, _monitor_ref} -> subscribers
      :error -> Map.put(subscribers, subscriber, Process.monitor(subscriber))
    end
  end

  defp drop_subscriber(subscribers, subscriber) do
    case Map.pop(subscribers, subscriber) do
      {nil, subscribers} ->
        subscribers

      {monitor_ref, subscribers} ->
        Process.demonitor(monitor_ref, [:flush])
        subscribers
    end
  end

  defp broadcast(state, message) do
    Enum.each(state.subscribers, fn {subscriber, _monitor_ref} -> send(subscriber, message) end)
  end

  defp broadcast_turn_failure(state, turn_id, reason) do
    broadcast(
      state,
      {:tackle_turn_failed, state.agent_state.session_id, turn_id, reason}
    )
  end

  defp cleanup_active_turn(nil), do: :ok

  defp cleanup_active_turn(active_turn) do
    safe_cancellation(fn -> Cancellation.cancel(active_turn.signal, :session_closed) end)
    TurnTask.shutdown(active_turn.task, @task_shutdown_timeout)
    safe_cancellation(fn -> Cancellation.delete(active_turn.signal) end)
    :ok
  end

  # The default ETS cancellation store can lose its lazily-created table when
  # its owning process exits. Cleanup must not crash a terminating session.
  defp safe_cancellation(fun) do
    fun.()
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end
end
