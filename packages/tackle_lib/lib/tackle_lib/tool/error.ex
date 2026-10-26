defmodule Tackle.Lib.Tool.Error do
  @moduledoc """
  Settled failed tool execution.

  This keeps dispatch/validation/runtime failures structured while still
  exposing a model-facing `content` string for the transcript.
  """

  @type reason ::
          :unknown_tool
          | :invalid_input
          | :invalid_output
          | :execution_error
          | :interrupted

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

  @doc """
  Builds the settlement of a call to a tool the registry does not know.
  """
  @spec unknown_tool(Tackle.Lib.Tool.Call.t()) :: t()
  def unknown_tool(%Tackle.Lib.Tool.Call{} = call) do
    message = "Unknown tool: #{call.name}"

    %__MODULE__{
      tool_call_id: call.id,
      name: call.name,
      reason: :unknown_tool,
      message: message,
      content: "Error: " <> message
    }
  end

  @doc """
  Builds the settlement of a tool call that crashed: its execution raised,
  threw, or exited instead of returning a result.

  `kind` and `reason` are what `catch kind, reason` received, or `:exit` and
  the exit reason of a task that died. The model sees a generic error; the
  crash stays in `message` and `details` for the host.
  """
  @spec crashed(Tackle.Lib.Tool.Call.t(), :error | :exit | :throw, term()) :: t()
  def crashed(%Tackle.Lib.Tool.Call{} = call, kind, reason)
      when kind in [:error, :exit, :throw] do
    %__MODULE__{
      tool_call_id: call.id,
      name: call.name,
      reason: :execution_error,
      message: "Tool crashed: " <> describe_crash(kind, reason),
      content: "Error: The tool failed while completing the request.",
      details: {kind, reason}
    }
  end

  @typedoc """
  How a call left without a result ended: its turn was `:aborted` by an error
  or `:cancelled`, or the call was found `:interrupted` when the next turn
  started. `:unknown` is for a call found unresolved in stored history, whose
  tool may or may not have run.
  """
  @type interrupted_outcome :: :interrupted | :aborted | :cancelled | :unknown

  @doc """
  Builds the settlement recorded for a call that was left without a result,
  saying how it ended (see `t:interrupted_outcome/0`). The tool never
  reported a result, so there are no details.
  """
  @spec interrupted(String.t(), String.t() | nil, interrupted_outcome()) :: t()
  def interrupted(tool_call_id, name, outcome) do
    message = interrupted_message(outcome)

    %__MODULE__{
      tool_call_id: tool_call_id,
      name: name,
      reason: :interrupted,
      message: message,
      content: "Error: " <> message
    }
  end

  defp interrupted_message(:unknown),
    do: "Tool execution was interrupted before a result was recorded; the outcome is unknown."

  defp interrupted_message(outcome) when outcome in [:interrupted, :aborted, :cancelled],
    do: "Tool execution was #{outcome} before this call completed."

  defp describe_crash(:error, reason),
    do: :error |> Exception.normalize(reason) |> Exception.message()

  defp describe_crash(kind, reason), do: "#{kind} #{inspect(reason)}"
end
