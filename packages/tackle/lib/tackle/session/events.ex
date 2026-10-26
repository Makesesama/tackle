defmodule Tackle.Session.Events do
  @moduledoc """
  A `Tackle.Session`'s subscribers and the messages it sends them.

  A process subscribes through `Tackle.Session.subscribe/1` (`Tackle.subscribe/1`)
  while the session is idle, and is monitored until it unsubscribes or exits.
  Messages are sent when they happen and never replayed; the snapshot
  `subscribe/1` returns is the state they start from.

  ## Subscriber messages

  Every message carries the session id, so one process can follow several
  sessions:

    * `{:tackle_event, session_id, turn_id, %Tackle.Lib.Event{}}` - a library
      event of the turn `turn_id`. A `:usage` event also carries the selected
      model's `:model_info` and, when the model declares a context window,
      `:context_usage` (`Tackle.Lib.ContextUsage`).
    * `{:tackle_event, session_id, nil, %Tackle.Lib.Event{}}` - an event
      outside any turn: the progress of a manual compaction (`:compaction_start`,
      `:compaction_end`), a background subagent's `:subagent_progress` and
      `:subagent_finished`, `:subagent_message_received` when the session
      takes an agent's message into its conversation, and auxiliary events
      services publish (`Tackle.Session.publish_event/2`).
    * `{:tackle_turn_started, session_id, turn_id, reason}` - the session
      started a turn itself, for queued input (`:queued_messages`) or for
      background completions only (`:background_notice`). A turn a caller
      starts is not announced: the caller gets its id.
    * `{:tackle_turn_finished, session_id, turn_id, {status, agent_state}}` -
      the turn ended with `:ok`, `:error`, or `:cancelled`; the state is the
      session's settled state.
    * `{:tackle_turn_failed, session_id, turn_id, reason}` - the turn's task
      crashed or returned something else, or an announced turn could not
      start after its start was journaled. The session keeps its state from
      before the turn, rebuilt from the journal when it has one.
    * `{:tackle_session_reconfigured, session_id, %Tackle.Session.Snapshot{}}` -
      the model or thinking level changed (`Tackle.Session.reconfigure/2`).
    * `{:tackle_session_compacted, session_id, %Tackle.Session.Snapshot{}, record}` -
      a manual compaction committed `record` (`Tackle.Lib.Compaction.Record`),
      or `nil` when it failed after an earlier pass committed.
    * `{:tackle_session_navigated, session_id, %Tackle.Session.Snapshot{}, outcome}` -
      the conversation tree moved (`Tackle.Lib.Tree.Navigator.Outcome`).
    * `{:tackle_session_title_changed, session_id, title}` - an automatic
      title was committed (`Tackle.Session.Title`).
    * `{:tackle_storage, session_id, :delayed | :ready}` - the journal fell
      behind, or caught up again.

  The session also delivers an ephemeral run's terminal outcome to its
  request helper, not to subscribers, as
  `{:tackle_runtime_terminal, run_id, %Tackle.Runtime.Outcome{}}`.
  """

  alias Tackle.Lib.ContextUsage
  alias Tackle.Lib.Event
  alias Tackle.Lib.State, as: AgentState

  @enforce_keys [:session_id]
  defstruct [:session_id, subscribers: %{}]

  @type t :: %__MODULE__{session_id: String.t(), subscribers: %{pid() => reference()}}

  @doc "No subscribers yet for the session `session_id`."
  @spec new(String.t()) :: t()
  def new(session_id) when is_binary(session_id), do: %__MODULE__{session_id: session_id}

  @doc "Adds and monitors `pid`; subscribing twice keeps one subscription."
  @spec subscribe(t(), pid()) :: t()
  def subscribe(%__MODULE__{subscribers: subscribers} = events, pid) when is_pid(pid) do
    if Map.has_key?(subscribers, pid),
      do: events,
      else: %{events | subscribers: Map.put(subscribers, pid, Process.monitor(pid))}
  end

  @doc "Removes and demonitors `pid`, if it is subscribed."
  @spec unsubscribe(t(), pid()) :: t()
  def unsubscribe(%__MODULE__{subscribers: subscribers} = events, pid) do
    case Map.pop(subscribers, pid) do
      {nil, _subscribers} ->
        events

      {monitor, subscribers} ->
        Process.demonitor(monitor, [:flush])
        %{events | subscribers: subscribers}
    end
  end

  @doc """
  Drops the subscriber a `:DOWN` message with `monitor` reports for `pid`;
  any other monitor leaves the subscribers as they are.
  """
  @spec down(t(), pid(), reference()) :: t()
  def down(%__MODULE__{subscribers: subscribers} = events, pid, monitor) do
    case subscribers do
      %{^pid => ^monitor} -> %{events | subscribers: Map.delete(subscribers, pid)}
      _other -> events
    end
  end

  @doc "Sends an event of the turn `turn_id`, or of no turn when it is `nil`."
  @spec event(t(), String.t() | nil, Event.t()) :: :ok
  def event(events, turn_id, %Event{} = event),
    do: broadcast(events, {:tackle_event, events.session_id, turn_id, event})

  @doc "Announces a turn the session started itself."
  @spec turn_started(t(), String.t(), :queued_messages | :background_notice) :: :ok
  def turn_started(events, turn_id, reason),
    do: broadcast(events, {:tackle_turn_started, events.session_id, turn_id, reason})

  @doc "Reports how a turn ended."
  @spec turn_finished(t(), String.t(), {:ok | :error | :cancelled, AgentState.t()}) :: :ok
  def turn_finished(events, turn_id, result),
    do: broadcast(events, {:tackle_turn_finished, events.session_id, turn_id, result})

  @doc "Reports a turn that crashed or could not begin."
  @spec turn_failed(t(), String.t(), term()) :: :ok
  def turn_failed(events, turn_id, reason),
    do: broadcast(events, {:tackle_turn_failed, events.session_id, turn_id, reason})

  @doc "Reports a reconfiguration."
  @spec reconfigured(t(), struct()) :: :ok
  def reconfigured(events, snapshot),
    do: broadcast(events, {:tackle_session_reconfigured, events.session_id, snapshot})

  @doc "Reports a committed compaction, or `nil` for one a later pass failed."
  @spec compacted(t(), struct(), Tackle.Lib.Compaction.Record.t() | nil) :: :ok
  def compacted(events, snapshot, record),
    do: broadcast(events, {:tackle_session_compacted, events.session_id, snapshot, record})

  @doc "Reports a committed navigation."
  @spec navigated(t(), struct(), Tackle.Lib.Tree.Navigator.Outcome.t()) :: :ok
  def navigated(events, snapshot, outcome),
    do: broadcast(events, {:tackle_session_navigated, events.session_id, snapshot, outcome})

  @doc "Reports a committed title."
  @spec title_changed(t(), String.t()) :: :ok
  def title_changed(events, title),
    do: broadcast(events, {:tackle_session_title_changed, events.session_id, title})

  @doc "Reports the journal's storage status."
  @spec storage(t(), :ready | :delayed) :: :ok
  def storage(events, status) when status in [:ready, :delayed],
    do: broadcast(events, {:tackle_storage, events.session_id, status})

  @doc """
  Adds the selected model's metadata and the context pressure it implies to
  a `:usage` event; keys the event already carries are kept. Other events
  are returned as they are.
  """
  @spec project_usage(Event.t(), AgentState.t()) :: Event.t()
  def project_usage(%Event{type: :usage, data: %{usage: usage} = data} = event, %AgentState{
        llm: llm
      }) do
    data = Map.put_new_lazy(data, :model_info, fn -> llm && llm.model_info end)

    data =
      Map.put_new_lazy(data, :context_usage, fn ->
        ContextUsage.from_usage(usage, data.model_info)
      end)

    %{event | data: data}
  end

  def project_usage(%Event{} = event, %AgentState{}), do: event

  defp broadcast(%__MODULE__{subscribers: subscribers}, message) do
    Enum.each(subscribers, fn {pid, _monitor} -> send(pid, message) end)
  end
end
