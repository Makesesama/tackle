defmodule Tackle.Runtime.ToolConcurrencyTest do
  use ExUnit.Case, async: false

  import Tackle.Test.Runtime

  alias Tackle.Runtime.Registry
  alias Tackle.Test.BlockingTool

  test "every session owns a distinct tool supervisor" do
    scope =
      start_scope(
        root: [allow_delegation: true, mode: :manual],
        profiles: %{"child" => agent_spec("child", mode: :manual)}
      )

    assert {:ok, root_tool_supervisor} = Registry.tool_supervisor(scope.root_agent_ref)
    assert is_pid(root_tool_supervisor)

    {:ok, run_ref} = Tackle.Runtime.request_agent(scope.root_agent_ref, "child", "work")
    assert_eventually(fn -> match?({:ok, _}, Tackle.Runtime.session_pid(run_ref.agent_ref)) end)

    assert {:ok, child_tool_supervisor} = Registry.tool_supervisor(run_ref.agent_ref)
    assert is_pid(child_tool_supervisor)
    refute child_tool_supervisor == root_tool_supervisor
  end

  test "a multi-call batch executes concurrently and commits results in call order" do
    scope = start_concurrent_scope()

    assert {:ok, snapshot} = Tackle.subscribe(scope.root_agent_ref)
    assert {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "go")

    # Both tools enter before either is released, proving parallel dispatch.
    assert_receive {:tool_entered, first_name, first_task}, 5_000
    assert_receive {:tool_entered, second_name, second_task}, 5_000
    assert MapSet.new([first_name, second_name]) == MapSet.new(["one", "two"])

    send(first_task, {:release, first_name})
    send(second_task, {:release, second_name})

    assert_receive {:tackle_turn_finished, session_id, ^turn_id, {:ok, state}}, 5_000
    assert session_id == snapshot.session_id

    tool_call_ids =
      state.messages
      |> Enum.filter(&(&1.role == :tool))
      |> Enum.map(& &1.tool_call_id)

    assert tool_call_ids == ["c1", "c2"]
  end

  test "cancelling a turn shuts down in-flight tool tasks" do
    scope = start_concurrent_scope()

    assert {:ok, _snapshot} = Tackle.subscribe(scope.root_agent_ref)
    assert {:ok, turn_id} = Tackle.submit(scope.root_agent_ref, "go")

    assert_receive {:tool_entered, _first_name, first_task}, 5_000
    assert_receive {:tool_entered, _second_name, second_task}, 5_000

    assert :ok = Tackle.cancel(scope.root_agent_ref)

    assert_receive {:tackle_turn_finished, _session_id, ^turn_id, {:cancelled, _state}}, 5_000

    assert_eventually(fn ->
      not Process.alive?(first_task) and not Process.alive?(second_task)
    end)
  end

  test "a root tool supervisor crash tears down the scope" do
    scope = start_scope()
    {:ok, tool_supervisor} = Registry.tool_supervisor(scope.root_agent_ref)
    {:ok, scope_supervisor} = Registry.scope(scope.scope_ref)
    monitor = Process.monitor(scope_supervisor)

    Process.exit(tool_supervisor, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^scope_supervisor, _reason}, 2_000
    assert_eventually(fn -> Registry.scope(scope.scope_ref) == {:error, :not_found} end)
  end

  test "a descendant tool supervisor crash is isolated to that session" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{"child" => agent_spec("child", mode: :manual)}
      )

    {:ok, run_ref} = Tackle.Runtime.request_agent(scope.root_agent_ref, "child", "work")
    assert_eventually(fn -> match?({:ok, _}, Tackle.Runtime.session_pid(run_ref.agent_ref)) end)

    {:ok, child_tool_supervisor} = Registry.tool_supervisor(run_ref.agent_ref)
    {:ok, child_session} = Tackle.Runtime.session_pid(run_ref.agent_ref)
    monitor = Process.monitor(child_session)

    Process.exit(child_tool_supervisor, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^child_session, _reason}, 2_000

    # The root and its own tool supervisor are unaffected.
    assert {:ok, _pid} = Tackle.Runtime.session_pid(scope.root_agent_ref)
    assert {:ok, _pid} = Registry.tool_supervisor(scope.root_agent_ref)
  end

  test "an ephemeral session cleans up its tool supervisor when it finishes" do
    scope =
      start_scope(
        root: [allow_delegation: true],
        profiles: %{"worker" => agent_spec("worker", content: "worker answer")}
      )

    {:ok, run_ref} = Tackle.Runtime.request_agent(scope.root_agent_ref, "worker", "do work")
    assert %{status: :ok} = Tackle.Runtime.await(run_ref, 5_000)

    assert_eventually(fn ->
      Tackle.Runtime.session_pid(run_ref.agent_ref) == {:error, :not_found} and
        Registry.tool_supervisor(run_ref.agent_ref) == {:error, :not_found}
    end)
  end

  defp assert_eventually(fun), do: assert(:ok = eventually(fun))

  defp start_concurrent_scope do
    start_scope(
      root: [
        tools: [BlockingTool],
        context: %{test_pid: self()},
        mode: :tools_then_answer,
        llm_opts: [
          tool_calls: [
            %{"id" => "c1", "name" => "blocking", "arguments" => %{"name" => "one"}},
            %{"id" => "c2", "name" => "blocking", "arguments" => %{"name" => "two"}}
          ],
          content: "done"
        ]
      ]
    )
  end
end
