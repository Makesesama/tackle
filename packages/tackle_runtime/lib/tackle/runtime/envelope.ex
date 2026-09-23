defmodule Tackle.Runtime.Envelope do
  @moduledoc """
  One model-facing message addressed to an agent in a scope.

  `:message` is ordinary agent text. `:launch` is held until its originating
  tool call settles: a committed tool result discards it, while an interrupted
  turn makes it visible on the next turn. `:completion` is deliverable as soon
  as it arrives. Backends own capacity, projection, and wake-up policy.
  """

  alias Tackle.Runtime.AgentRef

  @enforce_keys [:kind, :from, :message]
  defstruct [:kind, :from, :message, :origin]

  @type kind :: :message | :launch | :completion
  @type origin :: %{turn_id: String.t(), tool_call_id: String.t()}
  @type t :: %__MODULE__{
          kind: kind(),
          from: AgentRef.t(),
          message: String.t(),
          origin: origin() | nil
        }

  @doc "Creates a validated envelope. Launches require turn/tool-call correlation."
  @spec new(kind(), AgentRef.t(), String.t(), origin() | nil) :: {:ok, t()} | {:error, term()}
  def new(kind, from, message, origin \\ nil)

  def new(
        :launch,
        %AgentRef{} = from,
        message,
        %{turn_id: turn_id, tool_call_id: call_id} = origin
      )
      when is_binary(message) and message != "" and is_binary(turn_id) and turn_id != "" and
             is_binary(call_id) and call_id != "" do
    {:ok, %__MODULE__{kind: :launch, from: from, message: message, origin: origin}}
  end

  def new(kind, %AgentRef{} = from, message, nil)
      when kind in [:message, :completion] and is_binary(message) and message != "" do
    {:ok, %__MODULE__{kind: kind, from: from, message: message}}
  end

  def new(kind, from, message, origin),
    do: {:error, {:invalid_envelope, kind, from, message, origin}}
end
