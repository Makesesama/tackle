defmodule Tackle.Session do
  @moduledoc """
  Frontend-independent ownership of one in-memory agent session.

  A session owns settled `Tackle.Lib.State`, permits one active turn, runs that
  turn under a supervised task, forwards correlated library events to
  subscribers, and owns cancellation-signal cleanup.

  ## Scoped sessions

  Every session runs under a `Tackle.Runtime.ScopeRef` scope. It runs its turn
  tasks under the scope's shared `Tackle.AgentScope.WorkSupervisor`, registers
  itself in the runtime Registry, and accounts for its turn through the scope
  coordinator. A session without scoped runtime ownership fails to initialize:
  there is no unscoped fallback supervisor. Each session also runs beneath a
  `Tackle.Session.Supervisor` that owns its per-session tool `Task.Supervisor`, so
  concurrent tool execution is isolated per agent.

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
  alias Tackle.Lib.Compaction
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
  alias Tackle.Session.Journal
  alias Tackle.Session.Loader
  alias Tackle.Session.Persistence
  alias Tackle.Session.Projection
  alias Tackle.Session.Spec, as: SessionSpec
  alias Tackle.Session.Tree, as: SessionTree

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
    defstruct [:session_id, :agent_state, :active_turn, :stats, :agent_ref, :scope_ref, :recovery]

    @type active_turn :: %{
            required(:id) => String.t(),
            required(:operation) => :run | :continue,
            required(:cancellation_requested?) => boolean()
          }

    @type recovery :: %{
            required(:turn_id) => String.t(),
            required(:operation) => term(),
            required(:uncertain_tools) => [map()]
          }

    @type t :: %__MODULE__{
            session_id: String.t(),
            agent_state: Tackle.Lib.State.t(),
            active_turn: active_turn() | nil,
            stats: Tackle.Session.Stats.t() | nil,
            agent_ref: AgentRef.t() | nil,
            scope_ref: ScopeRef.t() | nil,
            recovery: recovery() | nil
          }
  end

  @type turn_result ::
          {:ok, AgentState.t()} | {:error, AgentState.t()} | {:cancelled, AgentState.t()}

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

  @doc """
  Runs one manual compaction of the model surface while the session is idle.

  Manual compaction shares the automatic transaction: plan, summarize, strictly
  validate, commit durably, then install. It is rejected during an active turn
  or while an interrupted turn requires an explicit recovery decision.

  `opts` may carry `:instructions` to add operator focus; it never removes the
  default summary invariants.
  """
  @spec compact(GenServer.server(), keyword()) ::
          {:ok, Snapshot.t(), Tackle.Lib.Compaction.Record.t()}
          | {:error, term()}
  def compact(session, opts \\ []) when is_list(opts),
    do: GenServer.call(session, {:compact, opts}, :infinity)

  @doc """
  Explicitly abandons an interrupted turn so durable resume can continue.

  A resumed session whose journal ends with `turn.started` and no terminal
  event is interrupted. Automatic continuation is prohibited while unresolved
  tools may have produced external effects; the frontend must inspect the
  uncertainty and call this to record `turn.abandoned` before new work.
  """
  @spec abandon_turn(GenServer.server()) :: :ok | {:error, term()}
  def abandon_turn(session), do: GenServer.call(session, :abandon_turn)

  @doc "Updates model and thinking settings while the session is idle."
  @spec reconfigure(GenServer.server(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def reconfigure(session, opts) when is_list(opts),
    do: GenServer.call(session, {:reconfigure, opts})

  def reconfigure(_session, opts), do: {:error, {:invalid_config, opts}}

  @doc """
  Reads the session's conversation tree, or `nil` when branching is disabled.
  """
  @spec tree(GenServer.server()) :: {:ok, Tackle.Lib.Tree.t() | nil}
  def tree(session), do: GenServer.call(session, :tree)

  @doc """
  Navigates the session's conversation tree while it is idle.

  Navigation is rejected during an active turn or while an interrupted turn
  requires an explicit recovery decision. The destination is validated, the
  committed position is persisted through the tree committer, and only then is
  the new position installed and published to subscribers.

  `target` is described in `Tackle.Lib.Tree.Navigator`; `opts` may carry
  `:expected_revision` and `:mode`. Returns the post-navigation snapshot and the
  navigation outcome, which can expose the selected user message as a draft.
  """
  @spec navigate(GenServer.server(), Tackle.Lib.Tree.Navigator.target(), keyword()) ::
          {:ok, Snapshot.t(), Tackle.Lib.Tree.Navigator.outcome()} | {:error, term()}
  def navigate(session, target, opts \\ []) when is_list(opts),
    do: GenServer.call(session, {:navigate, target, opts}, :infinity)

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
    coordinator = Keyword.get(opts, :coordinator) || coordinator_pid(scope_ref)
    work_supervisor = Keyword.get(opts, :work_supervisor) || work_supervisor(scope_ref)
    tool_supervisor = Keyword.get(opts, :tool_supervisor)

    with :ok <-
           validate_ownership(scope_ref, agent_ref, coordinator, work_supervisor, tool_supervisor),
         :ok <- register(scope_ref, agent_ref),
         {:ok, agent_state, journal, recovery} <-
           build_agent_state(config, scope_ref, agent_ref, opts) do
      state = %{
        config: config,
        agent_state: agent_state,
        active_turn: nil,
        subscribers: %{},
        scope_ref: scope_ref,
        agent_ref: agent_ref,
        coordinator: coordinator,
        lifetime: Keyword.get(opts, :lifetime, :explicit),
        parent: Keyword.get(opts, :parent),
        terminal: Keyword.get(opts, :terminal),
        work_supervisor: work_supervisor,
        tool_supervisor: tool_supervisor,
        journal: journal,
        recovery: recovery
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

  def handle_call(:abandon_turn, _from, %{recovery: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:abandon_turn, _from, %{journal: journal, recovery: recovery} = state)
      when not is_nil(journal) do
    case Journal.settle_turn(journal, "turn.abandoned", %{
           "turn_id" => recovery.turn_id,
           "reason" => "abandoned_by_frontend"
         }) do
      :ok -> {:reply, :ok, %{state | recovery: nil}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:compact, _opts}, _from, %{active_turn: active_turn} = state)
      when not is_nil(active_turn) do
    {:reply, {:error, :turn_in_progress}, state}
  end

  def handle_call({:compact, _opts}, _from, %{recovery: recovery} = state)
      when not is_nil(recovery) do
    {:reply, {:error, {:recovery_required, recovery}}, state}
  end

  def handle_call({:compact, opts}, _from, state) do
    session_id = state.agent_state.session_id
    event_callback = fn event -> broadcast(state, {:tackle_compaction, session_id, event}) end

    compaction_opts =
      opts
      |> Keyword.take([:instructions])
      |> Keyword.put(:event_callback, event_callback)

    case Compaction.compact(state.agent_state, :manual, compaction_opts) do
      {:ok, agent_state, record} ->
        state = %{state | agent_state: agent_state}
        snapshot = build_snapshot(state)
        broadcast(state, {:tackle_session_compacted, session_id, snapshot, record})
        {:reply, {:ok, snapshot, record}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:cancelled, reason} ->
        {:reply, {:error, {:cancelled, reason}}, state}
    end
  end

  def handle_call(:cancel, _from, %{active_turn: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:tree, _from, state) do
    {:reply, {:ok, state.agent_state.tree}, state}
  end

  def handle_call({:navigate, _target, _opts}, _from, %{active_turn: active} = state)
      when not is_nil(active) do
    {:reply, {:error, :turn_in_progress}, state}
  end

  def handle_call({:navigate, _target, _opts}, _from, %{recovery: recovery} = state)
      when not is_nil(recovery) do
    {:reply, {:error, {:recovery_required, recovery}}, state}
  end

  def handle_call({:navigate, target, opts}, _from, state) do
    case Tackle.Lib.navigate(state.agent_state, target, opts) do
      {:ok, agent_state, outcome} ->
        state = %{state | agent_state: agent_state}
        snapshot = build_snapshot(state)

        broadcast(
          state,
          {:tackle_session_navigated, agent_state.session_id, snapshot, outcome}
        )

        {:reply, {:ok, snapshot, outcome}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
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
        case persist_configuration(state, config) do
          :ok ->
            agent_state = apply_configuration(state.agent_state, config)
            state = %{state | config: config, agent_state: agent_state}
            snapshot = build_snapshot(state)
            broadcast(state, {:tackle_session_reconfigured, snapshot.session_id, snapshot})
            {:reply, {:ok, snapshot}, state}

          {:error, reason} ->
            {:stop, {:persistence_failed, reason}, {:error, reason}, state}
        end

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
    case persist_close(state) do
      :ok ->
        broadcast(state, {:tackle_session_closed, state.agent_state.session_id})
        {:stop, :normal, :ok, state}

      {:error, reason} ->
        {:stop, {:persistence_failed, reason}, {:error, reason}, state}
    end
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
        case persist_terminal(state, result) do
          :ok ->
            state = %{state | agent_state: agent_state, active_turn: nil}

            broadcast(
              state,
              {:tackle_turn_finished, agent_state.session_id, active_turn.id, result}
            )

            settle(state, result)

          {:error, reason} ->
            {:stop, {:persistence_failed, reason}, %{state | active_turn: nil}}
        end

      invalid_result ->
        reason = {:invalid_turn_result, invalid_result}

        case persist_terminal(state, {:runtime_error, reason}) do
          :ok ->
            state = %{state | active_turn: nil}
            broadcast_turn_failure(state, active_turn.id, reason)
            settle(state, {:runtime_error, reason})

          {:error, persist_reason} ->
            {:stop, {:persistence_failed, persist_reason}, %{state | active_turn: nil}}
        end
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{active_turn: %{task: %TurnTask{monitor: monitor}} = active_turn} = state
      ) do
    Cancellation.delete(active_turn.signal)
    release_turn(state)
    terminate_tool_tasks(state)

    case persist_terminal(state, {:runtime_error, reason}) do
      :ok ->
        state = %{state | active_turn: nil}
        broadcast_turn_failure(state, active_turn.id, reason)
        settle(state, {:runtime_error, reason})

      {:error, persist_reason} ->
        {:stop, {:persistence_failed, persist_reason}, %{state | active_turn: nil}}
    end
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

  defp start_turn(_operation, _input, %{recovery: recovery} = state)
       when not is_nil(recovery) do
    {:reply, {:error, {:recovery_required, recovery}}, state}
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
    run_opts = turn_opts(state, session_pid, turn_id, signal)

    case begin_turn(state, operation, input, turn_id) do
      :ok ->
        launch_turn(operation, input, state, agent_state, run_opts, signal, turn_id)

      {:error, reason} ->
        Cancellation.delete(signal)
        release_turn(state)
        {:reply, {:error, {:persistence_failed, reason}}, state}
    end
  end

  defp launch_turn(operation, input, state, agent_state, run_opts, signal, turn_id) do
    case start_turn_task(state.work_supervisor, fn ->
           run_operation(operation, agent_state, input, run_opts)
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

  defp start_turn_task(work_supervisor, fun), do: TurnTask.start(work_supervisor, fun)

  defp run_operation(:run, agent_state, input, run_opts) do
    Tackle.Lib.run(agent_state, input, run_opts)
  end

  defp run_operation(:continue, agent_state, _input, run_opts) do
    Tackle.Lib.continue(agent_state, run_opts)
  end

  defp turn_opts(state, session_pid, turn_id, signal) do
    [
      event_callback: fn event -> send(session_pid, {:tackle_event, turn_id, event}) end,
      cancellation_signal: signal,
      llm_stream: state.config.llm_stream,
      tool_supervisor: state.tool_supervisor
    ]
  end

  defp acquire_turn(%{coordinator: coordinator, agent_ref: %AgentRef{} = agent_ref}) do
    Coordinator.acquire_turn(coordinator, agent_ref)
  catch
    :exit, _reason -> {:error, :runtime_unavailable}
  end

  defp release_turn(%{coordinator: coordinator, agent_ref: %AgentRef{} = agent_ref}) do
    Coordinator.release_turn(coordinator, agent_ref)
  catch
    :exit, _reason -> :ok
  end

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
        allow_delegation: Keyword.get(opts, :allow_delegation, false),
        limits: Keyword.get(opts, :limits, Limits.default())
      )

    context =
      agent_state.context
      |> Map.put(:runtime, handle)
      |> Map.merge(Keyword.get(opts, :context_overrides, %{}))

    %{agent_state | context: context}
  end

  defp put_runtime_context(agent_state, _scope_ref, _agent_ref, _opts), do: agent_state

  defp build_agent_state(config, scope_ref, agent_ref, opts) do
    case Keyword.get(opts, :durable) do
      nil ->
        agent_state =
          config
          |> Config.to_agent_state(credential_store: Auth.credential_store())
          |> put_runtime_context(scope_ref, agent_ref, opts)

        {:ok, agent_state, nil, nil}

      %SessionSpec{} = durable ->
        build_durable_agent_state(config, scope_ref, agent_ref, opts, durable)
    end
  end

  defp build_durable_agent_state(config, scope_ref, agent_ref, opts, durable) do
    with {:ok, journal} <- Journal.whereis(durable.session_id),
         {:ok, projection} <- Journal.projection(journal),
         {:ok, loaded} <-
           Loader.load(projection, config,
             credential_store: Auth.credential_store(),
             override_config: durable.override_config,
             tree: durable.tree
           ),
         :ok <- persist_configuration_change(journal, loaded.configuration_changed?, config),
         :ok <- enable_tree_if_needed(journal, projection, durable.tree) do
      agent_state =
        loaded.state
        |> put_runtime_context(scope_ref, agent_ref, opts)
        |> install_persistence_hook()
        |> install_compaction_committer()
        |> install_tree_committer()

      {:ok, agent_state, journal, recovery_for(projection)}
    end
  end

  # A legacy linear journal is never rewritten; enabling branching appends one
  # explicit versioned transition before any tree-specific write.
  defp enable_tree_if_needed(_journal, _projection, false), do: :ok
  defp enable_tree_if_needed(_journal, %Projection{tree_enabled?: true}, true), do: :ok
  defp enable_tree_if_needed(journal, _projection, true), do: Journal.enable_tree(journal)

  defp install_compaction_committer(%AgentState{compaction: nil} = state), do: state

  defp install_compaction_committer(%AgentState{} = state) do
    # Durable sessions commit the compaction record through the journal before
    # the library installs the replacement in memory.
    config = Compaction.Config.put_committer(state.compaction, Tackle.Session.Compaction)
    %{state | compaction: config}
  end

  defp install_persistence_hook(%AgentState{} = state) do
    # The hook module is added directly rather than through Config's module
    # validation, so ensure it is loaded before the loop's function_exported?
    # dispatch can see it.
    _ = Code.ensure_loaded(Persistence)
    %{state | hooks: state.hooks ++ [Persistence]}
  end

  defp install_tree_committer(%AgentState{tree: nil} = state), do: state

  defp install_tree_committer(%AgentState{} = state) do
    # Durable tree navigations are committed through the journal before the
    # library installs the new active position.
    %{state | tree_committer: SessionTree}
  end

  defp recovery_for(%Projection{} = projection) do
    case projection.active_turn do
      nil ->
        nil

      %{} = turn ->
        %{
          turn_id: turn.turn_id,
          operation: turn.operation,
          uncertain_tools: Map.get(turn, :pending_tools, [])
        }
    end
  end

  defp persist_configuration_change(_journal, false, _config), do: :ok

  defp persist_configuration_change(journal, true, config) do
    Journal.configuration_changed(journal, config)
  end

  defp begin_turn(%{journal: nil}, _operation, _input, _turn_id), do: :ok

  defp begin_turn(%{journal: journal}, operation, input, turn_id) do
    case Journal.begin_turn(journal, operation, input, turn_id) do
      {:ok, _turn_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_terminal(%{journal: nil}, _result), do: :ok

  defp persist_terminal(%{journal: journal, active_turn: %{id: turn_id}}, result) do
    {type, data} = terminal_event(result)
    Journal.settle_turn(journal, type, Map.put(data, "turn_id", turn_id))
  end

  defp terminal_event({:ok, _agent_state}), do: {"turn.completed", %{"status" => "completed"}}

  defp terminal_event({:error, %AgentState{} = agent_state}),
    do: {"turn.errored", %{"error" => agent_state.error}}

  defp terminal_event({:cancelled, %AgentState{} = agent_state}),
    do: {"turn.cancelled", %{"reason" => agent_state.error}}

  defp terminal_event({:runtime_error, reason}),
    do: {"turn.crashed", %{"reason" => inspect(reason)}}

  defp persist_configuration(%{journal: nil}, _config), do: :ok

  defp persist_configuration(%{journal: journal}, config) do
    Journal.configuration_changed(journal, config)
  end

  defp persist_close(%{journal: nil}), do: :ok
  defp persist_close(%{journal: journal}), do: Journal.close_journal(journal)

  defp validate_ownership(%ScopeRef{}, %AgentRef{}, coordinator, work_supervisor, tool_supervisor)
       when not is_nil(coordinator) and not is_nil(work_supervisor) and
              not is_nil(tool_supervisor),
       do: :ok

  defp validate_ownership(scope_ref, _agent_ref, _coordinator, _work_supervisor, _tool_supervisor)
       when not is_struct(scope_ref, ScopeRef),
       do: {:error, {:missing_scope_ownership, :scope_ref}}

  defp validate_ownership(_scope_ref, agent_ref, _coordinator, _work_supervisor, _tool_supervisor)
       when not is_struct(agent_ref, AgentRef),
       do: {:error, {:missing_scope_ownership, :agent_ref}}

  defp validate_ownership(
         _scope_ref,
         _agent_ref,
         _coordinator,
         _work_supervisor,
         _tool_supervisor
       ),
       do: {:error, :missing_scope_supervision}

  defp register(%ScopeRef{} = scope_ref, %AgentRef{scope_id: scope_id} = agent_ref)
       when scope_ref.scope_id == scope_id do
    case Registry.register(agent_ref, :agent) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :already_registered}
    end
  end

  defp register(%ScopeRef{}, %AgentRef{}), do: {:error, :scope_mismatch}

  defp register_with_coordinator(%{coordinator: coordinator, agent_ref: %AgentRef{} = agent_ref}) do
    Coordinator.register_agent(coordinator, agent_ref, self())
  catch
    :exit, _reason -> :ok
  end

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
      scope_ref: state.scope_ref,
      recovery: state.recovery
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

  # A crashed turn can leave tool tasks running under the session's tool
  # supervisor. Only one turn runs at a time, so none of them belong to any
  # future work and they are terminated here instead of leaking.
  defp terminate_tool_tasks(%{tool_supervisor: nil}), do: :ok

  defp terminate_tool_tasks(%{tool_supervisor: supervisor}) do
    supervisor
    |> Task.Supervisor.children()
    |> Enum.each(&Task.Supervisor.terminate_child(supervisor, &1))

    :ok
  catch
    :exit, _reason -> :ok
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
