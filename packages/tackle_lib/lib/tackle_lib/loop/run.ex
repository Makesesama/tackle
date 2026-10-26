defmodule Tackle.Lib.Loop.Run do
  @moduledoc false

  # The inputs of one `Tackle.Lib.Loop` turn: the host's run options, validated
  # once, and the turn's frozen `Tackle.Lib.Snapshot`. The loop threads this
  # struct through every step instead of looking options up again.

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.Snapshot
  alias Tackle.Lib.State

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
          empty_response_retried?: boolean()
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
    llm_stream?: false,
    empty_response_retried?: false
  ]

  @doc """
  Validates the host's options and captures the turn's snapshot of `state`.

  Raises `ArgumentError` for an option the loop does not know, before
  anything else happens. `:turn_id` is stored on the snapshot.
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

    %__MODULE__{
      event_callback: Keyword.fetch!(opts, :event_callback),
      tool_context: Keyword.fetch!(opts, :tool_context),
      llm_stream?: Keyword.fetch!(opts, :llm_stream),
      cancellation_signal: Keyword.fetch!(opts, :cancellation_signal),
      tool_supervisor: Keyword.fetch!(opts, :tool_supervisor),
      take_incoming_messages: Keyword.fetch!(opts, :take_incoming_messages),
      before_provider_call: Keyword.fetch!(opts, :before_provider_call),
      before_tool_execution: Keyword.fetch!(opts, :before_tool_execution),
      snapshot: Snapshot.capture(state, turn_id: Keyword.fetch!(opts, :turn_id))
    }
  end

  defp ignore_event(_event), do: :ok
end
