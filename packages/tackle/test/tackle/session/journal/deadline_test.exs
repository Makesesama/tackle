defmodule Tackle.Session.Journal.DeadlineTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Tackle.Test.Runtime

  alias Tackle.Runtime.ID
  alias Tackle.Session.Journal.Deadline

  defmodule ControlledOwner do
    use GenServer

    def init(test_pid), do: {:ok, test_pid}

    def handle_call(:commit, _from, test_pid) do
      commit_id = make_ref()
      Deadline.stage(self(), :append, 7)
      send(test_pid, {:appended, commit_id, 7})
      Deadline.stage(self(), :sync, 7)

      receive do
        :sync_done -> :ok
      end

      Deadline.stage(self(), :projection, 7)
      send(test_pid, {:projection_entered, self()})

      receive do
        :projection_done -> :ok
      end

      {:reply, {:ok, commit_id, 7}, test_pid}
    end

    # Enters each stage in turn and stays in it until the test releases it.
    def handle_call({:stages, stages}, _from, test_pid) do
      for stage <- stages do
        Deadline.stage(self(), stage, 7)
        send(test_pid, {:entered, stage})
        receive do: ({:release, ^stage} -> :ok)
      end

      {:reply, :ok, test_pid}
    end
  end

  setup do
    {:ok, owner} = GenServer.start(ControlledOwner, self())
    session_id = ID.generate()
    {:ok, deadline} = Deadline.start(owner, session_id, home: tmp_home(), journal_timeout: 100)
    Deadline.ready(owner)
    assert :ready = Deadline.subscribe(owner, self())

    on_exit(fn ->
      if Process.alive?(owner), do: Process.exit(owner, :kill)
    end)

    {:ok, owner: owner, deadline: deadline, session_id: session_id}
  end

  test "the pending commit identity survives sync delay without another append", ctx do
    request = Task.async(fn -> Deadline.request(ctx.owner, :commit) end)
    assert_receive {:appended, commit_id, 7}
    session_id = ctx.session_id
    assert_receive {:tackle_storage, ^session_id, :delayed}, 1_000
    [pending_id] = Map.keys(:sys.get_state(ctx.deadline).pending)
    Process.sleep(250)
    assert %{seq: 7, stage: :sync, delayed?: true} = :sys.get_state(ctx.deadline)
    assert Map.keys(:sys.get_state(ctx.deadline).pending) == [pending_id]
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
    request = Task.async(fn -> Deadline.request(ctx.owner, :commit) end)
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

  for stage <- [:append_header, :append] do
    test "a stall in #{stage} pauses storage like a sync and resumes", ctx do
      stage = unquote(stage)
      session_id = ctx.session_id
      owner = ctx.owner

      log =
        capture_log(fn ->
          request = Task.async(fn -> Deadline.request(owner, {:stages, [stage]}) end)
          assert_receive {:entered, ^stage}
          assert_receive {:tackle_storage, ^session_id, :delayed}, 1_000
          Process.sleep(250)
          assert Process.alive?(owner)
          assert Task.yield(request, 20) == nil

          send(owner, {:release, stage})
          assert Task.await(request) == :ok
          assert_receive {:tackle_storage, ^session_id, :ready}
        end)

      assert log =~ "Session journal storage is slow; pausing"
      assert log =~ ~s("stage":"#{stage}")
      assert log =~ ~s("operation":"stages")
    end
  end

  test "an append that resumes into a slow sync stays paused", ctx do
    request = Task.async(fn -> Deadline.request(ctx.owner, {:stages, [:append, :sync]}) end)
    session_id = ctx.session_id
    assert_receive {:tackle_storage, ^session_id, :delayed}, 1_000
    send(ctx.owner, {:release, :append})
    assert_receive {:entered, :sync}
    Process.sleep(250)
    assert Process.alive?(ctx.owner)
    # The paused request has no deadline left, so the sync cannot kill it.
    assert %{stage: :sync, delayed?: true, pending: pending} = :sys.get_state(ctx.deadline)
    assert [%{timer: nil}] = Map.values(pending)

    send(ctx.owner, {:release, :sync})
    assert Task.await(request) == :ok
    assert_receive {:tackle_storage, ^session_id, :ready}
  end

  test "a resumed append does not exempt later work from its hard deadline", ctx do
    request = Task.async(fn -> Deadline.request(ctx.owner, {:stages, [:append, :catalog]}) end)
    session_id = ctx.session_id
    assert_receive {:tackle_storage, ^session_id, :delayed}, 1_000
    send(ctx.owner, {:release, :append})
    assert_receive {:entered, :catalog}

    assert {:error, {:journal_stalled, diagnostic}} = Task.await(request)
    assert diagnostic["stage"] == "catalog"
    refute_receive {:tackle_storage, ^session_id, :ready}, 20
  end

  test "a stall outside the storage waits still stops the owner", ctx do
    ref = Process.monitor(ctx.owner)
    request = Task.async(fn -> Deadline.request(ctx.owner, {:stages, [:projection]}) end)

    assert {:error, {:journal_stalled, diagnostic}} = Task.await(request)
    assert diagnostic["stage"] == "projection"
    assert_receive {:DOWN, ^ref, :process, _owner, :killed}
    refute_received {:tackle_storage, _session_id, :delayed}
  end
end
