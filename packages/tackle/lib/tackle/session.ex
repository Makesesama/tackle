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
  there is no unscoped fallback supervisor. Each session runs beneath a
  `Tackle.Runtime.AgentSupervisor`, whose dedicated tool `Task.Supervisor` keeps
  concurrent tool execution isolated per agent.

  An `:ephemeral` session delivers one correlated terminal outcome to its
  request helper and then stops. A session process is never reset for another
  agent identity.

  Subscription during an active turn is deliberately rejected because events
  are not replayed. Subscribe before submitting a turn to avoid a
  snapshot/event ordering gap.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Tackle.AgentScope.Coordinator
  alias Tackle.Auth
  alias Tackle.Config
  alias Tackle.Config.SessionTitles
  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Compaction
  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Event
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Message
  alias Tackle.Lib.Messages
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Envelope
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.Registry
  alias Tackle.Runtime.RunRef
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.Task, as: TurnTask
  alias Tackle.Session.Committer
  alias Tackle.Session.Journal
  alias Tackle.Session.Journal.Watchdog
  alias Tackle.Session.Loader
  alias Tackle.Session.Persistence
  alias Tackle.Session.Projection
  alias Tackle.Session.Spec, as: SessionSpec
  alias Tackle.Session.Title

  @task_shutdown_timeout 1_000
  @max_inbox_messages 32
  @max_deferred_messages 128
  @max_inbox_bytes 24 * 1024 * 1024

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
    defstruct [
      :session_id,
      :agent_state,
      :active_turn,
      :stats,
      :agent_ref,
      :scope_ref,
      :recovery,
      session_title: nil,
      storage: :ready
    ]

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
            recovery: recovery() | nil,
            session_title: String.t() | nil,
            storage: :ready | :delayed
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

  @doc "Starts a turn, or queues input for the active turn's next provider boundary."
  @spec submit(GenServer.server(), String.t()) ::
          {:ok, String.t() | :queued} | {:error, term()}
  def submit(session, input) when is_binary(input),
    do: GenServer.call(session, {:submit, input}, :infinity)

  def submit(_session, input), do: {:error, {:invalid_input, input}}

  @doc "Withdraws the newest matching user message still waiting in the inbox."
  @spec withdraw_queued(GenServer.server(), String.t()) :: :ok | {:error, :not_queued}
  def withdraw_queued(session, content) when is_binary(content),
    do: GenServer.call(session, {:withdraw_queued, content})

  @doc "Continues the current conversation without appending another user message."
  @spec continue(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def continue(session), do: GenServer.call(session, :continue, :infinity)

  @doc """
  Requests cooperative cancellation of the active turn, or of a running manual
  compaction (`compact/2`, which then returns `{:error, {:cancelled, reason}}`).
  Does nothing when neither is running.
  """
  @spec cancel(GenServer.server()) :: :ok
  def cancel(session), do: GenServer.call(session, :cancel)

  @doc """
  Requests cancellation of one tool call of the active turn.

  Cancels the call's per-call signal (`Tackle.Lib.Cancellation.for_call/2`)
  with `reason`, so only that tool stops and reports an error while the turn
  continues. A binary `reason` is shown to the agent by tools such as `bash`.
  Cancelling a call that has already finished, or one that never existed,
  has no effect. Returns `{:error, :no_active_turn}` when the session is idle.
  """
  @spec cancel_tool_call(GenServer.server(), String.t(), term()) ::
          :ok | {:error, :no_active_turn}
  def cancel_tool_call(session, tool_call_id, reason) when is_binary(tool_call_id),
    do: GenServer.call(session, {:cancel_tool_call, tool_call_id, reason})

  @doc "Queues an envelope for the next provider boundary or an idle agent's next turn."
  @spec deliver(GenServer.server(), Envelope.t()) :: :ok | {:error, term()}
  def deliver(session, %Envelope{} = envelope),
    do: GenServer.call(session, {:deliver, envelope}, :infinity)

  @doc "Publishes one background-run completion event from its owning request helper."
  @spec background_finished(GenServer.server(), RunRef.t(), String.t() | nil, Outcome.t()) :: :ok
  def background_finished(session, %RunRef{} = run_ref, profile, %Outcome{} = outcome) do
    GenServer.cast(session, {:background_finished, run_ref, profile, outcome})
  end

  @doc """
  Publishes one auxiliary event to the session's subscribers.

  Agent services such as `Tackle.Narrator` use this to report outside any
  turn: the event is broadcast as `{:tackle_event, session_id, nil, event}`,
  whether the session is idle or mid-turn, and is never persisted, projected
  into the transcript, or counted as usage. Only auxiliary events
  (`Tackle.Lib.Event.auxiliary?/1`) are accepted; anything else returns
  `{:error, {:invalid_event, event}}` without reaching subscribers.
  """
  @spec publish_event(GenServer.server(), Event.t()) :: :ok | {:error, {:invalid_event, term()}}
  def publish_event(session, %Event{} = event) do
    if Event.auxiliary?(event),
      do: GenServer.cast(session, {:publish_event, event}),
      else: {:error, {:invalid_event, event}}
  end

  def publish_event(_session, event), do: {:error, {:invalid_event, event}}

  @doc "Returns queued in-scope messages awaiting the next turn."
  @spec inbox(GenServer.server()) :: [map()]
  def inbox(session), do: GenServer.call(session, :inbox)

  @doc """
  Runs one manual compaction of the model surface while the session is idle.

  Manual compaction shares the automatic transaction: plan, summarize, strictly
  validate, commit durably, then install. It is rejected during an active turn
  or while an interrupted turn requires an explicit recovery decision.

  `opts` may carry `:instructions` to add operator focus; it never removes the
  default summary invariants. If a later pass fails after an earlier checkpoint
  was committed, the session retains and broadcasts the committed projection
  even though the call returns an error. `cancel/1` stops a running manual
  compaction cooperatively.
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

  Abandoning also settles the interrupted turn's unresolved tool calls with
  synthetic results, so the transcript keeps the call/result pairing providers
  require and the session can accept new work afterwards.
  """
  @spec abandon_turn(GenServer.server()) :: :ok | {:error, term()}
  def abandon_turn(session), do: GenServer.call(session, :abandon_turn, :infinity)

  @doc "Updates model and thinking settings while the session is idle."
  @spec reconfigure(GenServer.server(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def reconfigure(session, opts) when is_list(opts),
    do: GenServer.call(session, {:reconfigure, opts}, :infinity)

  def reconfigure(_session, opts), do: {:error, {:invalid_config, opts}}

  @doc """
  Reads the session's conversation tree.

  Every session keeps one; in a session without branching it has a single
  branch.
  """
  @spec tree(GenServer.server()) :: {:ok, Tackle.Lib.Tree.t()}
  def tree(session), do: GenServer.call(session, :tree)

  @doc """
  Navigates the session's conversation tree while it is idle.

  Navigation is rejected with `{:error, :tree_disabled}` in a session without
  branching: an ephemeral session, or a durable one whose spec sets
  `tree: false` and whose journal never enabled it. It is also rejected
  during an active turn or while an interrupted turn requires an explicit
  recovery decision. The destination is validated, the
  committed position is persisted through the session's committer, and only
  then is the new position installed and published to subscribers.

  `target` is described in `Tackle.Lib.Tree.Navigator`. The only option is
  `:expected_revision`; any other option is ignored, and the change is always
  committed through the session's own journal. Returns the post-navigation
  snapshot and the navigation outcome, which can expose the selected user
  message as a draft.
  """
  @spec navigate(GenServer.server(), Tackle.Lib.Tree.Navigator.target(), keyword()) ::
          {:ok, Snapshot.t(), Tackle.Lib.Tree.Navigator.Outcome.t()} | {:error, term()}
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
         {:ok, agent_state, journal, recovery, tree_enabled?} <-
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
        recovery: recovery,
        tree_enabled?: tree_enabled?,
        inbox: :queue.new(),
        inbox_count: 0,
        inbox_wake_scheduled?: false,
        session_title: projection_title(journal),
        title_task: nil,
        storage_task: nil,
        storage_status: :ready
      }

      register_with_coordinator(state)
      status = if journal, do: Watchdog.subscribe(journal, self()), else: :ready
      {:ok, %{state | storage_status: status}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(operation, _from, state)
      when (not is_nil(state.storage_task) or state.storage_status == :delayed) and
             (operation in [:abandon_turn, :close] or
                (is_tuple(operation) and elem(operation, 0) in [:compact, :navigate, :reconfigure])),
      do: {:reply, {:error, :storage_busy}, state}

  def handle_call({:submit, _input}, _from, %{storage_task: task} = state)
      when not is_nil(task) or state.storage_status == :delayed,
      do: {:reply, {:error, :storage_busy}, state}

  def handle_call({:submit, _input}, _from, %{recovery: recovery} = state)
      when not is_nil(recovery) do
    {:reply, {:error, {:recovery_required, recovery}}, state}
  end

  def handle_call({:submit, input}, _from, %{active_turn: active_turn} = state)
      when not is_nil(active_turn) do
    queue_user_message(state, input)
  end

  def handle_call({:submit, input}, from, state) do
    start_turn(:run, input, state, from)
  end

  def handle_call(
        {:withdraw_queued, _content},
        _from,
        %{storage_task: %{kind: :begin_turn}} = state
      ),
      do: {:reply, {:error, :storage_busy}, state}

  def handle_call({:withdraw_queued, content}, _from, state) do
    entries = :queue.to_list(state.inbox)

    index =
      entries
      |> Enum.with_index()
      |> Enum.reduce(nil, fn
        {%{from: :user, message: ^content}, index}, _found -> index
        _entry, found -> found
      end)

    case index do
      nil ->
        {:reply, {:error, :not_queued}, state}

      index ->
        retained = List.delete_at(entries, index)
        state = %{state | inbox: :queue.from_list(retained), inbox_count: length(retained)}
        {:reply, :ok, state}
    end
  end

  # Runtime notices are one-shot; retain them in the existing bounded inbox,
  # but never start their continuation until storage is ready.
  def handle_call({:deliver, %Envelope{kind: kind} = envelope}, _from, state)
      when kind in [:completion, :launch] do
    case Envelope.new(envelope.kind, envelope.from, envelope.message, envelope.origin) do
      {:ok, _validated} -> enqueue_envelope(state, envelope)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:deliver, %Envelope{}}, _from_call, state)
      when not is_nil(state.storage_task) or state.storage_status == :delayed,
      do: {:reply, {:error, :storage_busy}, state}

  def handle_call({:deliver, %Envelope{} = envelope}, _from_call, state) do
    case Envelope.new(envelope.kind, envelope.from, envelope.message, envelope.origin) do
      {:ok, _validated} -> enqueue_envelope(state, envelope)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:take_incoming_messages, _from, state) do
    envelopes = deliverable_inbox(state)
    state = drop_deliverable_inbox(state)
    broadcast_inbox_drained(state, envelopes)
    {:reply, {:ok, Enum.map(envelopes, &envelope_content/1)}, state}
  end

  def handle_call(:continue, _from, %{storage_task: task} = state)
      when not is_nil(task) or state.storage_status == :delayed,
      do: {:reply, {:error, :storage_busy}, state}

  def handle_call(:continue, from, state) do
    start_turn(:continue, nil, state, from)
  end

  def handle_call(:abandon_turn, _from, %{recovery: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:abandon_turn, from, %{journal: journal} = state)
      when not is_nil(journal) do
    defer_storage(
      state,
      from,
      fn -> persist_abandon(state) end,
      fn state, result ->
        case result do
          {:ok, agent_state} -> {:reply, :ok, %{state | recovery: nil, agent_state: agent_state}}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
      end
    )
  end

  def handle_call({:compact, _opts}, _from, %{active_turn: active_turn} = state)
      when not is_nil(active_turn) do
    {:reply, {:error, :turn_in_progress}, state}
  end

  def handle_call({:compact, _opts}, _from, %{recovery: recovery} = state)
      when not is_nil(recovery) do
    {:reply, {:error, {:recovery_required, recovery}}, state}
  end

  def handle_call({:compact, opts}, from, state) do
    session_id = state.agent_state.session_id
    event_callback = fn event -> broadcast(state, {:tackle_compaction, session_id, event}) end
    signal = Cancellation.new_signal()

    compaction_opts =
      opts
      |> Keyword.take([:instructions])
      |> Keyword.put(:event_callback, event_callback)
      |> Keyword.put(:before_provider_call, provider_gate(state))
      |> Keyword.put(:cancellation_signal, signal)

    defer_storage(
      state,
      from,
      fn -> Compaction.compact(state.agent_state, :manual, compaction_opts) end,
      fn state, result -> finish_compaction(state, result, session_id) end,
      signal
    )
  end

  # Cancels the active turn or, while idle, a running manual compaction.
  def handle_call(:cancel, _from, state),
    do: {:reply, :ok, cancel_running(state, :user_cancelled)}

  def handle_call(:tree, _from, state) do
    {:reply, {:ok, state.agent_state.tree}, state}
  end

  # Branching is the session's policy; the library can always navigate.
  def handle_call({:navigate, _target, _opts}, _from, %{tree_enabled?: false} = state) do
    {:reply, {:error, :tree_disabled}, state}
  end

  def handle_call({:navigate, _target, _opts}, _from, %{active_turn: active} = state)
      when not is_nil(active) do
    {:reply, {:error, :turn_in_progress}, state}
  end

  def handle_call({:navigate, _target, _opts}, _from, %{recovery: recovery} = state)
      when not is_nil(recovery) do
    {:reply, {:error, {:recovery_required, recovery}}, state}
  end

  # Only `:expected_revision` is forwarded: the committer and the session id
  # always come from the session's own state.
  def handle_call({:navigate, target, opts}, from, state) do
    opts = Keyword.take(opts, [:expected_revision])

    defer_storage(
      state,
      from,
      fn -> Tackle.Lib.navigate(state.agent_state, target, opts) end,
      &finish_navigation/2
    )
  end

  def handle_call({:cancel_tool_call, _call_id, _reason}, _from, %{active_turn: nil} = state),
    do: {:reply, {:error, :no_active_turn}, state}

  # A settling turn has dropped its signal: every call has already finished.
  def handle_call(
        {:cancel_tool_call, _call_id, _reason},
        _from,
        %{active_turn: %{signal: nil}} = state
      ),
      do: {:reply, :ok, state}

  # A record for a call that had already finished, or never existed, is
  # deleted with the turn signal when the turn settles.
  def handle_call({:cancel_tool_call, call_id, reason}, _from, state) do
    state.active_turn.signal |> Cancellation.for_call(call_id) |> Cancellation.cancel(reason)
    {:reply, :ok, state}
  end

  def handle_call({:reconfigure, _opts}, _from, %{active_turn: active_turn} = state)
      when not is_nil(active_turn) do
    {:reply, {:error, :turn_in_progress}, state}
  end

  def handle_call({:reconfigure, opts}, from, state) do
    case Config.reconfigure(state.config, opts) do
      {:ok, config} ->
        defer_storage(
          state,
          from,
          fn -> persist_configuration(state, config) end,
          &finish_reconfiguration(&1, &2, config)
        )

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_call(:inbox, _from, state) do
    {:reply, :queue.to_list(state.inbox), state}
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

  def handle_call(:close, from, state) do
    state = cancel_running(state, :session_closed)

    result =
      defer_storage(state, from, fn -> persist_close(state) end, fn state, result ->
        case result do
          :ok ->
            broadcast(state, {:tackle_session_closed, state.agent_state.session_id})
            {:stop, :normal, :ok, state}

          {:error, reason} ->
            {:stop, {:persistence_failed, reason}, {:error, reason}, state}
        end
      end)

    case result do
      {:noreply, state} -> {:noreply, put_in(state.storage_task.kind, :close)}
      result -> result
    end
  end

  @impl true
  def handle_cast(
        {:background_finished, %RunRef{} = run_ref, profile, %Outcome{} = outcome},
        state
      ) do
    publish_background_finished(state, run_ref, profile, outcome)
    {:noreply, state}
  end

  def handle_cast({:publish_event, %Event{} = event}, state) do
    broadcast(state, {:tackle_event, state.agent_state.session_id, nil, event})
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, result}, %{storage_task: %{task: %{ref: ref}} = pending} = state) do
    Process.demonitor(pending.task.monitor, [:flush])
    delete_operation_signal(pending)
    state = %{state | storage_task: nil}

    finish_storage_task(state, pending, result)
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{storage_task: %{task: %{monitor: monitor}} = pending} = state
      ) do
    Process.demonitor(monitor, [:flush])
    delete_operation_signal(pending)

    if Map.get(pending, :from),
      do: GenServer.reply(pending.from, {:error, {:persistence_failed, reason}})

    cleanup_active_turn(state.active_turn)
    release_turn(state)
    {:stop, {:persistence_failed, reason}, %{state | storage_task: nil, active_turn: nil}}
  end

  def handle_info({:tackle_storage, session_id, status}, state)
      when session_id == state.agent_state.session_id and status in [:ready, :delayed] do
    broadcast(state, {:tackle_storage, session_id, status})
    {:noreply, schedule_inbox_wake(%{state | storage_status: status})}
  end

  def handle_info(
        {:tackle_event, _turn_id,
         %Event{type: :subagent_progress, data: %{background: true}} = event},
        state
      ) do
    broadcast(state, {:tackle_event, state.agent_state.session_id, nil, event})
    {:noreply, state}
  end

  def handle_info(
        {:tackle_event, turn_id, %Event{} = event},
        %{active_turn: %{id: turn_id}} = state
      ) do
    event = project_usage_event(event, state.agent_state)

    broadcast(
      state,
      {:tackle_event, state.agent_state.session_id, turn_id, event}
    )

    state = record_interrupted_tool_call(state, event)
    {:noreply, state}
  end

  def handle_info({:tackle_message_appended, session_id, %Message{} = message}, state)
      when session_id == state.agent_state.session_id do
    {:noreply, maybe_generate_title(state, Event.message_end(message))}
  end

  def handle_info({:tackle_event, _turn_id, %Event{}}, state), do: {:noreply, state}

  # Close owns the terminal transition; a settling turn cannot replace its
  # outstanding storage continuation or start another terminal commit.
  def handle_info(
        {ref, _result},
        %{storage_task: %{kind: :close}, active_turn: %{task: %TurnTask{ref: ref}}} = state
      ),
      do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{storage_task: %{kind: :close}, active_turn: %{task: %TurnTask{monitor: monitor}}} =
          state
      ),
      do: {:noreply, state}

  def handle_info(
        {ref, result},
        %{active_turn: %{task: %TurnTask{ref: ref}} = active_turn} = state
      ) do
    Process.demonitor(active_turn.task.monitor, [:flush])
    delete_turn_signals(active_turn)
    release_turn(state)

    case result do
      {outcome, %AgentState{} = agent_state} when outcome in [:ok, :error, :cancelled] ->
        begin_terminal_persist(state, active_turn, result, agent_state)

      invalid_result ->
        reason = {:invalid_turn_result, invalid_result}
        begin_terminal_persist(state, active_turn, {:runtime_error, reason}, state.agent_state)
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{active_turn: %{task: %TurnTask{monitor: monitor}} = active_turn} = state
      ) do
    delete_turn_signals(active_turn)
    release_turn(state)
    begin_terminal_persist(state, active_turn, {:runtime_error, reason}, state.agent_state)
  end

  def handle_info({:runtime_cancel, reason}, state) do
    {:noreply, cancel_running(state, reason)}
  end

  # A completed title generation commits through the journal's metadata path so
  # the projection, catalog, and every frontend pick it up. A failure only
  # leaves the session untitled; it never surfaces as a session error.
  def handle_info({ref, result}, %{title_task: %TurnTask{ref: ref}} = state) do
    Process.demonitor(state.title_task.monitor, [:flush])
    {:noreply, state |> Map.put(:title_task, :done) |> apply_generated_title(result)}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{title_task: %TurnTask{monitor: monitor}} = state
      ) do
    Logger.debug("session title generation crashed")
    {:noreply, %{state | title_task: :done}}
  end

  def handle_info(:tackle_inbox_wake, state) do
    state = %{state | inbox_wake_scheduled?: false}

    case start_inbox_turn(state) do
      {:ok, turn_id, reason, state} ->
        broadcast(state, {:tackle_turn_started, state.agent_state.session_id, turn_id, reason})
        {:noreply, state}

      {:skip, state} ->
        {:noreply, state}
    end
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
    cleanup_title_task(state.title_task)

    if state.storage_task do
      TurnTask.shutdown(state.storage_task.task, @task_shutdown_timeout)
      safe_cancellation(fn -> delete_operation_signal(state.storage_task) end)
    end

    :ok
  end

  defp finish_storage_task(state, %{kind: :begin_turn} = pending, result),
    do: finish_begin_turn(state, pending, result)

  defp finish_storage_task(state, %{kind: :terminal} = pending, result),
    do: finish_terminal_persistence(state, pending, result)

  defp finish_storage_task(state, %{kind: kind} = pending, result)
       when kind in [:operation, :close],
       do: finish_storage_operation(pending.from, pending.complete.(state, result))

  defp finish_begin_turn(state, pending, :ok) do
    state = drop_reserved_inbox(state, pending.inbox_messages)
    broadcast_inbox_drained(state, pending.inbox_messages)

    if pending.reason do
      broadcast(
        state,
        {:tackle_turn_started, state.agent_state.session_id, pending.turn_id, pending.reason}
      )
    end

    case start_turn_task(state.work_supervisor, fn ->
           run_operation(
             pending.operation,
             pending.agent_state,
             pending.input,
             pending.run_opts
           )
         end) do
      {:ok, task} ->
        active = %{state.active_turn | task: task, beginning?: false}
        if pending.from, do: GenServer.reply(pending.from, {:ok, pending.turn_id})
        {:noreply, %{state | active_turn: active}}

      {:error, reason} ->
        fail_begin_turn(state, pending, {:turn_task_failed, reason})
    end
  end

  defp finish_begin_turn(state, pending, {:error, reason}),
    do: fail_begin_turn(state, pending, {:persistence_failed, reason})

  defp fail_begin_turn(state, pending, reason) do
    delete_turn_signals(%{state.active_turn | signal: pending.signal})
    release_turn(state)
    if pending.from, do: GenServer.reply(pending.from, {:error, reason})
    {:noreply, %{state | active_turn: nil}}
  end

  defp finish_reconfiguration(state, :ok, config) do
    agent_state = apply_configuration(state.agent_state, config)
    state = %{state | config: config, agent_state: agent_state}
    snapshot = build_snapshot(state)
    broadcast(state, {:tackle_session_reconfigured, snapshot.session_id, snapshot})
    {:reply, {:ok, snapshot}, state}
  end

  defp finish_reconfiguration(state, {:error, reason}, _config),
    do: {:stop, {:persistence_failed, reason}, {:error, reason}, state}

  # A failed or cancelled compaction still returns the last committed state:
  # when an earlier pass committed, the session keeps and broadcasts it.
  defp finish_compaction(state, result, session_id) do
    case result do
      {:ok, agent_state, record} ->
        state = %{state | agent_state: agent_state}
        snapshot = build_snapshot(state)
        broadcast(state, {:tackle_session_compacted, session_id, snapshot, record})
        {:reply, {:ok, snapshot, record}, state}

      {status, reason, agent_state} when status in [:error, :cancelled] ->
        state = keep_committed_compaction(state, agent_state, session_id)
        reply = if status == :cancelled, do: {:cancelled, reason}, else: reason
        {:reply, {:error, reply}, state}
    end
  end

  defp keep_committed_compaction(state, agent_state, session_id) do
    if AgentState.last_compaction_id(agent_state) ==
         AgentState.last_compaction_id(state.agent_state) do
      state
    else
      state = %{state | agent_state: agent_state}
      broadcast(state, {:tackle_session_compacted, session_id, build_snapshot(state), nil})
      state
    end
  end

  defp finish_navigation(state, result) do
    case result do
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

  # One deferred operation retains one caller and one payload. Mutating
  # admission is rejected until it completes; control calls stay responsive.
  # An operation `cancel/1` can stop carries its cancellation signal, which is
  # deleted when the operation settles.
  defp defer_storage(state, from, fun, complete, signal \\ nil) do
    case start_turn_task(state.work_supervisor, fun) do
      {:ok, task} ->
        pending = %{kind: :operation, task: task, from: from, complete: complete, signal: signal}
        {:noreply, %{state | storage_task: pending}}

      {:error, reason} ->
        Cancellation.delete(signal)
        {:reply, {:error, {:storage_task_failed, reason}}, state}
    end
  end

  defp delete_operation_signal(%{kind: kind, signal: signal}) when kind in [:operation, :close],
    do: Cancellation.delete(signal)

  defp delete_operation_signal(_pending), do: :ok

  defp finish_storage_operation(from, {:reply, reply, state}) do
    GenServer.reply(from, reply)
    {:noreply, schedule_inbox_wake(state)}
  end

  defp finish_storage_operation(from, {:stop, reason, reply, state}) do
    GenServer.reply(from, reply)
    {:stop, reason, state}
  end

  defp start_turn(operation, input, state, from \\ nil)

  defp start_turn(_operation, _input, %{recovery: recovery} = state, _from)
       when not is_nil(recovery) do
    {:reply, {:error, {:recovery_required, recovery}}, state}
  end

  defp start_turn(_operation, _input, %{active_turn: active_turn} = state, _from)
       when not is_nil(active_turn) do
    {:reply, {:error, :turn_in_progress}, state}
  end

  defp start_turn(operation, input, state, from) do
    case acquire_turn(state) do
      :ok ->
        do_start_turn(operation, input, state, from)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp do_start_turn(operation, input, %{journal: nil} = state, _from) do
    signal = Cancellation.new_signal()
    turn_id = state.config.id_generator.()
    {agent_state, inbox_messages, _projected_messages} = project_inbox(state)
    run_opts = turn_opts(state, self(), turn_id, signal)
    state = clear_inbox(state)
    broadcast_inbox_drained(state, inbox_messages)

    case start_turn_task(state.work_supervisor, fn ->
           run_operation(operation, agent_state, input, run_opts)
         end) do
      {:ok, task} ->
        active_turn = %{
          id: turn_id,
          operation: operation,
          task: task,
          signal: signal,
          initial_message_ids: MapSet.new(agent_state.messages, & &1.id),
          cancellation_requested?: false
        }

        {:reply, {:ok, turn_id}, %{state | active_turn: active_turn}}

      {:error, reason} ->
        Cancellation.delete(signal)
        release_turn(state)
        {:reply, {:error, {:turn_task_failed, reason}}, state}
    end
  end

  defp do_start_turn(operation, input, state, from) do
    signal = Cancellation.new_signal()
    turn_id = state.config.id_generator.()
    session_pid = self()
    {agent_state, inbox_messages, projected_messages} = project_inbox(state)
    run_opts = turn_opts(state, session_pid, turn_id, signal)

    case start_turn_task(state.work_supervisor, fn ->
           persist_begin(state, operation, input, turn_id, agent_state, projected_messages)
         end) do
      {:ok, task} ->
        active_turn = %{
          id: turn_id,
          operation: operation,
          task: nil,
          signal: signal,
          initial_message_ids: MapSet.new(agent_state.messages, & &1.id),
          cancellation_requested?: false,
          beginning?: true
        }

        pending = %{
          kind: :begin_turn,
          from: from,
          operation: operation,
          input: input,
          agent_state: agent_state,
          inbox_messages: inbox_messages,
          run_opts: run_opts,
          signal: signal,
          turn_id: turn_id,
          task: task,
          reason: if(is_nil(from), do: inbox_turn_reason(state))
        }

        {:noreply, %{state | active_turn: active_turn, storage_task: pending}}

      {:error, reason} ->
        Cancellation.delete(signal)
        release_turn(state)
        {:reply, {:error, {:storage_task_failed, reason}}, state}
    end
  end

  defp begin_terminal_persist(%{journal: nil} = state, active_turn, result, agent_state) do
    pending = %{
      turn_id: active_turn.id,
      result: result,
      agent_state: agent_state,
      active_turn: active_turn
    }

    finish_terminal_persistence(state, pending, :ok)
  end

  defp begin_terminal_persist(state, active_turn, result, agent_state) do
    case start_turn_task(state.work_supervisor, fn ->
           persist_terminal(state, result)
         end) do
      {:ok, task} ->
        pending = %{
          kind: :terminal,
          task: task,
          turn_id: active_turn.id,
          result: result,
          agent_state: agent_state,
          active_turn: active_turn
        }

        # Cancellation has already been observed by the completed task. Retain
        # the turn identity, but do not expose a deleted cancellation signal.
        active_turn = %{active_turn | signal: nil}
        {:noreply, %{state | storage_task: pending, active_turn: active_turn}}

      {:error, reason} ->
        {:stop, {:storage_task_failed, reason}, %{state | active_turn: nil}}
    end
  end

  defp finish_terminal_persistence(state, pending, :ok) do
    state = %{state | agent_state: pending.agent_state, active_turn: nil}

    case pending.result do
      {:runtime_error, reason} ->
        broadcast_turn_failure(state, pending.turn_id, reason)
        settle(state, pending.result)

      result ->
        state =
          discard_reported_background_launches(state, pending.active_turn, pending.agent_state)

        broadcast(
          state,
          {:tackle_turn_finished, pending.agent_state.session_id, pending.turn_id, result}
        )

        settle(state, result)
    end
  end

  defp finish_terminal_persistence(state, _pending, reason),
    do: {:stop, {:persistence_failed, reason}, %{state | active_turn: nil}}

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
      tool_context: %{runtime_turn_id: turn_id},
      cancellation_signal: signal,
      before_provider_call: provider_gate(state),
      before_tool_execution: tool_gate(state),
      turn_id: turn_id,
      llm_stream: state.config.llm_stream,
      take_incoming_messages: fn -> GenServer.call(session_pid, :take_incoming_messages) end,
      tool_supervisor: state.tool_supervisor
    ]
  end

  # The persistence hook appends write-behind. A provider call does not need a
  # durable record first (a crash only means calling again), but it must not run
  # ahead of a stalled or failed journal, so it waits behind earlier requests
  # without syncing.
  defp provider_gate(%{journal: nil}), do: nil
  defp provider_gate(%{journal: journal}), do: fn -> Journal.await_idle(journal) end

  # Tool intent (and everything before it) must be durable before a tool with
  # external effects runs, so recovery can report it as uncertain after a crash.
  # The loop skips this gate for read-only tools.
  defp tool_gate(%{journal: nil}), do: nil
  defp tool_gate(%{journal: journal}), do: fn -> Journal.await_durable(journal) end

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
      {:noreply, schedule_inbox_wake(state)}
    end
  end

  defp publish_background_finished(state, run_ref, profile, outcome) do
    event =
      Event.new(:subagent_finished, %{
        run_id: run_ref.run_id,
        agent_ref: run_ref.agent_ref,
        profile: profile,
        model: run_ref.model_ref,
        status: outcome.status
      })

    broadcast(state, {:tackle_event, state.agent_state.session_id, nil, event})
  end

  defp schedule_inbox_wake(
         %{
           lifetime: :explicit,
           recovery: nil,
           active_turn: nil,
           storage_task: nil,
           storage_status: :ready,
           inbox_wake_scheduled?: false
         } = state
       ) do
    if deliverable_inbox_pending?(state) do
      send(self(), :tackle_inbox_wake)
      %{state | inbox_wake_scheduled?: true}
    else
      state
    end
  end

  defp schedule_inbox_wake(state), do: state

  defp start_inbox_turn(state)
       when not is_nil(state.storage_task) or state.storage_status == :delayed,
       do: {:skip, state}

  defp start_inbox_turn(%{lifetime: :explicit, recovery: nil, active_turn: nil} = state) do
    if deliverable_inbox_pending?(state) do
      reason = inbox_turn_reason(state)

      case start_turn(:continue, nil, state) do
        {:reply, {:ok, turn_id}, state} -> {:ok, turn_id, reason, state}
        {:noreply, state} -> {:skip, state}
        {:reply, {:error, _reason}, state} -> {:skip, state}
      end
    else
      {:skip, state}
    end
  end

  defp start_inbox_turn(state), do: {:skip, state}

  defp deliverable_inbox_pending?(state) do
    state.inbox
    |> :queue.to_list()
    |> Enum.any?(&deliverable_envelope?/1)
  end

  defp inbox_turn_reason(state) do
    deliverable = Enum.filter(:queue.to_list(state.inbox), &deliverable_envelope?/1)

    if Enum.all?(deliverable, &match?(%Envelope{kind: :completion}, &1)) do
      :background_notice
    else
      :queued_messages
    end
  end

  defp project_inbox(%{inbox_count: 0} = state), do: {state.agent_state, [], []}

  defp project_inbox(state) do
    envelopes = :queue.to_list(state.inbox)

    {projected_messages, agent_state} =
      Enum.map_reduce(envelopes, state.agent_state, fn envelope, agent_state ->
        message = Message.user(envelope_content(envelope), id_generator: agent_state.id_generator)
        {message, AgentState.add_message(agent_state, message)}
      end)

    {agent_state, envelopes, projected_messages}
  end

  defp persist_inbox_messages(%{journal: journal}, agent_state, messages) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      # Write-behind like loop messages: durable at the next sync point.
      case Journal.append_message(
             journal,
             message,
             Persistence.tree_parent(agent_state, message.id),
             sync: false
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp drop_reserved_inbox(state, reserved) do
    retained = :queue.to_list(state.inbox) -- reserved
    %{state | inbox: :queue.from_list(retained), inbox_count: length(retained)}
  end

  defp clear_inbox(state),
    do: %{state | inbox: :queue.new(), inbox_count: 0}

  defp queue_user_message(state, message) do
    entry = %{from: :user, message: message}

    if ordinary_inbox_count(state) >= @max_inbox_messages or inbox_bytes_full?(state, entry) do
      {:reply, {:error, :inbox_full}, state}
    else
      {:reply, {:ok, :queued}, enqueue(state, entry)}
    end
  end

  defp enqueue_envelope(state, %Envelope{kind: kind} = envelope) do
    case inbox_capacity(state, envelope) do
      :ok ->
        state = enqueue(state, envelope)

        state =
          if kind == :launch or state.active_turn != nil,
            do: state,
            else: schedule_inbox_wake(state)

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp inbox_capacity(state, %Envelope{kind: :message} = envelope) do
    if ordinary_inbox_count(state) >= @max_inbox_messages or inbox_bytes_full?(state, envelope),
      do: {:error, :inbox_full},
      else: :ok
  end

  defp inbox_capacity(state, %Envelope{} = envelope) do
    if deferred_inbox_count(state) >= @max_deferred_messages or inbox_bytes_full?(state, envelope),
      do: {:error, :deferred_inbox_full},
      else: :ok
  end

  defp inbox_bytes_full?(state, entry) do
    bytes =
      state.inbox
      |> :queue.to_list()
      |> Enum.reduce(:erlang.external_size(entry), fn queued, bytes ->
        bytes + :erlang.external_size(queued)
      end)

    bytes > @max_inbox_bytes
  end

  defp ordinary_inbox_count(state) do
    state.inbox
    |> :queue.to_list()
    |> Enum.count(fn
      %Envelope{kind: :message} -> true
      %{from: :user} -> true
      _other -> false
    end)
  end

  defp deferred_inbox_count(state) do
    state.inbox
    |> :queue.to_list()
    |> Enum.count(fn
      %Envelope{kind: kind} when kind in [:launch, :completion] -> true
      _other -> false
    end)
  end

  defp enqueue(state, envelope) do
    %{state | inbox: :queue.in(envelope, state.inbox), inbox_count: state.inbox_count + 1}
  end

  defp deliverable_inbox(state) do
    state.inbox
    |> :queue.to_list()
    |> Enum.filter(&deliverable_envelope?/1)
  end

  defp drop_deliverable_inbox(state) do
    retained =
      state.inbox
      |> :queue.to_list()
      |> Enum.reject(&deliverable_envelope?/1)

    %{state | inbox: :queue.from_list(retained), inbox_count: length(retained)}
  end

  defp deliverable_envelope?(%Envelope{kind: :launch}), do: false
  defp deliverable_envelope?(_envelope), do: true

  defp envelope_content(%{from: :user, message: content}), do: content

  defp envelope_content(%Envelope{from: %AgentRef{} = from, message: content}) do
    "Message from agent #{from.agent_id}:\n\n#{content}"
  end

  # A tool result the loop settles synthetically on an interrupted batch did
  # not actually report anything: a background launch whose tool was cut off
  # still owes its run id to the next turn through the inbox.
  defp record_interrupted_tool_call(
         %{active_turn: active_turn} = state,
         %Event{type: :tool_error, data: %{reason: :interrupted, tool_call_id: id}}
       )
       when is_binary(id) do
    interrupted = Map.get(active_turn, :interrupted_tool_calls, MapSet.new())

    %{
      state
      | active_turn: Map.put(active_turn, :interrupted_tool_calls, MapSet.put(interrupted, id))
    }
  end

  defp record_interrupted_tool_call(state, _event), do: state

  defp discard_reported_background_launches(
         state,
         %{id: turn_id, initial_message_ids: initial_message_ids} = active_turn,
         %AgentState{} = agent_state
       ) do
    interrupted = Map.get(active_turn, :interrupted_tool_calls, MapSet.new())

    reported_tool_calls =
      agent_state.messages
      |> Enum.reject(&MapSet.member?(initial_message_ids, &1.id))
      |> Enum.flat_map(fn
        %Message{role: :tool, tool_call_id: tool_call_id} when is_binary(tool_call_id) ->
          [tool_call_id]

        _message ->
          []
      end)
      |> MapSet.new()
      |> MapSet.difference(interrupted)

    inbox =
      state.inbox
      |> :queue.to_list()
      |> Enum.reject(fn
        %Envelope{kind: :launch, origin: %{turn_id: ^turn_id, tool_call_id: tool_call_id}} ->
          MapSet.member?(reported_tool_calls, tool_call_id)

        _envelope ->
          false
      end)

    %{state | inbox: :queue.from_list(inbox), inbox_count: length(inbox)}
  end

  defp broadcast_inbox_drained(state, messages) do
    Enum.each(messages, fn
      %Envelope{from: %AgentRef{} = from} ->
        event =
          Event.new(:subagent_message_received, %{
            from_agent_ref: from,
            agent_ref: state.agent_ref
          })

        broadcast(state, {:tackle_event, state.agent_state.session_id, nil, event})

      %{from: :user} ->
        :ok
    end)
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

  # Idle, the only cancellable work is a manual compaction.
  defp cancel_running(%{active_turn: nil} = state, reason) do
    case state.storage_task do
      %{kind: :operation, signal: %Cancellation.Signal{} = signal} ->
        Cancellation.cancel(signal, reason)

      _none ->
        :ok
    end

    state
  end

  defp cancel_running(%{active_turn: active_turn} = state, reason) do
    if active_turn.signal, do: Cancellation.cancel(active_turn.signal, reason)
    %{state | active_turn: %{active_turn | cancellation_requested?: true}}
  end

  defp apply_configuration(agent_state, config) do
    llm_opts = Keyword.put(config.llm_opts, :credential_store, Auth.credential_store())

    %{agent_state | llm: config.llm, llm_opts: llm_opts}
  end

  # Tools find the agent they act for under `:runtime` (`AgentRef.from_context/1`);
  # the scope coordinator owns what that agent may do.
  defp put_runtime_context(agent_state, %ScopeRef{}, %AgentRef{} = agent_ref, opts) do
    context =
      agent_state.context
      |> Map.put(:runtime, agent_ref)
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

        {:ok, agent_state, nil, nil, false}

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
             override_config: durable.override_config
           ),
         :ok <- persist_configuration_change(journal, loaded.configuration_changed?, config),
         :ok <- enable_tree_if_needed(journal, projection, durable.tree) do
      agent_state =
        loaded.state
        |> put_runtime_context(scope_ref, agent_ref, opts)
        |> install_persistence_hook()
        |> install_committer()

      recovery = recovery_for(projection)

      tree_enabled? = durable.tree or projection.tree_enabled?

      case repair_interrupted_tool_results(journal, agent_state, config, recovery) do
        {:ok, agent_state} -> {:ok, agent_state, journal, recovery, tree_enabled?}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A settled turn can still leave assistant tool calls without results — a
  # turn cancelled or crashed mid-batch, or a journal written before the loop
  # settled interrupted batches — which providers reject. The loop settles such
  # calls itself when the next turn starts, but resume repairs them first: the
  # snapshot and transcript a frontend shows, manual compaction, and tree
  # navigation (which only accepts positions whose calls all have results) see
  # the history before any turn runs, and a resumed session need not run one.
  # Their outcome is unknown, since the tool may have run, which the results
  # say. The repair is committed through a dedicated repair turn so it is
  # durable. A turn that
  # still requires an explicit recovery decision is left untouched;
  # `abandon_turn/1` settles those.
  defp repair_interrupted_tool_results(_journal, agent_state, _config, recovery)
       when not is_nil(recovery),
       do: {:ok, agent_state}

  defp repair_interrupted_tool_results(journal, %AgentState{} = agent_state, config, nil) do
    case Messages.unresolved_tool_calls(agent_state.messages) do
      [] ->
        {:ok, agent_state}

      _calls ->
        turn_id = config.id_generator.()

        with {:ok, _turn_id} <- Journal.begin_turn(journal, :repair, nil, turn_id),
             {:ok, agent_state} <- settle_unresolved_tool_results(agent_state),
             :ok <-
               Journal.settle_turn(journal, "turn.abandoned", %{
                 "turn_id" => turn_id,
                 "reason" => "interrupted_tools_repaired"
               }) do
          {:ok, agent_state}
        end
    end
  end

  # Appends one synthetic result per unresolved tool call. The messages go
  # through the persistence hook, so they are journaled with the same parent
  # linkage as any other tool result and survive the next resume.
  defp settle_unresolved_tool_results(%AgentState{} = agent_state) do
    agent_state.messages
    |> Messages.interrupted_results(:unknown, id_generator: agent_state.id_generator)
    |> Enum.reduce_while({:ok, agent_state}, fn message, {:ok, acc} ->
      acc = AgentState.add_message(acc, message)

      case Persistence.after_message(acc, message, acc.context) do
        :ok -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A legacy linear journal is never rewritten; enabling branching appends one
  # explicit versioned transition before any tree-specific write.
  defp enable_tree_if_needed(_journal, _projection, false), do: :ok
  defp enable_tree_if_needed(_journal, %Projection{tree_enabled?: true}, true), do: :ok
  defp enable_tree_if_needed(journal, _projection, true), do: Journal.enable_tree(journal)

  # Durable sessions commit compactions and navigations through the journal
  # before the library installs them in memory.
  defp install_committer(%AgentState{} = state), do: %{state | committer: Committer}

  # The hook is added directly rather than through Config; Tackle.Lib.Hook
  # loads hook modules itself when it validates or invokes them.
  defp install_persistence_hook(%AgentState{} = state) do
    %{
      state
      | hooks: append(state.hooks, Persistence),
        context:
          state.context |> Map.put(:journal_required, true) |> Map.put(:session_owner, self())
    }
  end

  defp append(items, item), do: Enum.concat(items, [item])

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

  defp persist_abandon(%{journal: journal, recovery: recovery} = state) do
    with :ok <-
           Journal.settle_turn(journal, "turn.abandoned", %{
             "turn_id" => recovery.turn_id,
             "reason" => "abandoned_by_frontend"
           }) do
      repair_interrupted_tool_results(journal, state.agent_state, state.config, nil)
    end
  end

  defp persist_begin(state, operation, input, turn_id, agent_state, messages) do
    with :ok <- begin_turn(state, operation, input, turn_id) do
      persist_inbox_messages(state, agent_state, messages)
    end
  end

  defp begin_turn(%{journal: journal}, operation, input, turn_id) do
    case Journal.begin_turn(journal, operation, input, turn_id) do
      {:ok, _turn_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

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
      recovery: state.recovery,
      session_title: state.session_title,
      storage: state.storage_status
    }
  end

  # -- automatic session titles ---------------------------------------------

  # Codex-style automatic titles: the first settled user message of an
  # untitled durable session starts one bounded, tool-free generation task
  # (`Tackle.Session.Title`). The task runs concurrently with the active turn,
  # so the title is ready soon after the prompt instead of after the turn. An
  # explicit title from the session spec or a resumed journal suppresses
  # generation, and a session generates at most one title.
  defp maybe_generate_title(
         %{session_title: nil, title_task: nil, journal: journal} = state,
         %Event{type: :message_end, data: %{message: %Message{role: :user} = message}}
       )
       when not is_nil(journal) do
    content = message.content

    if titles_enabled?(state.config) and is_binary(content) and String.trim(content) != "" do
      start_title_task(state, content)
    else
      state
    end
  end

  defp maybe_generate_title(state, _event), do: state

  defp titles_enabled?(%Config{session_titles: %SessionTitles{}}), do: true
  defp titles_enabled?(_config), do: false

  defp start_title_task(state, user_message) do
    selection = title_selection(state.config)
    llm_opts = title_llm_opts(state)

    case TurnTask.start(state.work_supervisor, fn ->
           generate_and_persist_title(state.journal, selection, user_message, llm_opts)
         end) do
      {:ok, task} ->
        %{state | title_task: task}

      {:error, reason} ->
        Logger.debug("session title task failed to start: #{inspect(reason)}")
        %{state | title_task: :done}
    end
  end

  defp generate_and_persist_title(journal, selection, user_message, llm_opts) do
    # A title is also a model effect: wait behind outstanding commits.
    with :ok <- Journal.await_idle(journal),
         {:ok, title} <- Title.generate(selection, user_message, llm_opts),
         :ok <- Journal.metadata_changed(journal, %{"title" => title}) do
      {:ok, title}
    end
  end

  # A dedicated title model wins when one is configured; otherwise the title
  # call reuses the session's live selection, like codex falling back to the
  # current model.
  defp title_selection(%Config{
         session_titles: %SessionTitles{selection: %Selection{} = selection}
       }),
       do: selection

  defp title_selection(%Config{llm: %Selection{} = selection}), do: selection

  defp title_llm_opts(%{config: config, agent_state: agent_state}) do
    config.llm_opts
    |> Keyword.put(:credential_store, Auth.credential_store())
    |> Keyword.put(:session_id, agent_state.session_id)
  end

  defp apply_generated_title(state, {:ok, title}) do
    state = %{state | session_title: title}
    broadcast(state, {:tackle_session_title_changed, state.agent_state.session_id, title})
    state
  end

  defp apply_generated_title(state, {:error, reason}) do
    Logger.debug("session title generation failed: #{inspect(reason)}")
    state
  end

  defp projection_title(nil), do: nil

  defp projection_title(journal) do
    case Journal.projection(journal) do
      {:ok, %Projection{title: title}} when is_binary(title) -> title
      _other -> nil
    end
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
    safe_cancellation(fn -> delete_turn_signals(active_turn) end)
    :ok
  end

  # Deleting the turn signal also deletes the per-call records of calls a host
  # cancelled through `cancel_tool_call/3`, including calls killed mid-flight
  # or cancelled after they settled.
  defp delete_turn_signals(%{signal: signal}), do: Cancellation.delete(signal)

  defp cleanup_title_task(nil), do: :ok
  defp cleanup_title_task(:done), do: :ok

  defp cleanup_title_task(%TurnTask{} = task),
    do: TurnTask.shutdown(task, @task_shutdown_timeout)

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
