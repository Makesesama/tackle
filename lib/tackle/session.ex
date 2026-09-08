defmodule Tackle.Session do
  @moduledoc """
  Frontend-independent ownership of one in-memory agent session.

  A session owns settled `Tackle.Lib.State`, permits one active turn, runs that
  turn under `Tackle.TaskSupervisor`, forwards correlated library events to
  subscribers, and owns cancellation-signal cleanup.

  Subscription during an active turn is deliberately rejected in this initial
  slice because events are not replayed. Subscribe before submitting a turn to
  avoid a snapshot/event ordering gap.
  """

  use GenServer, restart: :temporary

  alias Tackle.Auth
  alias Tackle.Config
  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Event
  alias Tackle.Lib.State, as: AgentState

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
    defstruct [:session_id, :agent_state, :active_turn, :stats]

    @type active_turn :: %{
            required(:id) => String.t(),
            required(:operation) => :run | :continue,
            required(:cancellation_requested?) => boolean()
          }

    @type t :: %__MODULE__{
            session_id: String.t(),
            agent_state: Tackle.Lib.State.t(),
            active_turn: active_turn() | nil,
            stats: Tackle.Session.Stats.t() | nil
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
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(%Config{} = config), do: GenServer.start_link(__MODULE__, config)

  def child_spec(%Config{} = config) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config]},
      restart: :temporary
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
  def init(%Config{} = config) do
    Process.flag(:trap_exit, true)

    agent_state =
      Config.to_agent_state(config, credential_store: Auth.credential_store())

    {:ok,
     %{
       config: config,
       agent_state: agent_state,
       active_turn: nil,
       subscribers: %{}
     }}
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
        %{active_turn: %{task: %Task{ref: ref}} = active_turn} = state
      ) do
    Process.demonitor(ref, [:flush])
    Cancellation.delete(active_turn.signal)

    case result do
      {outcome, %AgentState{} = agent_state}
      when outcome in [:ok, :error, :cancelled] ->
        state = %{state | agent_state: agent_state, active_turn: nil}

        broadcast(
          state,
          {:tackle_turn_finished, agent_state.session_id, active_turn.id, result}
        )

        {:noreply, state}

      invalid_result ->
        reason = {:invalid_turn_result, invalid_result}
        state = %{state | active_turn: nil}
        broadcast_turn_failure(state, active_turn.id, reason)
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{active_turn: %{task: %Task{ref: ref}} = active_turn} = state
      ) do
    Cancellation.delete(active_turn.signal)
    state = %{state | active_turn: nil}
    broadcast_turn_failure(state, active_turn.id, reason)
    {:noreply, state}
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
    signal = Cancellation.new_signal()
    turn_id = state.config.id_generator.()
    session_pid = self()
    agent_state = state.agent_state
    run_opts = turn_opts(state.config, session_pid, turn_id, signal)

    task =
      Task.Supervisor.async_nolink(Tackle.TaskSupervisor, fn ->
        case operation do
          :run -> Tackle.Lib.run(agent_state, input, run_opts)
          :continue -> Tackle.Lib.continue(agent_state, run_opts)
        end
      end)

    active_turn = %{
      id: turn_id,
      operation: operation,
      task: task,
      signal: signal,
      cancellation_requested?: false
    }

    {:reply, {:ok, turn_id}, %{state | active_turn: active_turn}}
  end

  defp turn_opts(config, session_pid, turn_id, signal) do
    [
      event_callback: fn event -> send(session_pid, {:tackle_event, turn_id, event}) end,
      cancellation_signal: signal,
      llm_stream: config.llm_stream
    ]
  end

  defp apply_configuration(agent_state, config) do
    llm_opts = Keyword.put(config.llm_opts, :credential_store, Auth.credential_store())

    %{agent_state | llm: config.llm, model: config.llm.model, llm_opts: llm_opts}
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
      stats: Stats.from_agent_state(state.agent_state)
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
    Cancellation.cancel(active_turn.signal, :session_closed)
    Task.shutdown(active_turn.task, @task_shutdown_timeout)
    Cancellation.delete(active_turn.signal)
    :ok
  end
end
