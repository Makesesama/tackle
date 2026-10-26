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
  request helper and then stops. Input it acknowledged after the loop last
  took queued messages (while `before_turn_end` hooks ran, or while the
  terminal event was written) is not dropped: a successful turn is continued
  with it, and the last turn's outcome is delivered. An error or cancelled
  outcome is delivered at once, and input still queued is dropped. A session
  process is never reset for another agent identity.

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
  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Envelope
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.Registry
  alias Tackle.Runtime.RunRef
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.Task, as: TurnTask
  alias Tackle.Session.Committer
  alias Tackle.Session.Inbox
  alias Tackle.Session.Journal
  alias Tackle.Session.Journal.Watchdog
  alias Tackle.Session.Loader
  alias Tackle.Session.Persistence
  alias Tackle.Session.Projection
  alias Tackle.Session.Spec, as: SessionSpec
  alias Tackle.Session.Title
  alias Tackle.Session.Turn

  @task_shutdown_timeout 1_000

  defmodule Snapshot do
    @moduledoc "An atomic view of a Tackle session and its active turn."

    @enforce_keys [:session_id, :agent_state]
    defstruct [
      :session_id,
      :agent_state,
      :active_turn,
      :agent_ref,
      :scope_ref,
      :recovery,
      session_title: nil,
      storage: :ready
    ]

    @type recovery :: %{
            required(:turn_id) => String.t(),
            required(:operation) => term(),
            required(:uncertain_tools) => [map()]
          }

    @type t :: %__MODULE__{
            session_id: String.t(),
            agent_state: Tackle.Lib.State.t(),
            active_turn: Tackle.Session.Turn.summary() | nil,
            agent_ref: AgentRef.t() | nil,
            scope_ref: ScopeRef.t() | nil,
            recovery: recovery() | nil,
            session_title: String.t() | nil,
            storage: :ready | :delayed
          }
  end

  @type turn_result ::
          {:ok, AgentState.t()} | {:error, AgentState.t()} | {:cancelled, AgentState.t()}

  @typedoc """
  What a session starts from: the agent's configuration, the runtime context
  the agent's backend received, and the durable session it owns, if any.
  Only `Tackle.Runtime.RootBackend` starts sessions, and only a root session
  is durable.
  """
  @type start_arg :: {Config.t(), AgentContext.t(), SessionSpec.t() | nil}

  @doc false
  @spec start_link(start_arg()) :: GenServer.on_start()
  def start_link({%Config{}, %AgentContext{}, durable} = arg)
      when is_nil(durable) or is_struct(durable, SessionSpec),
      do: GenServer.start_link(__MODULE__, arg)

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

  `reason` (`:user_cancelled` by default) is recorded as the cancelled turn's
  error; the runtime passes its own, such as `:request_terminated` for a
  delegated run. The first reason a turn is cancelled with wins.
  """
  @spec cancel(GenServer.server(), term()) :: :ok
  def cancel(session, reason \\ :user_cancelled),
    do: GenServer.call(session, {:cancel, reason})

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

  @doc """
  Returns the session's inbox, oldest entry first.

  Every entry is a `Tackle.Runtime.Envelope` (see `Tackle.Session.Inbox`): a
  user message submitted during a turn has `from: :user`; the others came
  from other agents and the runtime, including background launch notices
  held until their tool call settles. Nothing in the inbox has reached the
  conversation yet. Meant for tests and diagnostics; the runtime does not
  call it.
  """
  @spec inbox(GenServer.server()) :: [Inbox.entry()]
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

  @impl true
  def init({%Config{} = config, %AgentContext{} = context, durable}) do
    Process.flag(:trap_exit, true)

    with :ok <- validate_ownership(context),
         :ok <- register(context.agent_ref),
         {:ok, config, agent_state, journal, recovery, tree_enabled?} <-
           build_agent_state(config, context.agent_ref, durable) do
      state = %{
        config: config,
        agent_state: agent_state,
        active_turn: nil,
        subscribers: %{},
        scope_ref: context.scope_ref,
        agent_ref: context.agent_ref,
        coordinator: context.coordinator,
        lifetime: context.lifetime,
        terminal: context.terminal,
        work_supervisor: context.work_supervisor,
        tool_supervisor: context.tool_supervisor,
        journal: journal,
        recovery: recovery,
        tree_enabled?: tree_enabled?,
        inbox: Inbox.new(),
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

  # A storage task (a turn's begin or terminal commit, or a deferred
  # operation) is outstanding, or the journal is delayed: work that writes or
  # starts a turn waits.
  defguardp is_storage_busy(state)
            when not is_nil(state.storage_task) or state.storage_status == :delayed

  @impl true
  def handle_call(operation, _from, state)
      when is_storage_busy(state) and
             (operation in [:abandon_turn, :continue] or
                (is_tuple(operation) and elem(operation, 0) in [:compact, :navigate, :reconfigure])),
      do: {:reply, {:error, :storage_busy}, state}

  # Queueing input for the active turn writes nothing, so it is accepted while
  # the turn's begin or terminal commit is outstanding or storage is delayed.
  def handle_call({:submit, input}, _from, %{active_turn: active_turn} = state)
      when not is_nil(active_turn) do
    case Inbox.push_user(state.inbox, input) do
      {:ok, inbox} -> {:reply, {:ok, :queued}, %{state | inbox: inbox}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:submit, _input}, _from, state) when is_storage_busy(state),
    do: {:reply, {:error, :storage_busy}, state}

  def handle_call({:submit, _input}, _from, %{recovery: recovery} = state)
      when not is_nil(recovery) do
    {:reply, {:error, {:recovery_required, recovery}}, state}
  end

  def handle_call({:submit, input}, from, state) do
    case start_turn(state, :run, input, from) do
      {:error, reason} -> {:reply, {:error, reason}, state}
      result -> result
    end
  end

  # Nothing can be withdrawn while a starting turn journals the messages it
  # reserved.
  def handle_call({:withdraw_queued, content}, _from, state) do
    case Inbox.withdraw(state.inbox, content) do
      {:ok, inbox} -> {:reply, :ok, %{state | inbox: inbox}}
      {:error, :reserved} -> {:reply, {:error, :storage_busy}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Like a mid-turn submit, a message for the active turn is queued while its
  # storage is busy; an idle session would have to start a turn for it.
  # Runtime notices are one-shot: they are kept in the inbox whatever the
  # storage, but never start their continuation until storage is ready.
  def handle_call({:deliver, %Envelope{kind: kind}}, _from_call, state)
      when kind not in [:completion, :launch] and is_nil(state.active_turn) and
             is_storage_busy(state),
      do: {:reply, {:error, :storage_busy}, state}

  def handle_call({:deliver, %Envelope{} = envelope}, _from_call, state) do
    case Inbox.push(state.inbox, envelope) do
      {:ok, inbox} ->
        state = %{state | inbox: inbox}

        state =
          if envelope.kind == :launch or state.active_turn != nil,
            do: state,
            else: schedule_inbox_wake(state)

        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:take_incoming_messages, _from, state) do
    {entries, inbox} = Inbox.take_deliverable(state.inbox)

    turn =
      state.active_turn &&
        Turn.record_user_inputs(state.active_turn, Inbox.user_messages(entries))

    state = %{state | inbox: inbox, active_turn: turn}

    broadcast_inbox_drained(state, entries)
    {:reply, {:ok, Enum.map(entries, &Inbox.content/1)}, state}
  end

  def handle_call(:continue, from, state) do
    case start_turn(state, :continue, nil, from) do
      {:error, reason} -> {:reply, {:error, reason}, state}
      result -> result
    end
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

  # Progress goes through the session, which broadcasts it to whoever is
  # subscribed when it arrives, as for turn events.
  def handle_call({:compact, opts}, from, state) do
    session_id = state.agent_state.session_id
    session_pid = self()

    event_callback = fn event ->
      send(session_pid, {:tackle_compaction_progress, session_id, event})
    end

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
  def handle_call({:cancel, reason}, _from, state),
    do: {:reply, :ok, cancel_running(state, reason)}

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

  # A record for a call that had already finished, or never existed, is
  # deleted with the turn signal when the turn settles.
  def handle_call({:cancel_tool_call, call_id, reason}, _from, state),
    do: {:reply, Turn.cancel_tool_call(state.active_turn, call_id, reason), state}

  def handle_call({:reconfigure, _opts}, _from, %{active_turn: active_turn} = state)
      when not is_nil(active_turn) do
    {:reply, {:error, :turn_in_progress}, state}
  end

  def handle_call({:reconfigure, opts}, from, state) do
    case Config.reconfigure(state.config, opts) do
      {:ok, config} -> apply_reconfiguration(state, from, config)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(state), state}
  end

  def handle_call(:inbox, _from, state) do
    {:reply, Inbox.entries(state.inbox), state}
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

    if pending.from, do: GenServer.reply(pending.from, {:error, {:persistence_failed, reason}})
    cleanup_active_turn(state.active_turn)
    release_turn(state)
    {:stop, {:persistence_failed, reason}, %{state | storage_task: nil, active_turn: nil}}
  end

  def handle_info({:tackle_compaction_progress, session_id, event}, state)
      when session_id == state.agent_state.session_id do
    broadcast(state, {:tackle_compaction, session_id, event})
    {:noreply, state}
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
        %{active_turn: %Turn{id: turn_id} = turn} = state
      ) do
    event = project_usage_event(event, state.agent_state)

    broadcast(
      state,
      {:tackle_event, state.agent_state.session_id, turn_id, event}
    )

    {:noreply, %{state | active_turn: Turn.record_event(turn, event)}}
  end

  # Only input the user wrote can title the session: the turn's own input and
  # queued user messages, not agent messages, background notices, or hook
  # feedback the loop also appends as user messages.
  def handle_info({:tackle_message_appended, session_id, %Message{} = message}, state)
      when session_id == state.agent_state.session_id do
    if Turn.user_authored?(state.active_turn, message),
      do: {:noreply, maybe_generate_title(state, message.content)},
      else: {:noreply, state}
  end

  def handle_info({:tackle_event, _turn_id, %Event{}}, state), do: {:noreply, state}

  def handle_info(
        {ref, result},
        %{active_turn: %Turn{task: %TurnTask{ref: ref}} = turn} = state
      ) do
    Process.demonitor(turn.task.monitor, [:flush])
    release_turn(state)
    state = %{state | active_turn: Turn.settling(turn)}

    case result do
      {outcome, %AgentState{} = agent_state} when outcome in [:ok, :error, :cancelled] ->
        begin_terminal_persist(state, result, agent_state)

      invalid_result ->
        reason = {:invalid_turn_result, invalid_result}
        begin_terminal_persist(state, {:runtime_error, reason}, state.agent_state)
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{active_turn: %Turn{task: %TurnTask{monitor: monitor}} = turn} = state
      ) do
    release_turn(state)
    state = %{state | active_turn: Turn.settling(turn)}
    begin_terminal_persist(state, {:runtime_error, reason}, state.agent_state)
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

  def handle_info(:tackle_inbox_wake, state),
    do: start_inbox_turn(%{state | inbox_wake_scheduled?: false})

  def handle_info({:DOWN, monitor_ref, :process, subscriber, _reason}, state) do
    subscribers =
      case Map.get(state.subscribers, subscriber) do
        ^monitor_ref -> Map.delete(state.subscribers, subscriber)
        _other -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  # A stray message, such as another session's storage notice or a late reply
  # the session no longer waits for, must not crash it: the root session runs
  # under `max_restarts: 0`, so its crash takes the whole scope down. Only the
  # message's tag is logged, since messages can carry conversation content.
  def handle_info(message, state) do
    Logger.debug("Tackle.Session ignored an unexpected message: #{message_tag(message)}")
    {:noreply, state}
  end

  defp message_tag(message) when is_tuple(message) and tuple_size(message) > 0,
    do: "tuple tagged #{inspect(elem(message, 0), limit: 3, printable_limit: 64)}"

  defp message_tag(message) when is_atom(message), do: inspect(message)
  defp message_tag(_message), do: "untagged message"

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

  defp finish_storage_task(state, %{kind: :operation} = pending, result),
    do: finish_storage_operation(pending.from, pending.complete.(state, result))

  # The turn's task runs only once its start is committed. A caller is
  # answered then; a turn the session started itself is announced with
  # `:tackle_turn_started` instead. Without a journal nothing was committed,
  # so a task that cannot be started leaves the queued messages queued.
  defp finish_begin_turn(state, begin, :ok) do
    turn = state.active_turn
    run_opts = turn_opts(state, self(), turn.id, turn.signal)

    case start_turn_task(state.work_supervisor, fn ->
           run_operation(turn.operation, begin.agent_state, begin.input, run_opts)
         end) do
      {:ok, task} ->
        state = state |> take_reserved_inbox() |> announce_turn(begin)
        if begin.from, do: GenServer.reply(begin.from, {:ok, turn.id})
        {:noreply, %{state | active_turn: Turn.running(turn, task)}}

      {:error, reason} when is_nil(state.journal) ->
        fail_begin_turn(state, begin, {:turn_task_failed, reason})

      {:error, reason} ->
        state
        |> take_reserved_inbox()
        |> announce_turn(begin)
        |> abort_begun_turn(begin, {:turn_task_failed, reason})
    end
  end

  # The inbox messages journaled before the failure are part of the
  # conversation now; the rest stay queued.
  defp finish_begin_turn(state, begin, {:inbox_failed, reason, journaled}) do
    {journaled, inbox} = Inbox.commit_reserved(state.inbox, journaled)
    state = %{state | inbox: inbox}
    broadcast_inbox_drained(state, journaled)
    abort_begun_turn(state, begin, {:persistence_failed, reason})
  end

  defp finish_begin_turn(state, begin, {:error, reason}),
    do: fail_begin_turn(state, begin, {:persistence_failed, reason})

  # The reserved inbox messages are the turn's now: journaled with its start,
  # or about to be handed to its task.
  defp take_reserved_inbox(state) do
    {entries, inbox} = Inbox.commit_reserved(state.inbox)

    state =
      %{state | inbox: inbox}
      # The session journaled these itself, so no hook reports them appended.
      |> maybe_generate_title(first_user_input(entries))

    broadcast_inbox_drained(state, entries)
    state
  end

  defp announce_turn(state, %{reason: nil}), do: state

  defp announce_turn(state, %{reason: reason}) do
    broadcast(
      state,
      {:tackle_turn_started, state.agent_state.session_id, state.active_turn.id, reason}
    )

    state
  end

  # `turn.started` is journaled, so the turn is settled as crashed (and the
  # state rebuilt from the journal) before the session goes idle; otherwise
  # the journal would keep an active turn and refuse every later one. A
  # caller gets the reason once that is written; a turn the session started
  # from its inbox fails like a crashed turn.
  defp abort_begun_turn(state, begin, reason) do
    release_turn(state)
    state = %{state | active_turn: Turn.settling(state.active_turn)}
    begin_terminal_persist(state, {:runtime_error, reason}, begin.agent_state, begin.from)
  end

  defp fail_begin_turn(state, begin, reason) do
    Turn.delete_signal(state.active_turn)
    release_turn(state)
    if begin.from, do: GenServer.reply(begin.from, {:error, reason})
    state = %{state | active_turn: nil, inbox: Inbox.release(state.inbox)}

    # An ephemeral session's continuation has no caller: its request helper
    # still waits for the one terminal outcome.
    if is_nil(begin.from) and state.lifetime == :ephemeral,
      do: finish_ephemeral(state, {:runtime_error, {:continuation_failed, reason}}),
      else: {:noreply, state}
  end

  # Without a journal there is nothing to commit first.
  defp apply_reconfiguration(%{journal: nil} = state, _from, config),
    do: finish_reconfiguration(state, :ok, config)

  defp apply_reconfiguration(%{journal: journal} = state, from, config) do
    defer_storage(
      state,
      from,
      fn -> Journal.configuration_changed(journal, config) end,
      &finish_reconfiguration(&1, &2, config)
    )
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

  defp delete_operation_signal(%{kind: :operation, signal: signal}),
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

  # Admits and begins a turn. Returns `{:error, reason}` when the turn is not
  # admitted; otherwise the caller (`from`, or nil for a turn the session
  # starts itself) is answered once the turn's task runs or its start failed.
  defp start_turn(state, operation, input, from) do
    with :ok <- admit_turn(state),
         :ok <- acquire_turn(state) do
      begin_turn(state, operation, input, from)
    end
  end

  defp admit_turn(%{recovery: recovery}) when not is_nil(recovery),
    do: {:error, {:recovery_required, recovery}}

  defp admit_turn(%{active_turn: %Turn{}}), do: {:error, :turn_in_progress}
  defp admit_turn(_state), do: :ok

  # The turn takes the whole inbox. A durable turn first journals
  # `turn.started` and those messages in a storage task; without a journal
  # there is nothing to commit, so the begin finishes at once.
  defp begin_turn(state, operation, input, from) do
    turn_id = state.config.id_generator.()
    reason = if is_nil(from), do: Inbox.turn_reason(state.inbox)
    {entries, inbox} = Inbox.reserve(state.inbox)
    {agent_state, messages} = Inbox.project(entries, state.agent_state)
    turn = Turn.new(turn_id, operation, input, agent_state)

    begin = %{
      kind: :begin_turn,
      from: from,
      input: input,
      agent_state: agent_state,
      reason: reason
    }

    state = %{state | active_turn: turn, inbox: inbox}

    if state.journal,
      do: start_begin_commit(state, begin, messages),
      else: finish_begin_turn(state, begin, :ok)
  end

  defp start_begin_commit(state, begin, messages) do
    case start_turn_task(state.work_supervisor, fn -> persist_begin(state, begin, messages) end) do
      {:ok, task} -> {:noreply, %{state | storage_task: Map.put(begin, :task, task)}}
      {:error, reason} -> fail_begin_turn(state, begin, {:storage_task_failed, reason})
    end
  end

  # Only a durable turn can fail after it started in the journal, so only
  # durable terminal persistence has a caller to reply to.
  defp begin_terminal_persist(state, result, agent_state, from \\ nil)

  defp begin_terminal_persist(%{journal: nil} = state, result, agent_state, from),
    do: finish_terminal_persistence(state, terminal(nil, from, result, agent_state), :ok)

  defp begin_terminal_persist(state, result, agent_state, from) do
    owner = self()

    case start_turn_task(state.work_supervisor, fn ->
           persist_terminal(state, result, owner)
         end) do
      {:ok, task} ->
        {:noreply, %{state | storage_task: terminal(task, from, result, agent_state)}}

      {:error, reason} ->
        if from, do: GenServer.reply(from, {:error, {:storage_task_failed, reason}})
        {:stop, {:storage_task_failed, reason}, %{state | active_turn: nil}}
    end
  end

  defp terminal(task, from, result, agent_state),
    do: %{kind: :terminal, task: task, from: from, result: result, agent_state: agent_state}

  defp finish_terminal_persistence(state, pending, {:ok, %AgentState{} = agent_state}),
    do: finish_terminal_persistence(state, %{pending | agent_state: agent_state}, :ok)

  # A caller whose turn failed to start learns it from the reply, once the
  # journal has settled the turn.
  defp finish_terminal_persistence(state, %{from: from} = pending, :ok) when not is_nil(from) do
    {:runtime_error, reason} = pending.result
    GenServer.reply(from, {:error, reason})
    {:noreply, schedule_inbox_wake(%{state | agent_state: pending.agent_state, active_turn: nil})}
  end

  defp finish_terminal_persistence(%{active_turn: turn} = state, pending, :ok) do
    state = %{state | agent_state: pending.agent_state, active_turn: nil}

    case pending.result do
      {:runtime_error, reason} ->
        broadcast_turn_failure(state, turn.id, reason)
        settle(state, pending.result)

      result ->
        state = discard_reported_background_launches(state, turn, pending.agent_state)

        broadcast(
          state,
          {:tackle_turn_finished, pending.agent_state.session_id, turn.id, result}
        )

        settle(state, result)
    end
  end

  defp finish_terminal_persistence(state, pending, reason) do
    if pending.from, do: GenServer.reply(pending.from, {:error, {:persistence_failed, reason}})
    {:stop, {:persistence_failed, reason}, %{state | active_turn: nil}}
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
      tool_context: %{runtime_turn_id: turn_id},
      cancellation_signal: signal,
      before_provider_call: provider_gate(state),
      before_tool_execution: tool_gate(state),
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

  # An ephemeral session reports one terminal outcome and stops. Input it
  # acknowledged after the loop last took queued messages (during
  # `before_turn_end` hooks such as the compile gate, or while the terminal
  # event was written) would be lost, so a successful turn is first continued
  # with it; the outcome of the last turn is delivered. An error or
  # cancellation ends the session at once, dropping input still queued.
  defp settle(%{lifetime: :ephemeral} = state, {:ok, %AgentState{}} = result) do
    if Inbox.pending?(state.inbox),
      do: continue_ephemeral(state),
      else: finish_ephemeral(state, result)
  end

  defp settle(%{lifetime: :ephemeral} = state, result), do: finish_ephemeral(state, result)

  defp settle(state, result) do
    deliver_terminal(state, result)
    {:noreply, schedule_inbox_wake(state)}
  end

  defp finish_ephemeral(state, result) do
    deliver_terminal(state, result)
    {:stop, :normal, state}
  end

  # The continuation announces itself with `:tackle_turn_started` once it runs.
  defp continue_ephemeral(state) do
    case start_turn(state, :continue, nil, nil) do
      {:error, reason} ->
        finish_ephemeral(state, {:runtime_error, {:continuation_failed, reason}})

      result ->
        result
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
    if Inbox.pending?(state.inbox) do
      send(self(), :tackle_inbox_wake)
      %{state | inbox_wake_scheduled?: true}
    else
      state
    end
  end

  defp schedule_inbox_wake(state), do: state

  # A turn the inbox starts announces itself with `:tackle_turn_started` once
  # it runs; one that cannot start leaves the input queued.
  defp start_inbox_turn(state) when is_storage_busy(state), do: {:noreply, state}

  defp start_inbox_turn(%{lifetime: :explicit, recovery: nil, active_turn: nil} = state) do
    if Inbox.pending?(state.inbox) do
      case start_turn(state, :continue, nil, nil) do
        {:error, _reason} -> {:noreply, state}
        result -> result
      end
    else
      {:noreply, state}
    end
  end

  defp start_inbox_turn(state), do: {:noreply, state}

  # Runs after `turn.started`, so a failure reports how many messages were
  # journaled for the session to settle the started turn.
  defp persist_inbox_messages(%{journal: journal}, agent_state, messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {message, index}, :ok ->
      # Write-behind like loop messages: durable at the next sync point.
      case Journal.append_message(
             journal,
             message,
             Persistence.tree_parent(agent_state, message.id),
             sync: false
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:inbox_failed, reason, index}}
      end
    end)
  end

  # A launch whose tool call reported carries its run id in the result; one
  # whose call the loop cut off still owes it to the next turn.
  defp discard_reported_background_launches(state, %Turn{} = turn, %AgentState{} = agent_state) do
    reported = Turn.reported_tool_calls(turn, agent_state)
    %{state | inbox: Inbox.discard_reported_launches(state.inbox, turn.id, reported)}
  end

  defp broadcast_inbox_drained(state, entries) do
    entries
    |> Inbox.drained_events(state.agent_ref)
    |> Enum.each(&broadcast(state, {:tackle_event, state.agent_state.session_id, nil, &1}))
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

  defp cancel_running(%{active_turn: turn} = state, reason),
    do: %{state | active_turn: Turn.cancel(turn, reason)}

  defp apply_configuration(agent_state, config) do
    llm_opts = Keyword.put(config.llm_opts, :credential_store, Auth.credential_store())

    %{agent_state | llm: config.llm, llm_opts: llm_opts}
  end

  # Tools find the agent they act for under `:runtime` (`AgentRef.from_context/1`);
  # the scope coordinator owns what that agent may do.
  defp put_runtime_context(agent_state, %AgentRef{} = agent_ref),
    do: %{agent_state | context: Map.put(agent_state.context, :runtime, agent_ref)}

  defp build_agent_state(config, agent_ref, nil) do
    agent_state =
      config
      |> Config.to_agent_state(credential_store: Auth.credential_store())
      |> put_runtime_context(agent_ref)

    {:ok, config, agent_state, nil, nil, false}
  end

  defp build_agent_state(config, agent_ref, %SessionSpec{} = durable) do
    runtime = %{agent_ref: agent_ref, owner: self()}

    with {:ok, journal} <- Journal.whereis(durable.session_id),
         {:ok, projection} <- Journal.projection(journal),
         {:ok, loaded} <- load_projection(projection, config, durable.override_config),
         :ok <-
           persist_configuration_change(journal, loaded.configuration_changed?, loaded.config),
         :ok <- enable_tree_if_needed(journal, projection, durable.tree) do
      recovery = recovery_for(projection)
      tree_enabled? = durable.tree or projection.tree_enabled?

      case restore_durable_state(journal, loaded, recovery, runtime) do
        {:ok, agent_state} -> {:ok, loaded.config, agent_state, journal, recovery, tree_enabled?}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # After a turn's start failed or its task crashed, the turn's messages are
  # journaled (by the persistence hook, or with the inbox) but the session
  # still holds the pre-turn state. Once the turn is settled in the journal,
  # the state is rebuilt from the journal's projection the way `init/1` builds
  # it, so memory and journal agree again: the next message links to the
  # journaled tip instead of starting a branch (or being refused without
  # branching), and calls the crash left without results are repaired. The
  # session's current configuration is authoritative, so it is not resolved
  # against the recording again. `owner` is the session process, since this
  # runs in a storage task.
  defp reload_durable_state(state, owner) do
    runtime = %{agent_ref: state.agent_ref, owner: owner}

    with {:ok, projection} <- Journal.projection(state.journal),
         {:ok, loaded} <- load_projection(projection, state.config, true) do
      # The turn was just settled, so no turn awaits a recovery decision.
      restore_durable_state(state.journal, loaded, nil, runtime)
    end
  end

  defp load_projection(projection, config, override?) do
    Loader.load(projection, config,
      credential_store: Auth.credential_store(),
      override_config: override?
    )
  end

  defp restore_durable_state(journal, loaded, recovery, runtime) do
    agent_state =
      loaded.state
      |> put_runtime_context(runtime.agent_ref)
      |> install_persistence_hook(runtime.owner)
      |> install_committer()

    repair_interrupted_tool_results(journal, agent_state, loaded.config, recovery)
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
  defp install_persistence_hook(%AgentState{} = state, owner) do
    %{
      state
      | hooks: append(state.hooks, Persistence),
        context:
          state.context |> Map.put(:journal_required, true) |> Map.put(:session_owner, owner)
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

  defp persist_begin(%{active_turn: %Turn{} = turn} = state, begin, messages) do
    with {:ok, _turn_id} <-
           Journal.begin_turn(state.journal, turn.operation, begin.input, turn.id) do
      persist_inbox_messages(state, begin.agent_state, messages)
    end
  end

  defp persist_terminal(
         %{journal: journal, active_turn: %Turn{id: turn_id}} = state,
         result,
         owner
       ) do
    {type, data} = terminal_event(result)

    with :ok <- Journal.settle_turn(journal, type, Map.put(data, "turn_id", turn_id)) do
      case result do
        {:runtime_error, _reason} -> reload_durable_state(state, owner)
        _settled -> :ok
      end
    end
  end

  defp terminal_event({:ok, _agent_state}), do: {"turn.completed", %{"status" => "completed"}}

  defp terminal_event({:error, %AgentState{} = agent_state}),
    do: {"turn.errored", %{"error" => agent_state.error}}

  defp terminal_event({:cancelled, %AgentState{} = agent_state}),
    do: {"turn.cancelled", %{"reason" => agent_state.error}}

  defp terminal_event({:runtime_error, reason}),
    do: {"turn.crashed", %{"reason" => inspect(reason)}}

  # The runtime builds the context, so a session always runs inside a scope
  # whose coordinator and supervisors it can reach; there is no fallback.
  defp validate_ownership(%AgentContext{
         scope_ref: %ScopeRef{scope_id: scope_id},
         agent_ref: %AgentRef{scope_id: scope_id},
         coordinator: coordinator,
         work_supervisor: work_supervisor,
         tool_supervisor: tool_supervisor
       })
       when not is_nil(coordinator) and not is_nil(work_supervisor) and
              not is_nil(tool_supervisor),
       do: :ok

  defp validate_ownership(%AgentContext{}), do: {:error, :invalid_scope_ownership}

  defp register(%AgentRef{} = agent_ref) do
    case Registry.register(agent_ref, :agent) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _pid}} -> {:error, :already_registered}
    end
  end

  defp register_with_coordinator(%{coordinator: coordinator, agent_ref: %AgentRef{} = agent_ref}) do
    Coordinator.register_agent(coordinator, agent_ref, self())
  catch
    :exit, _reason -> :ok
  end

  defp build_snapshot(state) do
    active_turn = if state.active_turn, do: Turn.summary(state.active_turn)

    %Snapshot{
      session_id: state.agent_state.session_id,
      agent_state: state.agent_state,
      active_turn: active_turn,
      agent_ref: state.agent_ref,
      scope_ref: state.scope_ref,
      recovery: state.recovery,
      session_title: state.session_title,
      storage: state.storage_status
    }
  end

  # -- automatic session titles ---------------------------------------------

  # Codex-style automatic titles: the first settled message the user wrote in
  # an untitled durable session starts one bounded, tool-free generation task
  # (`Tackle.Session.Title`). The task runs concurrently with the active turn,
  # so the title is ready soon after the prompt instead of after the turn. An
  # explicit title from the session spec or a resumed journal suppresses
  # generation, and a session generates at most one title.
  defp maybe_generate_title(
         %{session_title: nil, title_task: nil, journal: journal} = state,
         content
       )
       when not is_nil(journal) and is_binary(content) do
    if titles_enabled?(state.config) and String.trim(content) != "" do
      start_title_task(state, content)
    else
      state
    end
  end

  defp maybe_generate_title(state, _content), do: state

  defp first_user_input(entries), do: entries |> Inbox.user_messages() |> List.first()

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

  # Deleting the turn signal also deletes the per-call records of calls a host
  # cancelled through `cancel_tool_call/3`, including calls killed mid-flight
  # or cancelled after they settled.
  defp cleanup_active_turn(%Turn{} = turn) do
    safe_cancellation(fn -> Turn.cancel(turn, :session_closed) end)
    TurnTask.shutdown(turn.task, @task_shutdown_timeout)
    safe_cancellation(fn -> Turn.delete_signal(turn) end)
    :ok
  end

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
