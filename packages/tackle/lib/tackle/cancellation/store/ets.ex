defmodule Tackle.Cancellation.Store.Ets do
  @moduledoc """
  Default ETS-backed cancellation store.

  This module keeps Tackle's historical cancellation behaviour: a lazily-created
  named public ETS table shared by all processes in the VM. Hosts that prefer a
  different storage mechanism can implement `Tackle.Cancellation.Store` and set
  `:cancellation_store` in config.
  """

  @behaviour Tackle.Cancellation.Store

  @table __MODULE__

  @impl true
  def cancel(signal_id, reason) do
    ensure_table!()
    true = :ets.insert(@table, {signal_id, reason})
    :ok
  end

  @impl true
  def reason(signal_id) do
    ensure_table!()

    case :ets.lookup(@table, signal_id) do
      [{^signal_id, reason}] -> reason
      [] -> nil
    end
  end

  @impl true
  def delete(signal_id) do
    ensure_table!()
    :ets.delete(@table, signal_id)
    :ok
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      _table ->
        @table
    end
  end
end
