defmodule Tackle.Lib.ProviderGate do
  @moduledoc false

  # Runs one zero-arity host gate: `:before_provider_call` before every provider
  # dispatch, or `:before_tool_execution` before tools run. The library has no
  # storage knowledge; the gate is host policy.

  @type gate :: :before_provider_call | :before_tool_execution

  @spec await(nil | (-> :ok | {:error, term()})) :: :ok | {:error, term()}
  def await(callback), do: await(callback, :before_provider_call)

  @spec await(nil | (-> :ok | {:error, term()}), gate()) :: :ok | {:error, term()}
  def await(nil, _gate), do: :ok

  def await(callback, gate) when is_function(callback, 0) do
    case callback.() do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {invalid_result(gate), other}}
    end
  rescue
    error -> {:error, {failed(gate), Exception.message(error)}}
  catch
    kind, reason -> {:error, {failed(gate), {kind, reason}}}
  end

  defp invalid_result(:before_provider_call), do: :invalid_before_provider_call_result
  defp invalid_result(:before_tool_execution), do: :invalid_before_tool_execution_result

  defp failed(:before_provider_call), do: :before_provider_call_failed
  defp failed(:before_tool_execution), do: :before_tool_execution_failed
end
