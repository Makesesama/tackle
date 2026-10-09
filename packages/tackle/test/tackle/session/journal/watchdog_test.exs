defmodule Tackle.Session.Journal.WatchdogTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Runtime.ID
  alias Tackle.Session.Journal.Watchdog

  defmodule ControlledOwner do
    use GenServer

    def init(test_pid), do: {:ok, test_pid}

    def handle_call(:commit, _from, test_pid) do
      commit_id = make_ref()
      Watchdog.stage(self(), :append, 7)
      send(test_pid, {:appended, commit_id, 7})
      Watchdog.stage(self(), :sync, 7)

      receive do
        :sync_done -> :ok
      end

      Watchdog.stage(self(), :projection, 7)
      send(test_pid, {:projection_entered, self()})

      receive do
        :projection_done -> :ok
      end

      {:reply, {:ok, commit_id, 7}, test_pid}
    end
  end

  setup do
    {:ok, owner} = GenServer.start(ControlledOwner, self())
    session_id = ID.generate()
    {:ok, watchdog} = Watchdog.start(owner, session_id, home: tmp_home(), journal_timeout: 100)
    Watchdog.ready(owner)
    assert :ready = Watchdog.subscribe(owner, self())

    on_exit(fn ->
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    {:ok, owner: owner, watchdog: watchdog, session_id: session_id}
  end

  test "the pending commit identity survives sync delay without another append", ctx do
    request = Task.async(fn -> Watchdog.request(ctx.owner, :commit) end)
    assert_receive {:appended, commit_id, 7}
    session_id = ctx.session_id
    assert_receive {:tackle_storage, ^session_id, :delayed}, 1_000
    [pending_id] = Map.keys(:sys.get_state(ctx.watchdog).pending)
    Process.sleep(250)
    assert %{seq: 7, stage: :sync, delayed?: true} = :sys.get_state(ctx.watchdog)
    assert Map.keys(:sys.get_state(ctx.watchdog).pending) == [pending_id]
    refute_receive {:appended, _, _}, 20
    assert Task.yield(request, 20) == nil
    send(ctx.owner, :sync_done)
    assert_receive {:projection_entered, _}
    send(ctx.owner, :projection_done)
    assert Task.await(request) == {:ok, commit_id, 7}
    assert_receive {:tackle_storage, ^session_id, :ready}
    refute_receive {:appended, _, _}, 20
    GenServer.stop(ctx.owner)
  end

  test "a resumed sync does not exempt a later projection stall from its hard deadline", ctx do
    request = Task.async(fn -> Watchdog.request(ctx.owner, :commit) end)
    assert_receive {:appended, _, 7}
    session_id = ctx.session_id
    assert_receive {:tackle_storage, ^session_id, :delayed}, 1_000
    send(ctx.owner, :sync_done)
    assert_receive {:projection_entered, _}
    assert {:error, {:journal_stalled, diagnostic}} = Task.await(request)
    assert diagnostic["stage"] == "projection"
    assert diagnostic["sequence"] == 7
    refute_receive {:tackle_storage, ^session_id, :ready}, 20
  end
end
