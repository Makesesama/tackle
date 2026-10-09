defmodule Tackle.Lib.ProviderGate do
  @moduledoc false

  @spec await(nil | (-> :ok | {:error, term()})) :: :ok | {:error, term()}
  def await(nil), do: :ok

  def await(callback) when is_function(callback, 0) do
    case callback.() do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_before_provider_call_result, other}}
    end
  rescue
    error -> {:error, {:before_provider_call_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:before_provider_call_failed, {kind, reason}}}
  end
end
