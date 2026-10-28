defmodule Tackle.AgentServiceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Tackle.AgentService
  alias Tackle.AgentService.Call

  describe "Call" do
    setup do
      %{supervisor: start_supervised!(Task.Supervisor)}
    end

    test "settles on the task's reply", %{supervisor: supervisor} do
      {:ok, call} = Call.start(supervisor, fn -> :answer end, 1_000, :meta)
      assert call.meta == :meta

      assert {:ok, :answer} = receive_settled(call)
      refute_received {:DOWN, _ref, :process, _pid, _reason}
    end

    test "turns a crash into an error", %{supervisor: supervisor} do
      capture_log(fn ->
        {:ok, call} = Call.start(supervisor, fn -> exit(:boom) end, 1_000, nil)
        assert {:ok, {:error, {:crashed, :boom}}} = receive_settled(call)
      end)
    end

    test "kills a task that outlives its timeout and grace", %{supervisor: supervisor} do
      {:ok, call} = Call.start(supervisor, fn -> Process.sleep(:infinity) end, 20, nil)
      started = System.monotonic_time(:millisecond)

      assert {:ok, {:error, :timeout}} = receive_settled(call)
      assert System.monotonic_time(:millisecond) - started >= 40
      refute Process.alive?(call.task.pid)
    end

    test "ignores other messages and no call" do
      assert Call.match(nil, {make_ref(), :answer}) == :error
    end

    test "reports an unavailable supervisor" do
      supervisor = spawn(fn -> :ok end)
      Process.sleep(10)

      assert {:error, {:task_supervisor_unavailable, _reason}} =
               Call.start(supervisor, fn -> :answer end, 1_000, nil)
    end
  end

  test "request_timeout!/2 takes a positive integer or the default" do
    assert AgentService.request_timeout!([], 30_000) == 30_000
    assert AgentService.request_timeout!([request_timeout: 50], 30_000) == 50

    for timeout <- [0, 1.5, :soon, nil] do
      assert_raise ArgumentError, fn ->
        AgentService.request_timeout!([request_timeout: timeout], 30_000)
      end
    end
  end

  describe "schedule/3" do
    test "keeps a timer with an unchanged due time and replaces others" do
      at = AgentService.now() + 60_000
      timer = AgentService.schedule(nil, at, :tick)
      assert AgentService.schedule(timer, at, :tick) == timer

      {ref, _at} = timer
      sooner = AgentService.schedule(timer, AgentService.now(), :tick)
      assert Process.read_timer(ref) == false
      assert_receive :tick

      assert AgentService.schedule(sooner, :infinity, :tick) == nil
    end
  end

  defp receive_settled(call) do
    receive do
      message ->
        case Call.match(call, message) do
          :error -> receive_settled(call)
          settled -> settled
        end
    after
      2_000 -> flunk("the call did not settle")
    end
  end
end
