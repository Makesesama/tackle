defmodule Tackle.Lib.Tree.Entry do
  @moduledoc """
  One immutable node in a conversation tree.

  An entry is either a settled message or a committed compaction. Message
  entries reuse the settled message id and compaction entries reuse the
  compaction id, so identity stays consistent with the rest of the harness
  instead of being minted twice.

  `:ordinal` is the chronological insertion order, `:parent_id` links to the
  entry this one was appended to (or `nil` for a root), and `:kind` selects
  which payload is populated.
  """

  alias Tackle.Lib.Compaction.Record
  alias Tackle.Lib.Message

  @type kind :: :message | :compaction

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t() | nil,
          kind: kind(),
          ordinal: pos_integer(),
          message: Message.t() | nil,
          compaction: Record.t() | nil
        }

  @enforce_keys [:id, :kind, :ordinal]
  defstruct [:id, :parent_id, :kind, :ordinal, :message, :compaction]

  @doc "Returns the settled message for a message entry."
  @spec message(t()) :: Message.t() | nil
  def message(%__MODULE__{kind: :message, message: message}), do: message
  def message(%__MODULE__{}), do: nil

  @doc "Returns the compaction record for a compaction entry."
  @spec compaction(t()) :: Record.t() | nil
  def compaction(%__MODULE__{kind: :compaction, compaction: record}), do: record
  def compaction(%__MODULE__{}), do: nil
end
