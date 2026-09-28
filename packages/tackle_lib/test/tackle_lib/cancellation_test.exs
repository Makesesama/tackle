defmodule Tackle.Lib.CancellationTest do
  use ExUnit.Case, async: false

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Cancellation.Store.Ets

  defmodule AgentStore do
    @behaviour Tackle.Lib.Cancellation.Store

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
    @behaviour Tackle.Lib.Cancellation.Store

    @impl true
    def cancel(_signal_id, _reason), do: flunk("old signals must keep their original store")

    @impl true
    def reason(_signal_id), do: flunk("old signals must keep their original store")

    @impl true
    def delete(_signal_id), do: flunk("old signals must keep their original store")
  end

  setup do
    previous_store = Application.get_env(:tackle_lib, :cancellation_store)
    start_supervised!(%{id: AgentStore, start: {AgentStore, :start_link, [[]]}})

    on_exit(fn ->
      if previous_store do
        Application.put_env(:tackle_lib, :cancellation_store, previous_store)
      else
        Application.delete_env(:tackle_lib, :cancellation_store)
      end
    end)
  end

  test "default store preserves cancellation records after callers exit" do
    Application.delete_env(:tackle_lib, :cancellation_store)

    signal = Cancellation.new_signal()
    other_signal = Cancellation.new_signal()
    assert signal.store == Ets

    on_exit(fn ->
      Cancellation.delete(signal)
      Cancellation.delete(other_signal)
    end)

    owner = Process.whereis(Ets)
    assert is_pid(owner)
    assert :ets.info(Ets, :owner) == owner
    assert {Ets, owner, :worker, [Ets]} in Supervisor.which_children(Tackle.Lib.Supervisor)

    task =
      Task.async(fn ->
        receive do
          :cancel ->
            refute Cancellation.cancelled?(signal)
            Cancellation.cancel(signal)
        end
      end)

    monitor = Process.monitor(task.pid)
    send(task.pid, :cancel)
    assert Task.await(task) == :ok
    assert_receive {:DOWN, ^monitor, :process, _, :normal}

    assert Cancellation.reason(signal) == :cancelled
    assert Cancellation.cancelled?(signal)

    assert Task.async(fn -> Cancellation.cancel(other_signal, :user_cancelled) end)
           |> Task.await() == :ok

    assert Cancellation.reason(signal) == :cancelled
    assert Cancellation.reason(other_signal) == :user_cancelled
    assert :ets.info(Ets, :owner) == owner

    assert Cancellation.delete(signal) == :ok
    refute Cancellation.cancelled?(signal)
    assert Cancellation.reason(other_signal) == :user_cancelled
  end

  test "default store does not recreate its table when its owner is unavailable" do
    assert :ok = Supervisor.terminate_child(Tackle.Lib.Supervisor, Ets)

    on_exit(fn ->
      {:ok, _pid} = Supervisor.restart_child(Tackle.Lib.Supervisor, Ets)
    end)

    assert :ets.whereis(Ets) == :undefined
    signal_id = make_ref()

    assert_raise ArgumentError, fn -> Ets.cancel(signal_id, :cancelled) end
    assert_raise ArgumentError, fn -> Ets.reason(signal_id) end
    assert_raise ArgumentError, fn -> Ets.delete(signal_id) end
    assert :ets.whereis(Ets) == :undefined
  end

  test "uses configured cancellation store" do
    Application.put_env(:tackle_lib, :cancellation_store, AgentStore)

    signal = Cancellation.new_signal()

    refute Cancellation.cancelled?(signal)
    assert Cancellation.cancel(signal, "stop") == :ok
    assert Cancellation.cancelled?(signal)
    assert Cancellation.reason(signal) == "stop"
    assert Cancellation.delete(signal) == :ok
    refute Cancellation.cancelled?(signal)
  end

  test "signals retain the store configured when they were created" do
    Application.put_env(:tackle_lib, :cancellation_store, AgentStore)

    signal = Cancellation.new_signal()

    Application.put_env(:tackle_lib, :cancellation_store, FailingStore)

    assert Cancellation.cancel(signal, :cancelled) == :ok
    assert Cancellation.reason(signal) == :cancelled
  end
end
