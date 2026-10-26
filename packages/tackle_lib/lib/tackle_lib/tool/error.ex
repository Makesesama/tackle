defmodule Tackle.Lib.Tool.Error do
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

  @doc """
  Builds the settlement of a call to a tool the registry does not know.
  """
  @spec unknown_tool(Tackle.Lib.Tool.Call.t()) :: t()
  def unknown_tool(%Tackle.Lib.Tool.Call{} = call) do
    unresolved(call, :unknown_tool, "Unknown tool: #{call.name}")
  end

  @doc """
  Builds the settlement of a call made against an outdated definition of a
  tool: its `definition_id` no longer matches the registry's. The model is
  asked to fetch the current tool list and retry.
  """
  @spec stale_definition(Tackle.Lib.Tool.Call.t()) :: t()
  def stale_definition(%Tackle.Lib.Tool.Call{} = call) do
    unresolved(
      call,
      :stale_tool_definition,
      "Stale tool definition for #{call.name}; ask for the current tool list and retry"
    )
  end

  defp unresolved(call, reason, message) do
    %__MODULE__{
      tool_call_id: call.id,
      name: call.name,
      reason: reason,
      message: message,
      content: "Error: " <> message,
      metadata: %{definition_id: call.definition_id}
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
      details: {kind, reason},
      metadata: %{definition_id: call.definition_id}
    }
  end

  defp describe_crash(:error, reason),
    do: :error |> Exception.normalize(reason) |> Exception.message()

  defp describe_crash(kind, reason), do: "#{kind} #{inspect(reason)}"
end
