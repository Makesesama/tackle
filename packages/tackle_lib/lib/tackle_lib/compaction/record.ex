defmodule Tackle.Lib.Compaction.Record do
  @moduledoc """
  Durable intent of one committed compaction.

  The record is the provider-neutral description of a replacement: which
  synthetic checkpoint now leads the model context (`:summary_message`, see
  `Tackle.Lib.Compaction.Checkpoint`), which message ids it shadows, how the
  context shrank, and the auxiliary summarization usage. A
  `Tackle.Lib.Committer` lowers it into the host's durable schema, and
  `Tackle.Lib.Compaction.Checkpoint.apply_compaction/2` applies it to a
  message list.

  `:shadowed_message_ids` is the replaced prefix of the model context in
  order, starting with an earlier checkpoint when there is one.
  `:first_retained_message_id` is the first message kept after it, or `nil`
  when the compaction shadowed everything.

  `:parent_id` is the tree entry the compaction is attached to
  (`Tackle.Lib.Tree.append_compaction/3` sets it).

  `:details` holds auxiliary facts with atom keys; the library records the
  tightening pass that committed the record as `:pass`.

  Summary usage is stored here as auxiliary accounting. It is never attached to
  the synthetic checkpoint as if it were an assistant conversation checkpoint.
  """

  alias Tackle.Lib.Message
  alias Tackle.Lib.Usage

  @typedoc """
  What started a compaction: context pressure before a request, a provider
  context overflow, or an operator's manual request.
  """
  @type trigger :: :pressure | :overflow | :manual

  @type t :: %__MODULE__{
          compaction_id: String.t(),
          trigger: trigger(),
          summary_message: Message.t(),
          shadowed_message_ids: [String.t()],
          first_retained_message_id: String.t() | nil,
          previous_compaction_id: String.t() | nil,
          parent_id: String.t() | nil,
          tokens_before: non_neg_integer(),
          estimated_tokens_after: non_neg_integer(),
          summary_usage: Usage.t() | nil,
          summary_model: String.t() | nil,
          created_at: DateTime.t(),
          details: %{optional(atom()) => term()}
        }

  @enforce_keys [
    :compaction_id,
    :trigger,
    :summary_message,
    :shadowed_message_ids,
    :tokens_before,
    :estimated_tokens_after,
    :created_at
  ]
  defstruct [
    :compaction_id,
    :trigger,
    :summary_message,
    :shadowed_message_ids,
    :first_retained_message_id,
    :previous_compaction_id,
    :parent_id,
    :tokens_before,
    :estimated_tokens_after,
    :summary_usage,
    :summary_model,
    :created_at,
    details: %{}
  ]

  @doc "Returns every trigger a record can have."
  @spec triggers() :: [trigger()]
  def triggers, do: [:pressure, :overflow, :manual]
end
