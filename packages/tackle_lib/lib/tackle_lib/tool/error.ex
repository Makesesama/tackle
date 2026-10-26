defmodule Tackle.Lib.Tool.Error do
  @moduledoc """
  Settled failed tool execution.

  This keeps dispatch/validation/runtime failures structured while still
  exposing a model-facing `content` string for the transcript.

  `message` and `details` are for the host. `content` is what the model sees:
  `"Error: "` followed by a message written for the model, or a generic
  `"Error: The tool failed while completing the request."` when the failure
  must not be shown to it (see "Errors the model sees" in `Tackle.Lib.Tool`). The constructors below are the one
  place errors are built; their text is made valid UTF-8, since the transcript
  is sent to providers as JSON.
  """

  alias Tackle.Lib.Tool.Call

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

  @generic_content "Error: The tool failed while completing the request."

  @doc """
  Builds the settlement of a call to a tool the registry does not know.
  """
  @spec unknown_tool(Call.t()) :: t()
  def unknown_tool(%Call{} = call) do
    message = "Unknown tool: #{call.name}"
    new(call.id, call.name, :unknown_tool, message, nil, message)
  end

  @doc """
  Builds the settlement of a call whose arguments were rejected before the
  tool ran. `message` names only schema fields and their constraints, so the
  model sees it.
  """
  @spec invalid_input(Call.t(), String.t()) :: t()
  def invalid_input(%Call{} = call, message) when is_binary(message),
    do: new(call.id, call.name, :invalid_input, message, nil, message)

  @doc """
  Builds the settlement of a call whose result failed output validation or
  could not be projected into the transcript. That is a bug in the tool, so
  the model sees the generic content. A `reason` that is not a binary (a host
  output validator may return any term) is kept in `details`.
  """
  @spec invalid_output(Call.t(), term()) :: t()
  def invalid_output(%Call{} = call, reason) when is_binary(reason),
    do: new(call.id, call.name, :invalid_output, reason, nil, nil)

  def invalid_output(%Call{} = call, reason) do
    message = "Invalid tool output: #{inspect(reason)}"
    new(call.id, call.name, :invalid_output, message, reason, nil)
  end

  @doc """
  Builds the settlement of a call whose tool returned `{:error, reason}`.

  A non-empty binary `reason` is the model-facing message; any other reason
  gets the generic content and stays in `message` and `details` for the host.
  """
  @spec failed(Call.t(), term()) :: t()
  def failed(%Call{} = call, reason) when is_binary(reason) and reason != "",
    do: new(call.id, call.name, :execution_error, reason, reason, reason)

  def failed(%Call{} = call, reason) do
    message = "Tool execution failed: #{inspect(reason)}"
    new(call.id, call.name, :execution_error, message, reason, nil)
  end

  @doc """
  Builds the settlement of a tool call that crashed: its execution raised,
  threw, or exited instead of returning a result.

  `kind` and `reason` are what `catch kind, reason` received, or `:exit` and
  the exit reason of a task that died. The model sees a generic error; the
  crash stays in `message` and `details` for the host.
  """
  @spec crashed(Call.t(), :error | :exit | :throw, term()) :: t()
  def crashed(%Call{} = call, kind, reason) when kind in [:error, :exit, :throw] do
    message = "Tool crashed: " <> describe_crash(kind, reason)
    new(call.id, call.name, :execution_error, message, {kind, reason}, nil)
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
    new(tool_call_id, name, :interrupted, message, nil, message)
  end

  # `model_message` is what the model may see; without one the model sees the
  # generic content.
  defp new(tool_call_id, name, reason, message, details, model_message) do
    %__MODULE__{
      tool_call_id: tool_call_id,
      name: name,
      reason: reason,
      message: String.replace_invalid(message),
      content: content(model_message),
      details: details
    }
  end

  defp content(nil), do: @generic_content
  defp content(message), do: "Error: " <> String.replace_invalid(message)

  defp interrupted_message(:unknown),
    do: "Tool execution was interrupted before a result was recorded; the outcome is unknown."

  defp interrupted_message(outcome) when outcome in [:interrupted, :aborted, :cancelled],
    do: "Tool execution was #{outcome} before this call completed."

  defp describe_crash(:error, reason),
    do: :error |> Exception.normalize(reason) |> Exception.message()

  defp describe_crash(kind, reason), do: "#{kind} #{inspect(reason)}"
end
