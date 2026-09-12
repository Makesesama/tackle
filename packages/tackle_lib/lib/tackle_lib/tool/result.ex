defmodule Tackle.Lib.Tool.Result do
  @moduledoc """
  Settled successful tool execution.

  `raw` is the host tool's original return value. `output` is the validated or
  normalized output value when an output schema is available. `content` is the
  model-facing string projection stored in the transcript. `parts` holds any
  extra provider-neutral content parts (see `Tackle.Lib.Tool.Content`) that
  adapters lower into their wire format; it is empty for text-only results.
  """

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          name: String.t(),
          raw: term(),
          output: term(),
          content: String.t(),
          parts: [Tackle.Lib.Tool.Content.part()],
          metadata: map()
        }

  defstruct [:tool_call_id, :name, :raw, :output, :content, parts: [], metadata: %{}]
end
