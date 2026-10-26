defmodule Tackle.Lib.Compaction.Summary do
  @moduledoc """
  Result of one successful summarization call.

  A summary is only text plus bounded metadata and usage. The core owns cut
  selection, validation, durable commit, and model-surface replacement; a
  summarizer cannot bypass those invariants.

  `:stop_reason` is the provider's reason for ending the summary
  (`t:Tackle.Lib.LLM.Response.stop_reason/0`), when the summarizer knows it.
  The core rejects a summary that stopped at `:max_tokens` or
  `:content_filter` as incomplete. Without one it falls back to the usage:
  a summary whose visible output (output tokens less reasoning tokens)
  reached the request's output cap counts as cut off.
  """

  alias Tackle.Lib.LLM.Response
  alias Tackle.Lib.Usage

  @type t :: %__MODULE__{
          content: String.t(),
          usage: Usage.t() | nil,
          model: String.t() | nil,
          stop_reason: Response.stop_reason()
        }

  @enforce_keys [:content]
  defstruct [:content, :usage, :model, :stop_reason]
end
