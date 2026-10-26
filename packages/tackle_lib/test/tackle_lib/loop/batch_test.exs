defmodule Tackle.Lib.Loop.BatchTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Cancellation
  alias Tackle.Lib.Event
  alias Tackle.Lib.Loop.Batch
  alias Tackle.Lib.Loop.Job
  alias Tackle.Lib.Loop.Run
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Error
  alias Tackle.Lib.Tool.Result

  test "collects out-of-order completions by call index and reports progress immediately" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    parent = self()
    jobs = jobs(["first", "second"])

    batch =
      Task.async(fn ->
        Batch.run(jobs, run(supervisor, parent), fn %Job{call: call} ->
          send(parent, {:entered, call.id, self()})
          receive do: ({:release, value} -> ok(call.id, value))
        end)
      end)

    assert_receive {:entered, "first", first}
    assert_receive {:entered, "second", second}
    send(second, {:release, :two})

    assert_receive {:event, %Event{type: :tool_execution_end, data: %{tool_call_id: "second"}}},
                   1_000

    refute_receive {:event, %Event{type: :tool_execution_end}}, 20
    send(first, {:release, :one})

    assert {%{0 => {:ok, %Result{output: :one}}, 1 => {:ok, %Result{output: :two}}}, :ok} =
             Task.await(batch)

    assert_receive {:event, %Event{type: :tool_execution_end, data: %{tool_call_id: "first"}}}
  end

  @tag :capture_log
  test "converts a task exit to a tool error without losing sibling results" do
    {:ok, supervisor} = Task.Supervisor.start_link()

    assert {%{0 => {:error, %Error{} = error}, 1 => {:ok, %Result{}}}, :ok} =
             Batch.run(jobs(["crash", "success"]), run(supervisor), fn
               %Job{call: %Call{id: "crash"}} -> exit(:broken)
               %Job{call: call} -> ok(call.id, :success)
             end)

    assert error.tool_call_id == "crash"
    assert error.reason == :execution_error
    assert error.details == {:exit, :broken}
    assert error.message == "Tool crashed: exit :broken"
    assert error.content == "Error: The tool failed while completing the request."
  end

  describe "cancellation" do
    setup do
      signal = Cancellation.new_signal()
      on_exit(fn -> Cancellation.delete(signal) end)
      {:ok, supervisor} = Task.Supervisor.start_link()
      %{signal: signal, supervisor: supervisor}
    end

    test "gives a cooperative tool time to clean up and keeps its result", ctx do
      parent = self()

      batch =
        Task.async(fn ->
          Batch.run(
            jobs(["slow_cleanup"], ctx.signal),
            run(ctx.supervisor, parent, ctx.signal),
            fn job ->
              send(parent, {:entered, job.call.id, self()})
              wait_for_cancellation(job.call_signal)
              send(parent, {:observed, Cancellation.reason(job.call_signal)})
              # Stopping its work takes longer than one poll, as stopping an OS
              # process group can, but less than the grace.
              Process.sleep(300)
              ok(job.call.id, :cleaned_up)
            end
          )
        end)

      assert_receive {:entered, "slow_cleanup", tool}
      monitor = Process.monitor(tool)
      Cancellation.cancel(ctx.signal, "stop")
      assert_receive {:observed, "stop"}

      assert {%{0 => {:ok, %Result{output: :cleaned_up}}}, :cancelled} =
               Task.await(batch, 5_000)

      assert_receive {:event,
                      %Event{
                        type: :tool_execution_end,
                        data: %{tool_call_id: "slow_cleanup", status: :completed}
                      }}

      assert_receive {:DOWN, ^monitor, :process, ^tool, :normal}
    end

    test "kills a tool that ignores cancellation after the grace and deletes its call signal",
         ctx do
      parent = self()
      [_done, stubborn_job] = jobs = jobs(["done", "stubborn"], ctx.signal)
      # A host cancelled this call on its own, which leaves a record behind.
      Cancellation.cancel(stubborn_job.call_signal, "just this call")

      batch =
        Task.async(fn ->
          Batch.run(jobs, run(ctx.supervisor, parent, ctx.signal), fn
            %Job{call: %Call{id: "done"}} = job ->
              send(parent, {:entered, job.call.id, self()})
              receive do: ({:release, value} -> ok(job.call.id, value))

            job ->
              send(parent, {:entered, job.call.id, self()})
              wait_for_cancellation(job.call_signal)
              send(parent, :observed)
              receive do: (:never -> ok(job.call.id, :never))
          end)
        end)

      assert_receive {:entered, "done", done}
      assert_receive {:entered, "stubborn", stubborn}
      monitor = Process.monitor(stubborn)
      assert_receive :observed
      send(done, {:release, :done})

      assert_receive {:event, %Event{type: :tool_execution_end, data: %{tool_call_id: "done"}}},
                     1_000

      Cancellation.cancel(ctx.signal, "stop")

      refute_receive {:DOWN, ^monitor, :process, ^stubborn, _reason}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^stubborn, :killed}, 2_000

      assert {%{0 => {:ok, %Result{output: :done}}} = settlements, :cancelled} =
               Task.await(batch, 5_000)

      refute Map.has_key?(settlements, 1)
      refute_received {:event, %Event{type: :tool_execution_end}}
      assert own_record(stubborn_job.call_signal) == nil
    end
  end

  describe "when the caller goes down" do
    setup do
      signal = Cancellation.new_signal()
      on_exit(fn -> Cancellation.delete(signal) end)
      {:ok, supervisor} = Task.Supervisor.start_link()
      %{signal: signal, supervisor: supervisor}
    end

    test "cancels every call, then stops the tools that do not stop", ctx do
      parent = self()
      jobs = jobs(["cooperative", "stubborn"], ctx.signal)

      caller =
        spawn(fn ->
          Batch.run(jobs, run(ctx.supervisor), fn
            %Job{call: %Call{id: "cooperative"}} = job ->
              send(parent, {:entered, job.call.id, self()})
              wait_for_cancellation(job.call_signal)
              send(parent, {:observed, Cancellation.reason(job.call_signal)})
              ok(job.call.id, :stopped)

            job ->
              send(parent, {:entered, job.call.id, self()})
              receive do: (:never -> ok(job.call.id, :never))
          end)
        end)

      assert_receive {:entered, "cooperative", cooperative}
      assert_receive {:entered, "stubborn", stubborn}
      cooperative_monitor = Process.monitor(cooperative)
      stubborn_monitor = Process.monitor(stubborn)

      Process.exit(caller, :kill)

      assert_receive {:observed, :caller_down}
      assert_receive {:DOWN, ^cooperative_monitor, :process, ^cooperative, :normal}
      refute_receive {:DOWN, ^stubborn_monitor, :process, ^stubborn, _reason}, 1_000
      assert_receive {:DOWN, ^stubborn_monitor, :process, ^stubborn, :killed}, 2_000

      assert Task.Supervisor.children(ctx.supervisor) == []
      assert eventually(fn -> Enum.all?(jobs, &(own_record(&1.call_signal) == nil)) end)
      # The turn signal belongs to the host and is left alone.
      refute Cancellation.cancelled?(ctx.signal)
    end
  end

  describe "a task that cannot be started" do
    @tag :capture_log
    test "settles with every later call as crashed while started calls run on" do
      {:ok, supervisor} = Task.Supervisor.start_link(max_children: 1)
      signal = Cancellation.new_signal()
      on_exit(fn -> Cancellation.delete(signal) end)
      parent = self()
      [_first, second, _third] = jobs = jobs(["first", "second", "third"], signal)
      Cancellation.cancel(second.call_signal, "cancelled before it started")

      batch =
        Task.async(fn ->
          Batch.run(jobs, run(supervisor, parent), fn job ->
            send(parent, {:entered, job.call.id, self()})
            receive do: ({:release, value} -> ok(job.call.id, value))
          end)
        end)

      assert_receive {:entered, "first", first}

      for id <- ["second", "third"] do
        assert_receive {:event,
                        %Event{
                          type: :tool_execution_end,
                          data: %{tool_call_id: ^id, status: :failed, reason: :execution_error}
                        }}
      end

      send(first, {:release, :one})

      assert {%{
                0 => {:ok, %Result{output: :one}},
                1 => {:error, %Error{tool_call_id: "second", details: {:error, %RuntimeError{}}}},
                2 => {:error, %Error{tool_call_id: "third"}}
              }, :ok} = Task.await(batch)

      refute_received {:entered, _id, _pid}
      assert own_record(second.call_signal) == nil
    end

    @tag :capture_log
    test "settles every call as crashed when the supervisor is gone" do
      {:ok, supervisor} = Task.Supervisor.start_link()
      Process.unlink(supervisor)
      Process.exit(supervisor, :kill)

      assert {%{
                0 => {:error, %Error{details: {:exit, _noproc}}},
                1 => {:error, %Error{details: {:exit, _}}}
              }, :ok} =
               Batch.run(jobs(["first", "second"]), run(supervisor), fn _job ->
                 flunk("unexpected task")
               end)
    end
  end

  test "empty batch needs no task and returns success" do
    assert {%{}, :ok} = Batch.run([], run(nil), fn _ -> flunk("unexpected task") end)
  end

  defp run(supervisor, parent \\ self(), signal \\ nil) do
    %Run{
      event_callback: &send(parent, {:event, &1}),
      tool_context: %{},
      snapshot: nil,
      tool_supervisor: supervisor,
      cancellation_signal: signal
    }
  end

  defp jobs(ids, signal \\ nil) do
    Enum.map(ids, fn id ->
      %Job{
        call: %Call{id: id, name: "test", definition_id: "definition"},
        call_signal: Cancellation.for_call(signal, id)
      }
    end)
  end

  defp ok(id, output),
    do: {:ok, %Result{tool_call_id: id, name: "test", output: output, content: inspect(output)}}

  # Tools such as `bash` watch their call's signal while they wait.
  defp wait_for_cancellation(signal) do
    unless Cancellation.cancelled?(signal) do
      receive do
      after
        5 -> wait_for_cancellation(signal)
      end
    end
  end

  # The signal's own record, without falling back to its parent's.
  defp own_record(%Cancellation.Signal{id: id, store: store}), do: store.reason(id)

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
