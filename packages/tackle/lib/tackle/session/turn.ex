defmodule Tackle.Session.Turn do
  @moduledoc """
  The active turn of a `Tackle.Session`.

  A turn goes through three states:

    * `:starting` - its start is being committed; it has a cancellation
      signal but no task yet.
    * `:running` - its task runs the agent loop.
    * `:settling` - its task has finished and its terminal event is being
      written. The cancellation signal is deleted, so the turn can no longer
      be cancelled, but it still holds the session's one turn.

  Besides its identity the turn records what the session needs when it ends:
  the messages it started from, the user's own input (`user_inputs`, which
  alone may title the session), and the tool calls the loop settled as
  interrupted. The struct is owned by the session process; only the signal
  functions touch shared state, the cancellation store.
  """

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.Message
  alias Tackle.Lib.State, as: AgentState
  alias Tackle.Runtime.Task, as: TurnTask

  @enforce_keys [:id, :operation, :signal, :initial_message_ids]
  defstruct [
    :id,
    :operation,
    :signal,
    :initial_message_ids,
    task: nil,
    status: :starting,
    user_inputs: [],
    interrupted_tool_calls: MapSet.new(),
    cancellation_requested?: false
  ]

  @type operation :: :run | :continue
  @type status :: :starting | :running | :settling

  @type t :: %__MODULE__{
          id: String.t(),
          operation: operation(),
          signal: Cancellation.signal(),
          initial_message_ids: MapSet.t(String.t()),
          task: TurnTask.t() | nil,
          status: status(),
          user_inputs: [String.t()],
          interrupted_tool_calls: MapSet.t(String.t()),
          cancellation_requested?: boolean()
        }

  @typedoc "What a session snapshot shows of its active turn."
  @type summary :: %{
          id: String.t(),
          operation: operation(),
          cancellation_requested?: boolean()
        }

  @doc """
  Creates a starting turn with a fresh cancellation signal.

  `agent_state` is the state the turn runs from, with the inbox entries it
  took already added; `input` is the user's input of a `:run`.
  """
  @spec new(String.t(), operation(), String.t() | nil, AgentState.t()) :: t()
  def new(id, operation, input, %AgentState{} = agent_state)
      when operation in [:run, :continue] do
    %__MODULE__{
      id: id,
      operation: operation,
      signal: Cancellation.new_signal(),
      initial_message_ids: MapSet.new(agent_state.messages, & &1.id),
      user_inputs: if(operation == :run and is_binary(input), do: [input], else: [])
    }
  end

  @doc "Marks the turn running in `task`."
  @spec running(t(), TurnTask.t()) :: t()
  def running(%__MODULE__{status: :starting} = turn, %TurnTask{} = task),
    do: %{turn | task: task, status: :running}

  @doc """
  Marks the turn settling and deletes its cancellation signal, with the
  per-call records of calls a host cancelled.
  """
  @spec settling(t()) :: t()
  def settling(%__MODULE__{} = turn) do
    :ok = delete_signal(turn)
    %{turn | status: :settling}
  end

  @doc """
  Requests cancellation with `reason`. A settling turn has already observed
  its outcome, so only the request is recorded.
  """
  @spec cancel(t(), term()) :: t()
  def cancel(%__MODULE__{} = turn, reason) do
    if turn.status != :settling, do: Cancellation.cancel(turn.signal, reason)
    %{turn | cancellation_requested?: true}
  end

  @doc """
  Cancels one tool call's per-call signal. Every call of a settling turn has
  finished, so that does nothing.
  """
  @spec cancel_tool_call(t(), String.t(), term()) :: :ok
  def cancel_tool_call(%__MODULE__{status: :settling}, _tool_call_id, _reason), do: :ok

  def cancel_tool_call(%__MODULE__{signal: signal}, tool_call_id, reason) do
    signal |> Cancellation.for_call(tool_call_id) |> Cancellation.cancel(reason)
  end

  @doc "Deletes the turn's cancellation signal and every per-call signal derived from it."
  @spec delete_signal(t()) :: :ok
  def delete_signal(%__MODULE__{signal: signal}), do: Cancellation.delete(signal)

  @doc """
  Records what a turn event tells the session: a tool call the loop settled
  synthetically on an interrupted batch did not actually report anything.
  """
  @spec record_event(t(), Event.t()) :: t()
  def record_event(
        %__MODULE__{} = turn,
        %Event{type: :tool_error, data: %{reason: :interrupted, tool_call_id: id}}
      )
      when is_binary(id),
      do: %{turn | interrupted_tool_calls: MapSet.put(turn.interrupted_tool_calls, id)}

  def record_event(%__MODULE__{} = turn, %Event{}), do: turn

  @doc "Records queued user messages the turn took into its conversation."
  @spec record_user_inputs(t(), [String.t()]) :: t()
  def record_user_inputs(%__MODULE__{} = turn, inputs) when is_list(inputs),
    do: %{turn | user_inputs: turn.user_inputs ++ inputs}

  @doc "Returns true when `message` is input the user wrote during the turn."
  @spec user_authored?(t() | nil, Message.t()) :: boolean()
  def user_authored?(%__MODULE__{user_inputs: inputs}, %Message{role: :user, content: content}),
    do: content in inputs

  def user_authored?(_turn, _message), do: false

  @doc """
  Returns the ids of the tool calls whose results the turn added to
  `agent_state`, leaving out calls the loop settled as interrupted.
  """
  @spec reported_tool_calls(t(), AgentState.t()) :: MapSet.t(String.t())
  def reported_tool_calls(%__MODULE__{} = turn, %AgentState{} = agent_state) do
    agent_state.messages
    |> Enum.reject(&MapSet.member?(turn.initial_message_ids, &1.id))
    |> Enum.flat_map(fn
      %Message{role: :tool, tool_call_id: tool_call_id} when is_binary(tool_call_id) ->
        [tool_call_id]

      _message ->
        []
    end)
    |> MapSet.new()
    |> MapSet.difference(turn.interrupted_tool_calls)
  end

  @doc "Returns what a session snapshot shows of the turn."
  @spec summary(t()) :: summary()
  def summary(%__MODULE__{} = turn),
    do: Map.take(turn, [:id, :operation, :cancellation_requested?])
end
