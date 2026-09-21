defmodule Tackle.Runtime.CancellationStore do
  @moduledoc """
  Long-lived cancellation store owned by the Tackle harness.

  `Tackle.Lib`'s default ETS store creates its table lazily in whichever process
  first needs it, so the table disappears when that process exits. The harness
  owns this table for the lifetime of the application instead, keeping
  cancellation state visible across sessions, turn tasks, adapters, and tools.

  It implements `Tackle.Lib.Cancellation.Store` and is selected through
  `config :tackle_lib, cancellation_store: Tackle.Runtime.CancellationStore`.
  """

  @behaviour Tackle.Lib.Cancellation.Store

  use GenServer

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
    true = :ets.insert(@table, {signal_id, reason})
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
    :ok
  end
end
