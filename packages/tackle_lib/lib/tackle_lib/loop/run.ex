defmodule Tackle.Lib.Loop.Run do
  @moduledoc false

  # The inputs of one `Tackle.Lib.Loop` turn: the host's run options, validated
  # once, and the turn's frozen `Tackle.Lib.Snapshot`. The loop threads this
  # struct through every step instead of looking options up again.
  #
  # It also carries the loop's own bookkeeping, which hosts never see and
  # which therefore stays off `Tackle.Lib.State`:
  #
  #   * `assistant_id` - the id of the assistant message the current step
  #     generates, minted at its `message_start` (`nil` before the first step);
  #   * `overflow_retries` - the context-overflow recoveries the turn has spent,
  #     bounded by the compaction policy's `overflow_retry_limit`.
  #
  # The functions below are the operations every step performs through those
  # inputs: emitting events to the run's callback, invoking the snapshot's
  # hooks with the run's cancellation signal, finalizing a message, and
  # observing cancellation. `Tackle.Lib.Loop`, `Tackle.Lib.Loop.Provider`, and
  # `Tackle.Lib.Loop.Tools` share them.

  require Logger

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.Hook
  alias Tackle.Lib.LLM.Selection
  alias Tackle.Lib.Message
  alias Tackle.Lib.Snapshot
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Policy

  @type gate :: (-> :ok | {:error, term()}) | nil

  @type t :: %__MODULE__{
          event_callback: (Event.t() -> any()),
          tool_context: map(),
          llm_stream?: boolean(),
          cancellation_signal: Cancellation.signal() | nil,
          tool_supervisor: Supervisor.supervisor() | nil,
          take_incoming_messages: (-> {:ok, [String.t()]} | {:error, term()}) | nil,
          before_provider_call: gate(),
          before_tool_execution: gate(),
          snapshot: Snapshot.t(),
          assistant_id: String.t() | nil,
          overflow_retries: non_neg_integer()
        }

  @enforce_keys [:event_callback, :tool_context, :snapshot]
  defstruct [
    :event_callback,
    :tool_context,
    :cancellation_signal,
    :tool_supervisor,
    :take_incoming_messages,
    :before_provider_call,
    :before_tool_execution,
    :snapshot,
    :assistant_id,
    llm_stream?: false,
    overflow_retries: 0
  ]

  @doc """
  Validates the host's options and captures the turn's snapshot of `state`.

  Raises `ArgumentError` for an option the loop does not know, for a state
  without a `Tackle.Lib.LLM.Selection` in `:llm`, or for a concurrent tool
  policy without a `:tool_supervisor`, before anything else happens. `:turn_id` is stored on the snapshot.
  """
  @spec new!(keyword(), State.t()) :: t()
  def new!(opts, %State{} = state) when is_list(opts) do
    opts =
      Keyword.validate!(opts,
        event_callback: &ignore_event/1,
        tool_context: %{},
        llm_stream: false,
        cancellation_signal: nil,
        turn_id: nil,
        tool_supervisor: nil,
        take_incoming_messages: nil,
        before_provider_call: nil,
        before_tool_execution: nil
      )

    validate_llm!(state.llm)
    tool_supervisor = Keyword.fetch!(opts, :tool_supervisor)
    validate_tool_supervisor!(state.tool_policy, tool_supervisor)

    %__MODULE__{
      event_callback: Keyword.fetch!(opts, :event_callback),
      tool_context: Keyword.fetch!(opts, :tool_context),
      llm_stream?: Keyword.fetch!(opts, :llm_stream),
      cancellation_signal: Keyword.fetch!(opts, :cancellation_signal),
      tool_supervisor: tool_supervisor,
      take_incoming_messages: Keyword.fetch!(opts, :take_incoming_messages),
      before_provider_call: Keyword.fetch!(opts, :before_provider_call),
      before_tool_execution: Keyword.fetch!(opts, :before_tool_execution),
      snapshot: Snapshot.capture(state, turn_id: Keyword.fetch!(opts, :turn_id))
    }
  end

  defp validate_llm!(%Selection{}), do: :ok

  defp validate_llm!(llm) do
    raise ArgumentError,
          "the loop needs a Tackle.Lib.LLM.Selection in the state's :llm, got: #{inspect(llm)}; " <>
            "select one with Tackle.Lib.LLM.select/2 and pass it to Tackle.Lib.State.new/1"
  end

  defp validate_tool_supervisor!(%Policy{execution_mode: :concurrent}, nil) do
    raise ArgumentError,
          "concurrent tool execution requires a :tool_supervisor option; " <>
            "pass a Task.Supervisor or use the sequential tool policy"
  end

  defp validate_tool_supervisor!(_policy, _supervisor), do: :ok

  defp ignore_event(_event), do: :ok

  @doc """
  Emits `event` through the run's event callback.

  Events are observations: a crashing callback is logged and the turn goes
  on, so an observer's bug cannot leave the transcript half-settled.
  """
  @spec emit(t(), Event.t()) :: :ok
  def emit(%__MODULE__{event_callback: callback}, %Event{} = event) do
    callback.(event)
    :ok
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__

      Logger.error(fn ->
        [
          "Event callback crashed on ",
          inspect(event.type),
          ": ",
          Exception.format(kind, reason, stacktrace)
        ]
      end)

      :ok
  end

  @doc "Returns true once the run's cancellation signal has been cancelled."
  @spec cancelled?(t()) :: boolean()
  def cancelled?(%__MODULE__{cancellation_signal: signal}), do: Cancellation.cancelled?(signal)

  @doc "Marks `state` cancelled with the reason of the run's cancellation signal."
  @spec mark_cancelled(State.t(), t()) :: State.t()
  def mark_cancelled(%State{} = state, %__MODULE__{cancellation_signal: signal}) do
    State.set_cancelled(state, signal |> Cancellation.reason() |> cancellation_reason())
  end

  defp cancellation_reason(nil), do: "Cancelled"
  defp cancellation_reason(reason) when is_binary(reason), do: reason
  defp cancellation_reason(reason), do: inspect(reason)

  @doc """
  The options `Tackle.Lib.Compaction.compact/3` needs to compact within the
  run: its snapshot, event callback, provider gate, and cancellation signal.
  """
  @spec compaction_opts(t()) :: keyword()
  def compaction_opts(%__MODULE__{} = run) do
    opts = [
      snapshot: run.snapshot,
      event_callback: run.event_callback,
      before_provider_call: run.before_provider_call
    ]

    case run.cancellation_signal do
      nil -> opts
      signal -> Keyword.put(opts, :cancellation_signal, signal)
    end
  end

  @doc """
  Invokes the snapshot's `hook` callbacks with `args` and keeps the context
  they return on `state`.
  """
  @spec invoke_hook(State.t(), t(), Hook.event(), [term()]) :: {:ok, State.t()} | {:error, term()}
  def invoke_hook(%State{} = state, %__MODULE__{} = run, hook, args) do
    case Hook.invoke(run.snapshot.hooks, hook, args, hook_context(state, run)) do
      {:ok, context} -> {:ok, put_hook_context(state, context)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the context hooks see: the state's context with the run's
  cancellation signal, so a slow hook (such as a gate that compiles the
  project) can stop early.
  """
  @spec hook_context(State.t(), t()) :: map()
  def hook_context(%State{context: %{cancellation_signal: _} = context}, _run), do: context

  def hook_context(%State{context: context}, %__MODULE__{cancellation_signal: signal})
      when not is_nil(signal),
      do: Map.put(context, :cancellation_signal, signal)

  def hook_context(%State{context: context}, _run), do: context

  @doc """
  Stores the context a hook returned on `state`.

  The run's cancellation signal belongs to the run and is not kept, unless the
  host put that key into the state's context itself.
  """
  @spec put_hook_context(State.t(), map()) :: State.t()
  def put_hook_context(%State{context: %{cancellation_signal: _}} = state, context),
    do: %{state | context: context}

  def put_hook_context(%State{} = state, context),
    do: %{state | context: Map.delete(context, :cancellation_signal)}

  @doc """
  Finalizes a message already added to `state`: emits its `message_end` event
  and runs the `after_message` hooks. A hook error sets `state.error`, with
  the hook's reason as `state.error_reason`.
  """
  @spec finalize_message(State.t(), t(), Message.t()) :: {:ok, State.t()} | {:error, State.t()}
  def finalize_message(%State{} = state, %__MODULE__{} = run, %Message{} = message) do
    emit(run, Event.message_end(message))

    case invoke_hook(state, run, :after_message, [state, message]) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        {:error, State.set_error(state, "Hook aborted after message: #{inspect(reason)}", reason)}
    end
  end
end
