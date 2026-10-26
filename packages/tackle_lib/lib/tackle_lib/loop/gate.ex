defmodule Tackle.Lib.Loop.Gate do
  @moduledoc false

  # The loop's host gates: zero-arity callbacks returning `:ok` or
  # `{:error, reason}`. `before_provider_call/1` runs before every provider
  # dispatch (and compaction summary), `before_tool_execution/1` before tools
  # with external effects run. The library has no storage knowledge; a gate is
  # host policy. A missing gate passes; a gate that returns anything else,
  # raises, throws, or exits refuses with a reason naming the gate.

  @type callback :: nil | (-> :ok | {:error, term()})

  @doc "Runs the `:before_provider_call` gate."
  @spec before_provider_call(callback()) :: :ok | {:error, term()}
  def before_provider_call(callback),
    do: run(callback, :invalid_before_provider_call_result, :before_provider_call_failed)

  @doc "Runs the `:before_tool_execution` gate."
  @spec before_tool_execution(callback()) :: :ok | {:error, term()}
  def before_tool_execution(callback),
    do: run(callback, :invalid_before_tool_execution_result, :before_tool_execution_failed)

  defp run(nil, _invalid, _failed), do: :ok

  defp run(callback, invalid, failed) when is_function(callback, 0) do
    case callback.() do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {invalid, other}}
    end
  rescue
    error -> {:error, {failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {failed, {kind, reason}}}
  end
end
