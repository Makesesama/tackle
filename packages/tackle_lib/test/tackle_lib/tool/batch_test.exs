defmodule Tackle.Lib.Tool.BatchTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.Tool.Batch
  alias Tackle.Lib.Tool.Call
  alias Tackle.Lib.Tool.Error

  test "collects out-of-order completions by call index and reports progress immediately" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    parent = self()
    jobs = jobs(["first", "second"])

    run =
      Task.async(fn ->
        Batch.run(
          jobs,
          supervisor,
          fn %{call: call} ->
            send(parent, {:entered, call.id, self()})
            receive do: ({:release, value} -> value)
          end,
          fn settlement -> send(parent, {:finished, settlement}) end,
          fn -> false end
        )
      end)

    assert_receive {:entered, "first", first}
    assert_receive {:entered, "second", second}
    send(second, {:release, :two})
    assert_receive {:finished, :two}, 1_000
    refute_receive {:finished, :one}, 20
    send(first, {:release, :one})

    assert {%{0 => :one, 1 => :two}, :ok} = Task.await(run)
    assert_receive {:finished, :one}, 1_000
  end

  test "converts a task exit to a tool error without losing sibling results" do
    {:ok, supervisor} = Task.Supervisor.start_link()

    assert {%{0 => {:error, %Error{} = error}, 1 => :success}, :ok} =
             Batch.run(
               jobs(["crash", "success"]),
               supervisor,
               fn
                 %{call: %Call{id: "crash"}} -> exit(:broken)
                 _ -> :success
               end,
               fn _ -> :ok end,
               fn -> false end
             )

    assert error.tool_call_id == "crash"
    assert error.reason == :execution_error
    assert error.details == :broken
    assert error.content == "Error: The tool failed while completing the request."
  end

  test "cancellation shuts down pending tasks and keeps already collected settlements" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    parent = self()
    cancelled = :atomics.new(1, [])

    run =
      Task.async(fn ->
        Batch.run(
          jobs(["done", "pending"]),
          supervisor,
          fn %{call: call} ->
            send(parent, {:entered, call.id, self()})
            receive do: ({:release, result} -> result)
          end,
          fn result -> send(parent, {:finished, result}) end,
          fn -> :atomics.get(cancelled, 1) == 1 end
        )
      end)

    assert_receive {:entered, "done", done}
    assert_receive {:entered, "pending", pending}
    send(done, {:release, :done})
    assert_receive {:finished, :done}, 1_000
    :atomics.put(cancelled, 1, 1)

    assert {%{0 => :done}, :cancelled} = Task.await(run, 5_000)
    refute Process.alive?(pending)
    refute_receive {:finished, _}, 20
  end

  test "empty batch needs no task and returns success" do
    assert {%{}, :ok} =
             Batch.run([], nil, fn _ -> flunk("unexpected task") end, fn _ -> :ok end, fn ->
               false
             end)
  end

  defp jobs(ids) do
    ids
    |> Enum.with_index()
    |> Enum.map(fn {id, index} ->
      %{index: index, call: %Call{id: id, name: "test", definition_id: "definition"}}
    end)
  end
end
