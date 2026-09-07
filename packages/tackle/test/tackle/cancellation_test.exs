defmodule Tackle.CancellationTest do
  use ExUnit.Case, async: false

  alias Tackle.Cancellation

  defmodule AgentStore do
    @behaviour Tackle.Cancellation.Store

    @name __MODULE__.Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{} end, name: @name)
    end

    @impl true
    def cancel(signal_id, reason) do
      Agent.update(@name, &Map.put(&1, signal_id, reason))
    end

    @impl true
    def reason(signal_id) do
      Agent.get(@name, &Map.get(&1, signal_id))
    end

    @impl true
    def delete(signal_id) do
      Agent.update(@name, &Map.delete(&1, signal_id))
    end
  end

  defmodule FailingStore do
    @behaviour Tackle.Cancellation.Store

    @impl true
    def cancel(_signal_id, _reason), do: flunk("old signals must keep their original store")

    @impl true
    def reason(_signal_id), do: flunk("old signals must keep their original store")

    @impl true
    def delete(_signal_id), do: flunk("old signals must keep their original store")
  end

  setup do
    previous_store = Application.get_env(:tackle, :cancellation_store)
    start_supervised!(%{id: AgentStore, start: {AgentStore, :start_link, [[]]}})

    on_exit(fn ->
      if previous_store do
        Application.put_env(:tackle, :cancellation_store, previous_store)
      else
        Application.delete_env(:tackle, :cancellation_store)
      end
    end)
  end

  test "uses configured cancellation store" do
    Application.put_env(:tackle, :cancellation_store, AgentStore)

    signal = Cancellation.new_signal()

    refute Cancellation.cancelled?(signal)
    assert Cancellation.cancel(signal, "stop") == :ok
    assert Cancellation.cancelled?(signal)
    assert Cancellation.reason(signal) == "stop"
    assert Cancellation.delete(signal) == :ok
    refute Cancellation.cancelled?(signal)
  end

  test "signals retain the store configured when they were created" do
    Application.put_env(:tackle, :cancellation_store, AgentStore)

    signal = Cancellation.new_signal()

    Application.put_env(:tackle, :cancellation_store, FailingStore)

    assert Cancellation.cancel(signal, :cancelled) == :ok
    assert Cancellation.reason(signal) == :cancelled
  end
end
