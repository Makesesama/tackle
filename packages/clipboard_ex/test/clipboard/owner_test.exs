defmodule Clipboard.OwnerTest do
  use ExUnit.Case, async: false

  alias Clipboard.{FakeNative, Owner}

  setup do
    on_exit(&FakeNative.teardown/0)
    :ok
  end

  defp start_owner do
    start_supervised!({Owner, name: nil, native: FakeNative})
  end

  test "opens the handle lazily, once, and passes it to native calls" do
    FakeNative.setup(self(), fn
      :new, [] -> {:ok, :handle}
      :get_text, [:handle, :clipboard] -> {:ok, "hello"}
    end)

    owner = start_owner()
    refute_received {:native, :new, []}

    assert Owner.request(owner, :get_text, [:clipboard], 1_000) == {:ok, "hello"}
    assert Owner.request(owner, :get_text, [:clipboard], 1_000) == {:ok, "hello"}

    assert_received {:native, :new, []}
    refute_received {:native, :new, []}
  end

  test "returns a failed open and retries it on the next request" do
    test_pid = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    FakeNative.setup(test_pid, fn
      :new, [] ->
        case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
          0 -> {:error, :clipboard_not_supported}
          _ -> {:ok, :handle}
        end

      :clear, [:handle, :clipboard] ->
        :ok
    end)

    owner = start_owner()

    assert Owner.request(owner, :clear, [:clipboard], 1_000) ==
             {:error, :clipboard_not_supported}

    refute_received {:native, :clear, _args}
    assert Owner.request(owner, :clear, [:clipboard], 1_000) == :ok
  end

  test "reports a raising native function without losing the handle" do
    FakeNative.setup(self(), fn
      :new, [] -> {:ok, :handle}
      :get_text, _args -> raise ErlangError, original: :nif_panicked
      :clear, [:handle, :clipboard] -> :ok
    end)

    owner = start_owner()

    assert {:error, {:native_error, message}} =
             Owner.request(owner, :get_text, [:clipboard], 1_000)

    assert message =~ "nif_panicked"
    assert Owner.request(owner, :clear, [:clipboard], 1_000) == :ok
    assert_received {:native, :new, []}
    refute_received {:native, :new, []}
  end

  test "times out without exiting the caller" do
    FakeNative.setup(self(), fn
      :new, [] ->
        {:ok, :handle}

      :get_text, _args ->
        Process.sleep(200)
        {:ok, "late"}
    end)

    owner = start_owner()
    assert Owner.request(owner, :get_text, [:clipboard], 10) == {:error, :timeout}
  end

  test "closes an opened handle when stopped" do
    FakeNative.setup(self(), fn
      :new, [] -> {:ok, :handle}
      :clear, _args -> :ok
      :close, [:handle] -> :ok
    end)

    owner = start_owner()
    assert Owner.request(owner, :clear, [:clipboard], 1_000) == :ok

    :ok = GenServer.stop(owner)
    assert_received {:native, :close, [:handle]}
  end

  test "does not close a handle it never opened" do
    FakeNative.setup(self(), fn function, _args -> flunk("unexpected #{function}") end)

    owner = start_owner()
    :ok = GenServer.stop(owner)
    refute_received {:native, _function, _args}
  end

  test "contains a native function that exits" do
    FakeNative.setup(self(), fn
      :new, [] -> {:ok, :handle}
      :get_text, _args -> exit(:boom)
      :clear, [:handle, :clipboard] -> :ok
    end)

    owner = start_owner()

    assert Owner.request(owner, :get_text, [:clipboard], 1_000) ==
             {:error, {:native_error, {:exit, :boom}}}

    assert Owner.request(owner, :clear, [:clipboard], 1_000) == :ok
    assert_received {:native, :new, []}
    refute_received {:native, :new, []}
  end

  test "reports an owner killed during a request" do
    test_pid = self()

    FakeNative.setup(test_pid, fn
      :new, [] ->
        {:ok, :handle}

      :get_text, _args ->
        send(test_pid, {:busy, self()})
        Process.sleep(:infinity)
    end)

    owner = start_owner()
    task = Task.async(fn -> Owner.request(owner, :get_text, [:clipboard], 1_000) end)

    assert_receive {:busy, ^owner}
    Process.exit(owner, :kill)

    assert Task.await(task) == {:error, {:owner_exit, :killed}}
  end

  test "reports an owner that is not running" do
    assert Owner.request(:no_such_owner, :clear, [:clipboard], 100) ==
             {:error, :owner_not_running}
  end
end
