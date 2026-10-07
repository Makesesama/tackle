defmodule Tackle.Runtime.RegistryTest do
  # Suspends the shared runtime registry, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias Tackle.Runtime.{Ref, ScopeRef}
  alias Tackle.Runtime.Registry, as: RuntimeRegistry

  test "lookups ignore entries whose process exited before the registry cleaned up" do
    ref = %ScopeRef{scope_id: "registry-test-#{System.unique_integer([:positive])}"}
    test = self()

    pid =
      spawn(fn ->
        {:ok, _owner} = RuntimeRegistry.register(ref)
        send(test, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered
    assert {:ok, ^pid} = RuntimeRegistry.scope(ref)

    # Hold back the registry's asynchronous cleanup so the stale entry stays.
    partitions =
      for {_id, partition, _type, _modules} <- Supervisor.which_children(RuntimeRegistry),
          is_pid(partition),
          do: partition

    Enum.each(partitions, &:sys.suspend/1)

    try do
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

      assert [{^pid, _value}] = RuntimeRegistry.lookup_all(Ref.registry_key(ref))
      assert {:error, :not_found} = RuntimeRegistry.scope(ref)
      assert {:error, :not_found} = Ref.whereis(ref)
    after
      Enum.each(partitions, &:sys.resume/1)
    end
  end
end
