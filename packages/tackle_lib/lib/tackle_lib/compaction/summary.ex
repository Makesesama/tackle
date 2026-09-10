defmodule Tackle.Lib.Compaction.Summary do
  @moduledoc """
  Result of one successful summarization call.

  A summary is only text plus bounded metadata and usage. The core owns cut
  selection, validation, durable commit, and model-surface replacement; a
  summarizer cannot bypass those invariants.
  """

  alias Tackle.Lib.Usage

  @type t :: %__MODULE__{
          content: String.t(),
          usage: Usage.t() | nil,
          model: String.t() | nil
        }

  @enforce_keys [:content]
  defstruct [:content, :usage, :model]
end
