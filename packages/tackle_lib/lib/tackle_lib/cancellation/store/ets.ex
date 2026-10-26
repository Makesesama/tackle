defmodule Tackle.Lib.Cancellation.Store.Ets do
  @moduledoc """
  Default ETS-backed cancellation store.

  A supervised process in the `:tackle_lib` application owns the named public ETS
  table. Callers access ETS directly, and their exits do not discard cancellation
  records. The application must be started before using this store; operations
  raise `ArgumentError` if the table is unavailable rather than recreating it in
  a caller. Records are not preserved across owner or application restarts.

  Only cancelled signals have records: `cancel/2` inserts one unless the id
  already has a reason, and `delete/1` removes an id together with the records
  of the per-call ids derived from it. Every host on the node, the Tackle
  runtime included, shares this table.

  Hosts that prefer a different storage mechanism can implement
  `Tackle.Lib.Cancellation.Store` and set `:cancellation_store` in config.
  """

  use GenServer

  @behaviour Tackle.Lib.Cancellation.Store

  @table __MODULE__

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, table}
  end

  @impl true
  def cancel(signal_id, reason) do
    :ets.insert_new(@table, {signal_id, reason})
    :ok
  end

  @impl true
  def reason(signal_id) do
    case :ets.lookup(@table, signal_id) do
      [{^signal_id, reason}] -> reason
      [] -> nil
    end
  end

  @impl true
  def delete(signal_id) do
    true = :ets.delete(@table, signal_id)
    signal_id |> derived_ids() |> Enum.each(&delete/1)
  end

  # Keys `{signal_id, _}`. `:const` keeps the id from being read as a pattern.
  defp derived_ids(signal_id) do
    :ets.select(@table, [
      {{{:"$1", :_}, :_}, [{:"=:=", :"$1", {:const, signal_id}}], [{:element, 1, :"$_"}]}
    ])
  end
end
