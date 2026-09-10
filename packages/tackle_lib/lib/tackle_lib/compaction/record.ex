defmodule Tackle.Lib.Compaction.Record do
  @moduledoc """
  Durable intent of one committed compaction.

  The record is the provider-neutral description of a replacement: which
  synthetic checkpoint now leads the model projection (`:summary_message`),
  which transcript message ids it shadows, how the projection shrank, and the
  auxiliary summarization usage. A `Tackle.Lib.Compaction.Committer` lowers it
  into the host's durable schema.

  Summary usage is stored here as auxiliary accounting. It is never attached to
  the synthetic checkpoint as if it were an assistant conversation checkpoint.
  """

  alias Tackle.Lib.Message
  alias Tackle.Lib.Usage

  @type trigger :: :pressure | :overflow | :manual

  @type t :: %__MODULE__{
          compaction_id: String.t(),
          trigger: trigger(),
          summary_message: Message.t(),
          shadowed_message_ids: [String.t()],
          first_retained_message_id: String.t() | nil,
          previous_compaction_id: String.t() | nil,
          tokens_before: non_neg_integer(),
          estimated_tokens_after: non_neg_integer(),
          summary_usage: Usage.t() | nil,
          summary_model: String.t() | nil,
          created_at: String.t(),
          details: map()
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
    :tokens_before,
    :estimated_tokens_after,
    :summary_usage,
    :summary_model,
    :created_at,
    details: %{}
  ]
end
