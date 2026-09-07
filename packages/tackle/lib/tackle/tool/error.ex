defmodule Tackle.Tool.Error do
  @moduledoc """
  Settled failed tool execution.

  This keeps dispatch/validation/runtime failures structured while still
  exposing a model-facing `content` string for the transcript.
  """

  @type reason ::
          :unknown_tool
          | :stale_tool_definition
          | :invalid_input
          | :invalid_output
          | :execution_error

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          name: String.t() | nil,
          reason: reason(),
          message: String.t(),
          content: String.t(),
          details: term(),
          metadata: map()
        }

  defstruct [:tool_call_id, :name, :reason, :message, :content, :details, metadata: %{}]
end
