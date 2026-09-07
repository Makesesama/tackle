defmodule Tackle.Lib.Tool.Result do
  @moduledoc """
  Settled successful tool execution.

  `raw` is the host tool's original return value. `output` is the validated or
  normalized output value when an output schema is available. `content` is the
  model-facing string projection stored in the transcript.
  """

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          name: String.t(),
          raw: term(),
          output: term(),
          content: String.t(),
          metadata: map()
        }

  defstruct [:tool_call_id, :name, :raw, :output, :content, metadata: %{}]
end
