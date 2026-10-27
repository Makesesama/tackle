defmodule Tackle.Session.Inbox do
  @max_messages 32
  @max_deferred 128
  @max_bytes 24 * 1024 * 1024

  @moduledoc """
  The input a `Tackle.Session` has accepted but not yet added to its
  conversation.

  Every entry is a `Tackle.Runtime.Envelope`, oldest first: a message the user
  submitted during a turn (`kind: :message, from: :user`), a message from
  another agent, or a runtime notice. A `:launch` notice is held until its
  tool call settles (`discard_reported_launches/3` drops it once the call
  reported); every other entry is deliverable at the active turn's next
  provider boundary or in the agent's next turn.

  Capacity is bounded per class and in total: at most #{@max_messages} ordinary
  messages (the user's and other agents'), at most #{@max_deferred} deferred notices
  (`:launch` and `:completion`), and #{div(@max_bytes, 1024 * 1024)} MiB of entries.

  A starting turn reserves the entries it takes (`reserve/1`) until its start
  is committed: while a reservation is open entries can only be added, and
  `commit_reserved/2` drops the entries that reached the conversation and
  keeps the rest queued.

  A cancelled turn stops the agent, so `hand_back/1` takes the user's queued
  messages out, to be returned to the frontend unsent, and quiets the rest:
  they stay queued for the agent's next turn, but the inbox is not
  `pending?/1` until a deliverable entry is pushed or a turn reserves it.

  The inbox is a plain value without a process; the session owns it.
  """

  alias Tackle.Lib.Event
  alias Tackle.Lib.Message
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Runtime.AgentRef
  alias Tackle.Runtime.Envelope

  defstruct entries: :queue.new(), bytes: 0, reserved: nil, quiet?: false

  @typedoc "One queued entry: an envelope, or the user's input as one with `from: :user`."
  @type entry :: Envelope.t()

  @type t :: %__MODULE__{
          entries: :queue.queue(entry()),
          bytes: non_neg_integer(),
          reserved: non_neg_integer() | nil,
          quiet?: boolean()
        }

  @doc "Returns an empty inbox."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns the queued entries, oldest first."
  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{entries: entries}), do: :queue.to_list(entries)

  @doc "Queues a message the user submitted while a turn runs."
  @spec push_user(t(), String.t()) :: {:ok, t()} | {:error, :inbox_full}
  def push_user(%__MODULE__{} = inbox, message) when is_binary(message),
    do: admit(inbox, %Envelope{kind: :message, from: :user, message: message})

  @doc """
  Validates and queues an envelope from another agent or the runtime.

  The envelope is rebuilt with `Tackle.Runtime.Envelope.new/4`, so a
  hand-built one cannot pass as the user's input. Overflow returns
  `{:error, :inbox_full}` for a `:message` and `{:error, :deferred_inbox_full}`
  for a notice.
  """
  @spec push(t(), Envelope.t()) :: {:ok, t()} | {:error, term()}
  def push(%__MODULE__{} = inbox, %Envelope{} = envelope) do
    with {:ok, envelope} <-
           Envelope.new(envelope.kind, envelope.from, envelope.message, envelope.origin) do
      admit(inbox, envelope)
    end
  end

  @doc """
  Withdraws the newest queued user message equal to `message`.

  Returns `{:error, :reserved}` while a starting turn holds a reservation.
  """
  @spec withdraw(t(), String.t()) :: {:ok, t()} | {:error, :not_queued | :reserved}
  def withdraw(%__MODULE__{reserved: nil} = inbox, message) do
    index =
      inbox
      |> entries()
      |> Enum.with_index()
      |> Enum.reduce(nil, fn
        {%Envelope{from: :user, message: ^message}, index}, _found -> index
        _entry, found -> found
      end)

    case index do
      nil -> {:error, :not_queued}
      index -> {:ok, put_entries(inbox, List.delete_at(entries(inbox), index))}
    end
  end

  def withdraw(%__MODULE__{}, _message), do: {:error, :reserved}

  @doc """
  Returns true when an entry can be delivered now (anything but a held
  launch) and the inbox is not quiet (see `hand_back/1`).
  """
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{quiet?: true}), do: false
  def pending?(%__MODULE__{entries: entries}), do: :queue.any(&deliverable?/1, entries)

  @doc """
  Takes the deliverable entries for the active turn's next provider boundary,
  leaving held launches queued.
  """
  @spec take_deliverable(t()) :: {[entry()], t()}
  def take_deliverable(%__MODULE__{} = inbox) do
    {deliverable, held} = inbox |> entries() |> Enum.split_with(&deliverable?/1)
    {deliverable, put_entries(inbox, held)}
  end

  @doc """
  Why the inbox would start a turn: `:background_notice` when every
  deliverable entry is a background completion, `:queued_messages` otherwise.
  """
  @spec turn_reason(t()) :: :background_notice | :queued_messages
  def turn_reason(%__MODULE__{} = inbox) do
    deliverable = inbox |> entries() |> Enum.filter(&deliverable?/1)

    if Enum.all?(deliverable, &match?(%Envelope{kind: :completion}, &1)),
      do: :background_notice,
      else: :queued_messages
  end

  @doc """
  Reserves every entry for a starting turn and returns them.

  A launch still held belongs to a turn that was interrupted before its tool
  call reported, so the next turn takes it too.
  """
  @spec reserve(t()) :: {[entry()], t()}
  def reserve(%__MODULE__{reserved: nil} = inbox),
    do: {entries(inbox), %{inbox | reserved: :queue.len(inbox.entries), quiet?: false}}

  @doc """
  Closes the reservation: drops the first `count` reserved entries (`:all` by
  default), which reached the conversation, and returns them. The rest stay
  queued.
  """
  @spec commit_reserved(t(), non_neg_integer() | :all) :: {[entry()], t()}
  def commit_reserved(inbox, count \\ :all)

  def commit_reserved(%__MODULE__{reserved: reserved} = inbox, :all) when is_integer(reserved),
    do: commit_reserved(inbox, reserved)

  def commit_reserved(%__MODULE__{reserved: reserved} = inbox, count)
      when is_integer(reserved) and is_integer(count) and count >= 0 do
    {committed, retained} = inbox |> entries() |> Enum.split(min(count, reserved))
    {committed, %{put_entries(inbox, retained) | reserved: nil}}
  end

  @doc "Closes the reservation and keeps every entry queued."
  @spec release(t()) :: t()
  def release(%__MODULE__{} = inbox), do: %{inbox | reserved: nil}

  @doc """
  Takes the user's queued messages out after a cancelled turn and returns
  them, oldest first, with the inbox quieted.

  Every other entry stays queued for the agent's next turn, but a quiet inbox
  is not `pending?/1`, so it does not start that turn by itself: pushing a
  deliverable entry or reserving the inbox for a turn ends the quiet.
  """
  @spec hand_back(t()) :: {[String.t()], t()}
  def hand_back(%__MODULE__{reserved: nil} = inbox) do
    {user, retained} = inbox |> entries() |> Enum.split_with(&match?(%Envelope{from: :user}, &1))
    {user_messages(user), %{put_entries(inbox, retained) | quiet?: true}}
  end

  @doc """
  Drops the launches of turn `turn_id` whose tool calls reported a result:
  the result carries the run id, so the held notice is no longer owed.
  """
  @spec discard_reported_launches(t(), String.t(), MapSet.t(String.t())) :: t()
  def discard_reported_launches(%__MODULE__{} = inbox, turn_id, reported_tool_calls) do
    retained =
      inbox
      |> entries()
      |> Enum.reject(fn
        %Envelope{kind: :launch, origin: %{turn_id: ^turn_id, tool_call_id: tool_call_id}} ->
          MapSet.member?(reported_tool_calls, tool_call_id)

        _entry ->
          false
      end)

    put_entries(inbox, retained)
  end

  @doc "Returns the model-facing text of an entry."
  @spec content(entry()) :: String.t()
  def content(%Envelope{from: :user, message: message}), do: message

  def content(%Envelope{from: %AgentRef{} = from, message: message}),
    do: "Message from agent #{from.agent_id}:\n\n#{message}"

  @doc """
  Appends entries to `agent_state` as user messages and returns the new state
  and the messages in order.
  """
  @spec project([entry()], AgentState.t()) :: {AgentState.t(), [Message.t()]}
  def project(entries, %AgentState{} = agent_state) do
    {messages, agent_state} =
      Enum.map_reduce(entries, agent_state, fn entry, agent_state ->
        message = Message.user(content(entry), id_generator: agent_state.id_generator)
        {message, AgentState.add_message(agent_state, message)}
      end)

    {agent_state, messages}
  end

  @doc "Returns the messages the user wrote among `entries`, in order."
  @spec user_messages([entry()]) :: [String.t()]
  def user_messages(entries),
    do: for(%Envelope{from: :user, message: message} <- entries, do: message)

  @doc """
  Returns one `:subagent_message_received` event per agent entry among
  `entries`, for the agent `agent_ref` that took them into its conversation.
  """
  @spec drained_events([entry()], AgentRef.t()) :: [Event.t()]
  def drained_events(entries, agent_ref) do
    for %Envelope{from: %AgentRef{} = from} <- entries do
      Event.new(:subagent_message_received, %{from_agent_ref: from, agent_ref: agent_ref})
    end
  end

  defp admit(inbox, entry) do
    size = :erlang.external_size(entry)
    class = class(entry)

    if count(inbox, class) >= limit(class) or inbox.bytes + size > @max_bytes,
      do: {:error, full_error(class)},
      else: {:ok, queue(inbox, entry, size)}
  end

  defp queue(inbox, entry, size) do
    %{
      inbox
      | entries: :queue.in(entry, inbox.entries),
        bytes: inbox.bytes + size,
        quiet?: inbox.quiet? and not deliverable?(entry)
    }
  end

  defp class(%Envelope{kind: :message}), do: :ordinary
  defp class(%Envelope{}), do: :deferred

  defp limit(:ordinary), do: @max_messages
  defp limit(:deferred), do: @max_deferred

  defp full_error(:ordinary), do: :inbox_full
  defp full_error(:deferred), do: :deferred_inbox_full

  defp count(inbox, class), do: inbox |> entries() |> Enum.count(&(class(&1) == class))

  defp deliverable?(%Envelope{kind: :launch}), do: false
  defp deliverable?(%Envelope{}), do: true

  defp put_entries(inbox, entries) do
    bytes = Enum.reduce(entries, 0, &(:erlang.external_size(&1) + &2))
    %{inbox | entries: :queue.from_list(entries), bytes: bytes}
  end
end
