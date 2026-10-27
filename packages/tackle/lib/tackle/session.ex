defmodule Tackle.Session do
  @moduledoc """
  Frontend-independent ownership of one agent's conversation.

  A session owns the settled `Tackle.Lib.State`, permits one active turn, runs
  that turn in a supervised task, forwards correlated library events to
  subscribers, and owns cancellation-signal cleanup. It decides what happens
  and when; the pieces live in helpers it owns as plain values or calls:

    * `Tackle.Session.Turn` - the active turn: its states, cancellation
      signal, and what it records for the session.
    * `Tackle.Session.Inbox` - input accepted but not yet in the
      conversation: user messages submitted during a turn, other agents'
      messages, and runtime notices.
    * `Tackle.Session.Durable` - everything the session writes to or rebuilds
      from its journal: opening (configuration resolution, the recovery of an
      interrupted turn, repair of unresolved tool calls), beginning, settling,
      and abandoning turns, reconfiguration, rebuilding after a crashed turn,
      and the loop's provider and tool gates. It installs
      `Tackle.Session.Persistence` and `Tackle.Session.Committer`.
    * `Tackle.Session.Events` - subscribers and every message they receive.
    * `Tackle.Session.Title` - automatic titles.

  Manual compaction (`compact/2`) and navigation (`navigate/3`) run the
  library's own operations, which in a durable session commit through the
  state's committer before they install the change.

  Journal work never runs in the session process. A turn's begin and terminal
  commits, and the operations that write (compaction, navigation,
  reconfiguration, abandoning a turn), run in storage tasks under the scope's
  work supervisor. While one is outstanding, or while the journal reports
  itself delayed, calls that would write or start a turn return
  `{:error, :storage_busy}`; snapshots, cancellation, and input queued for the
  active turn are still served.

  ## Scoped sessions

  Every session runs under a `Tackle.Runtime.ScopeRef` scope. It runs its turn
  tasks under the scope's shared `Tackle.AgentScope.WorkSupervisor`, registers
  itself in the runtime Registry, and accounts for its turn through the scope
  coordinator. A session without scoped runtime ownership fails to initialize:
  there is no unscoped fallback supervisor. Each session runs beneath a
  `Tackle.Runtime.AgentSupervisor`, whose dedicated tool `Task.Supervisor` keeps
  concurrent tool execution isolated per agent. A session is never restarted:
  its exit tears down its agent subtree, and for the root session the scope.

  Only the root session of a scope started with a `Tackle.Session.Spec` is
  durable (it owns a journal); delegated agents and root sessions without a
  spec keep their conversation in memory only.

  The runtime gives every session a lifetime. An `:explicit` session (the
  root) lives until its scope stops and starts turns from its inbox by itself.
  An `:ephemeral` session (a delegated run) delivers one correlated terminal
  outcome to its request helper and then stops. Input it acknowledged after
  the loop last took queued messages (while `before_turn_end` hooks ran, or
  while the terminal event was written) is not dropped: a successful turn is
  continued with it, and the last turn's outcome is delivered. An error or
  cancelled outcome is delivered at once, and input still queued is dropped
  (after a cancel, the user's messages are handed back first; see below).
  A session process is never reset for another agent identity.

  A cancelled turn stops the agent whatever its lifetime. The user's messages
  still queued are handed back to subscribers unsent
  (`{:tackle_input_returned, ...}`, before the turn's
  `:tackle_turn_finished`), and the rest of the inbox stays queued for the
  next turn without starting one (`Tackle.Session.Inbox.hand_back/1`): an
  `:explicit` session wakes again only for new input.

  Subscription during an active turn is deliberately rejected because events
  are not replayed. Subscribe before submitting a turn to avoid a
  snapshot/event ordering gap. `Tackle.Session.Events` documents every
  message subscribers receive.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Tackle.AgentScope.Coordinator
  alias Tackle.Config
  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Compaction
  alias Tackle.Lib.Event
  alias Tackle.Lib.Message
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Runtime.AgentContext
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Envelope
  alias Tackle.Runtime.Outcome
  alias Tackle.Runtime.Registry
  alias Tackle.Runtime.RunRef
  alias Tackle.Runtime.ScopeRef
  alias Tackle.Runtime.Task, as: TurnTask
  alias Tackle.Session.Durable
  alias Tackle.Session.Events
  alias Tackle.Session.Inbox
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

    @type t :: %__MODULE__{
            session_id: String.t(),
            agent_state: Tackle.Lib.State.t(),
            active_turn: Tackle.Session.Turn.summary() | nil,
            agent_ref: AgentRef.t() | nil,
            scope_ref: ScopeRef.t() | nil,
            recovery: Tackle.Session.Durable.recovery() | nil,
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

  @doc """
  Starts a turn with `input` as its user message, or queues `input` for the
  active turn.

  An idle session returns `{:ok, turn_id}` once the turn's start is committed
  and its task runs; the turn also takes everything queued in the inbox.
  During a turn `input` is queued for the turn's next provider boundary and
  `{:ok, :queued}` is returned (`{:error, :inbox_full}` when the inbox is
  full). An idle session refuses with `{:error, :storage_busy}` while storage
  is busy and with `{:error, {:recovery_required, recovery}}` while an
  interrupted turn awaits `abandon_turn/1`.
  """
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

  @doc """
  Queues an envelope from another agent or the runtime in the inbox.

  During a turn the envelope reaches the conversation at the turn's next
  provider boundary; an idle `:explicit` session starts a turn for it once
  storage is ready. A `:launch` notice is held until its tool call settles
  and never starts a turn. An idle session refuses a `:message` with
  `{:error, :storage_busy}` while storage is busy; runtime notices are kept.
  The envelope is validated (`Tackle.Runtime.Envelope.new/4`), and a full
  inbox returns `{:error, :inbox_full}` or `{:error, :deferred_inbox_full}`.
  """
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
  require and the session can accept new work afterwards. Returns `:ok` at
  once when no turn is interrupted.
  """
  @spec abandon_turn(GenServer.server()) :: :ok | {:error, term()}
  def abandon_turn(session), do: GenServer.call(session, :abandon_turn, :infinity)

  @doc """
  Updates model and thinking settings while the session is idle.

  A durable session records the change in its journal before it
  takes effect; if that write fails, the call returns the error and the
  session stops, like after any other journal failure. Subscribers get
  `:tackle_session_reconfigured` with the new snapshot.
  """
  @spec reconfigure(GenServer.server(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def reconfigure(session, opts) when is_list(opts),
    do: GenServer.call(session, {:reconfigure, opts}, :infinity)

  def reconfigure(_session, opts), do: {:error, {:invalid_config, opts}}

  @doc """
  Navigates the session's conversation tree while it is idle.

  Navigation is rejected with `{:error, :tree_disabled}` in a session without
  branching: a session without a journal (a delegated agent, or a root
  scope started without a `Tackle.Session.Spec`), or a durable one whose
  spec sets `tree: false` and whose journal never enabled it. It is also rejected
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
         {:ok, opened} <- Durable.open(config, context.agent_ref, durable) do
      state = %{
        config: opened.config,
        agent_state: opened.agent_state,
        active_turn: nil,
        events: Events.new(opened.agent_state.session_id),
        scope_ref: context.scope_ref,
        agent_ref: context.agent_ref,
        coordinator: context.coordinator,
        lifetime: context.lifetime,
        terminal: context.terminal,
        work_supervisor: context.work_supervisor,
        tool_supervisor: context.tool_supervisor,
        journal: opened.journal,
        recovery: opened.recovery,
        tree_enabled?: opened.tree_enabled?,
        inbox: Inbox.new(),
        inbox_wake_scheduled?: false,
        title: Title.new(opened.title),
        storage_task: nil,
        storage_status: opened.storage
      }

      register_with_coordinator(state)
      {:ok, state}
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
      fn -> Durable.abandon_turn(journal, state.recovery, state.agent_state, state.config) end,
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
      |> Keyword.put(:before_provider_call, Durable.provider_gate(state.journal))
      |> Keyword.put(:cancellation_signal, signal)

    defer_storage(
      state,
      from,
      fn -> Compaction.compact(state.agent_state, :manual, compaction_opts) end,
      &finish_compaction/2,
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
    with :ok <- validate_reconfigure_options(opts),
         {:ok, config} <- Config.update(state.config, opts) do
      apply_reconfiguration(state, from, config)
    else
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
    state = %{state | events: Events.subscribe(state.events, subscriber)}
    {:reply, {:ok, build_snapshot(state)}, state}
  end

  def handle_call(:unsubscribe, {subscriber, _tag}, state),
    do: {:reply, :ok, %{state | events: Events.unsubscribe(state.events, subscriber)}}

  @impl true
  def handle_cast(
        {:background_finished, %RunRef{} = run_ref, profile, %Outcome{} = outcome},
        state
      ) do
    publish_background_finished(state, run_ref, profile, outcome)
    {:noreply, state}
  end

  def handle_cast({:publish_event, %Event{} = event}, state) do
    Events.event(state.events, nil, event)
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

  def handle_info({:tackle_compaction_progress, session_id, %Event{} = event}, state)
      when session_id == state.agent_state.session_id do
    Events.event(state.events, nil, event)
    {:noreply, state}
  end

  def handle_info({:tackle_storage, session_id, status}, state)
      when session_id == state.agent_state.session_id and status in [:ready, :delayed] do
    Events.storage(state.events, status)
    {:noreply, schedule_inbox_wake(%{state | storage_status: status})}
  end

  def handle_info(
        {:tackle_event, _turn_id,
         %Event{type: :subagent_progress, data: %{background: true}} = event},
        state
      ) do
    Events.event(state.events, nil, event)
    {:noreply, state}
  end

  def handle_info(
        {:tackle_event, turn_id, %Event{} = event},
        %{active_turn: %Turn{id: turn_id} = turn} = state
      ) do
    event = Events.project_usage(event, state.agent_state)
    Events.event(state.events, turn_id, event)

    {:noreply, %{state | active_turn: Turn.record_event(turn, event)}}
  end

  # Only input the user wrote can title the session: the turn's own input and
  # queued user messages, not agent messages, background notices, or hook
  # feedback the loop also appends as user messages.
  def handle_info({:tackle_message_appended, session_id, %Message{} = message}, state)
      when session_id == state.agent_state.session_id do
    if Turn.user_authored?(state.active_turn, message),
      do: {:noreply, maybe_start_title(state, message.content)},
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

  # A generated title is already committed through the journal's metadata
  # path, so the projection, catalog, and every frontend pick it up.
  def handle_info({ref, result}, %{title: {:pending, %TurnTask{ref: ref} = task}} = state) do
    Process.demonitor(task.monitor, [:flush])
    {:noreply, finish_title(state, result)}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{title: {:pending, %TurnTask{monitor: monitor}}} = state
      ),
      do: {:noreply, finish_title(state, {:exit, reason})}

  def handle_info(:tackle_inbox_wake, state),
    do: start_inbox_turn(%{state | inbox_wake_scheduled?: false})

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state),
    do: {:noreply, %{state | events: Events.down(state.events, pid, monitor)}}

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
    Title.shutdown(state.title, @task_shutdown_timeout)

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
      |> maybe_start_title(entries |> Inbox.user_messages() |> List.first())

    broadcast_inbox_drained(state, entries)
    state
  end

  defp announce_turn(state, %{reason: nil}), do: state

  defp announce_turn(state, %{reason: reason}) do
    Events.turn_started(state.events, state.active_turn.id, reason)
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
  # A running session changes only its model and thinking level; the rest of
  # its configuration is fixed when it starts.
  defp validate_reconfigure_options(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_config, opts}}

      (unknown = Keyword.keys(opts) -- [:model, :thinking]) != [] ->
        {:error, {:unknown_reconfigure_options, Enum.uniq(unknown)}}

      true ->
        :ok
    end
  end

  defp apply_reconfiguration(%{journal: nil} = state, _from, config),
    do: finish_reconfiguration(state, :ok, config)

  defp apply_reconfiguration(%{journal: journal} = state, from, config) do
    defer_storage(
      state,
      from,
      fn -> Durable.configure(journal, config) end,
      &finish_reconfiguration(&1, &2, config)
    )
  end

  defp finish_reconfiguration(state, :ok, config) do
    agent_state = apply_configuration(state.agent_state, config)
    state = %{state | config: config, agent_state: agent_state}
    snapshot = build_snapshot(state)
    Events.reconfigured(state.events, snapshot)
    {:reply, {:ok, snapshot}, state}
  end

  defp finish_reconfiguration(state, {:error, reason}, _config),
    do: {:stop, {:persistence_failed, reason}, {:error, reason}, state}

  # A failed or cancelled compaction still returns the last committed state:
  # when an earlier pass committed, the session keeps and broadcasts it.
  defp finish_compaction(state, result) do
    case result do
      {:ok, agent_state, record} ->
        state = %{state | agent_state: agent_state}
        snapshot = build_snapshot(state)
        Events.compacted(state.events, snapshot, record)
        {:reply, {:ok, snapshot, record}, state}

      {status, reason, agent_state} when status in [:error, :cancelled] ->
        state = keep_committed_compaction(state, agent_state)
        reply = if status == :cancelled, do: {:cancelled, reason}, else: reason
        {:reply, {:error, reply}, state}
    end
  end

  defp keep_committed_compaction(state, agent_state) do
    if AgentState.last_compaction_id(agent_state) ==
         AgentState.last_compaction_id(state.agent_state) do
      state
    else
      state = %{state | agent_state: agent_state}
      Events.compacted(state.events, build_snapshot(state), nil)
      state
    end
  end

  defp finish_navigation(state, result) do
    case result do
      {:ok, agent_state, outcome} ->
        state = %{state | agent_state: agent_state}
        snapshot = build_snapshot(state)

        Events.navigated(state.events, snapshot, outcome)

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
    journal = state.journal

    commit_storage(state, begin, fn ->
      Durable.begin_turn(journal, turn, input, agent_state, messages)
    end)
  end

  # Only a durable turn can fail after it started in the journal, so only
  # durable terminal persistence has a caller to reply to.
  defp begin_terminal_persist(state, result, agent_state, from \\ nil) do
    %{journal: journal, active_turn: %Turn{id: turn_id}} = state
    rebuild = rebuild_after(state, result)
    pending = %{kind: :terminal, from: from, result: result, agent_state: agent_state}

    commit_storage(state, pending, fn ->
      with :ok <- Durable.settle_turn(journal, turn_id, result), do: rebuild.()
    end)
  end

  # A durable crashed turn's messages are journaled while the session holds
  # the pre-turn state, and a turn that failed because the journal refused a
  # message holds that message, which the journal does not have. Either is
  # rebuilt from the journal once the turn is settled.
  defp rebuild_after(%{journal: journal} = state, result) when not is_nil(journal) do
    if diverged?(result) do
      %{config: config, agent_ref: agent_ref, tree_enabled?: tree_enabled?} = state
      fn -> Durable.reopen(journal, config, agent_ref, tree_enabled?) end
    else
      fn -> :ok end
    end
  end

  defp rebuild_after(_state, _result), do: fn -> :ok end

  defp diverged?({:runtime_error, _reason}), do: true

  defp diverged?({:error, %AgentState{error_reason: {:message_not_journaled, _reason}}}),
    do: true

  defp diverged?(_result), do: false

  # Without a journal a begin or terminal commit writes nothing, so it
  # finishes at once; a durable one runs in a storage task.
  defp commit_storage(%{journal: nil} = state, pending, fun),
    do: finish_storage_task(state, Map.put(pending, :task, nil), fun.())

  defp commit_storage(state, pending, fun) do
    case start_turn_task(state.work_supervisor, fun) do
      {:ok, task} ->
        {:noreply, %{state | storage_task: Map.put(pending, :task, task)}}

      {:error, reason} ->
        fail_storage_commit(state, pending, {:storage_task_failed, reason})
    end
  end

  defp fail_storage_commit(state, %{kind: :begin_turn} = begin, reason),
    do: fail_begin_turn(state, begin, reason)

  defp fail_storage_commit(state, %{kind: :terminal, from: from}, reason) do
    if from, do: GenServer.reply(from, {:error, reason})
    {:stop, reason, %{state | active_turn: nil}}
  end

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
        Events.turn_failed(state.events, turn.id, reason)
        settle(state, pending.result)

      result ->
        state =
          state
          |> discard_reported_background_launches(turn, pending.agent_state)
          |> hand_back_queued_input(turn, result)

        Events.turn_finished(state.events, turn.id, result)

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
      before_provider_call: Durable.provider_gate(state.journal),
      before_tool_execution: Durable.tool_gate(state.journal),
      llm_stream: state.config.llm_stream,
      take_incoming_messages: fn -> GenServer.call(session_pid, :take_incoming_messages) end,
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

    Events.event(state.events, nil, event)
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

  # A launch whose tool call reported carries its run id in the result; one
  # whose call the loop cut off still owes it to the next turn.
  defp discard_reported_background_launches(state, %Turn{} = turn, %AgentState{} = agent_state) do
    reported = Turn.reported_tool_calls(turn, agent_state)
    %{state | inbox: Inbox.discard_reported_launches(state.inbox, turn.id, reported)}
  end

  # A cancelled turn stops the agent: the user's queued messages go back to
  # the frontend unsent, and the quieted inbox starts no turn by itself.
  defp hand_back_queued_input(state, %Turn{} = turn, {:cancelled, %AgentState{}}) do
    {messages, inbox} = Inbox.hand_back(state.inbox)
    if messages != [], do: Events.input_returned(state.events, turn.id, messages)
    %{state | inbox: inbox}
  end

  defp hand_back_queued_input(state, %Turn{}, _result), do: state

  defp broadcast_inbox_drained(state, entries) do
    entries
    |> Inbox.drained_events(state.agent_ref)
    |> Enum.each(&Events.event(state.events, nil, &1))
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

  defp apply_configuration(agent_state, config),
    do: %{agent_state | llm: config.llm, llm_opts: config.llm_opts}

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
      session_title: Title.current(state.title),
      storage: state.storage_status
    }
  end

  # Only the first message the user wrote in an untitled session starts a
  # title (`Tackle.Session.Title`); the generation runs beside the turn.
  defp maybe_start_title(%{title: :untitled} = state, content) do
    %{config: config, journal: journal, work_supervisor: supervisor} = state
    title = Title.start(config, journal, supervisor, state.agent_state.session_id, content)
    %{state | title: title}
  end

  defp maybe_start_title(state, _content), do: state

  defp finish_title(state, result) do
    title = Title.finish(result)
    state = %{state | title: title}

    case title do
      {:titled, text} ->
        Events.title_changed(state.events, text)
        state

      _failed ->
        state
    end
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
