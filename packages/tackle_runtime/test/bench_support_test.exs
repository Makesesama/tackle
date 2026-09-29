Code.require_file("../bench/support.exs", __DIR__)

defmodule Tackle.Runtime.BenchSupportTest do
  use ExUnit.Case, async: false

  alias Tackle.Runtime
  alias Tackle.Runtime.Bench
  alias Tackle.Runtime.Registry

  test "foreground lifecycle consumes its result and tears down the scope" do
    scope = Bench.with_scope(Bench.input(10), &Bench.launch_await/1)
    assert {:error, :not_found} = Registry.scope(scope.scope_ref)
  end

  test "workflow completes and tears down the scope" do
    scope = Bench.setup(Bench.input(10))
    result = Bench.workflow(scope)
    assert :ok = Bench.finish_workflow(result)
    assert {:error, :not_found} = Registry.scope(scope.scope_ref)
  end

  test "streaming delivers the entire burst before await returns" do
    delivered = :atomics.new(1, [])

    Bench.with_scope(Bench.input(10, 100), fn scope ->
      Bench.launch_await(scope, event_callback: fn _ -> :atomics.add(delivered, 1, 1) end)
      assert :atomics.get(delivered, 1) == 100
    end)
  end

  test "retained result is inspectable and collection terminates its request" do
    Bench.with_scope(Bench.input(100), fn scope ->
      {run, pid} = Bench.retained(scope)
      assert Process.alive?(pid)
      state = :sys.get_state(pid)
      assert state.agent_spec == nil
      assert state.prompt == nil
      assert length(state.outcome.agent_state.messages) == 100
      assert {:memory, bytes} = Process.info(pid, :memory)
      assert bytes > 0
      assert :ok = Bench.collect(scope, run, pid)
      refute Process.alive?(pid)
      # Registry removes dead owners asynchronously after the DOWN is delivered.
      assert Runtime.collect(scope.root_agent_ref, run) in [
               {:error, :not_found},
               {:error, :request_terminated}
             ]
    end)
  end

  test "scope cleanup runs even when a scenario fails" do
    assert_raise RuntimeError, "fixture failure", fn ->
      Bench.with_scope(Bench.input(10), fn scope ->
        send(self(), {:scope, scope.scope_ref})
        raise "fixture failure"
      end)
    end

    assert_received {:scope, ref}
    assert {:error, :not_found} = Registry.scope(ref)
  end
end
