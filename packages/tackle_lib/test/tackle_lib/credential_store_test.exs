defmodule Tackle.Lib.CredentialStoreTest do
  use ExUnit.Case, async: true

  alias Tackle.Lib.CredentialStore

  defmodule Store do
    @behaviour CredentialStore

    @impl true
    def fetch(reference, namespace) do
      send(reference, {:fetch, namespace})
      {:ok, %{"opaque" => true}}
    end

    @impl true
    def put(reference, namespace, credentials) do
      send(reference, {:put, namespace, credentials})
      :ok
    end

    @impl true
    def delete(reference, namespace) do
      send(reference, {:delete, namespace})
      :ok
    end
  end

  test "delegates operations through an opaque handle" do
    handle = {Store, self()}

    assert {:ok, %{"opaque" => true}} = CredentialStore.fetch(handle, "provider")
    assert_receive {:fetch, "provider"}

    assert :ok = CredentialStore.put(handle, "provider", %{"token" => "secret"})
    assert_receive {:put, "provider", %{"token" => "secret"}}

    assert :ok = CredentialStore.delete(handle, "provider")
    assert_receive {:delete, "provider"}
  end

  defmodule ResultStore do
    @behaviour CredentialStore

    @impl true
    def fetch(result, _namespace), do: result

    @impl true
    def put(_result, _namespace, _credentials), do: :ok

    @impl true
    def delete(_result, _namespace), do: :ok
  end

  test "fetch/2 checks what the implementation returns" do
    assert CredentialStore.fetch({ResultStore, :error}, "p") == :error

    assert CredentialStore.fetch({ResultStore, {:error, :down}}, "p") ==
             {:error, {:credential_store_failed, :down}}

    # A malformed result is a store failure, and its value (possibly a secret)
    # is not echoed.
    for result <- [{:ok, "sk-secret"}, {:ok, nil}, :ok, nil] do
      assert CredentialStore.fetch({ResultStore, result}, "p") ==
               {:error, {:credential_store_failed, :invalid_result}}
    end
  end

  test "from_opts/1 reads the handle adapters are called with" do
    assert CredentialStore.from_opts(credential_store: {Store, self()}) == {:ok, {Store, self()}}
    assert CredentialStore.from_opts([]) == :error
    assert CredentialStore.from_opts(credential_store: nil) == :error

    for invalid <- [:store, {nil, :ref}, {"Store", :ref}] do
      assert CredentialStore.from_opts(credential_store: invalid) ==
               {:error, :invalid_credential_store}
    end
  end

  defmodule LockingStore do
    @behaviour CredentialStore

    @impl true
    def fetch(_reference, _namespace), do: :error

    @impl true
    def put(_reference, _namespace, _credentials), do: :ok

    @impl true
    def delete(_reference, _namespace), do: :ok

    @impl true
    def with_lock({test, :fail}, namespace, _fun) do
      send(test, {:with_lock, namespace})
      {:error, {:credential_lock_failed, :busy}}
    end

    def with_lock(test, namespace, fun) do
      send(test, {:with_lock, namespace})
      fun.()
    end
  end

  describe "with_lock/3" do
    test "uses the store's lock and returns the function's result" do
      handle = {LockingStore, self()}

      assert CredentialStore.with_lock(handle, "provider", fn -> {:ok, :refreshed} end) ==
               {:ok, :refreshed}

      assert_receive {:with_lock, "provider"}

      # Whatever the function returns passes through, errors included.
      assert CredentialStore.with_lock(handle, "provider", fn -> {:error, :expired} end) ==
               {:error, :expired}
    end

    test "returns the store's lock failure without running the function" do
      handle = {LockingStore, {self(), :fail}}

      assert CredentialStore.with_lock(handle, "provider", fn -> flunk("ran unlocked") end) ==
               {:error, {:credential_lock_failed, :busy}}

      assert_receive {:with_lock, "provider"}
    end

    test "without the callback, runs the function under a lock in this BEAM" do
      handle = {Store, self()}

      assert CredentialStore.with_lock(handle, "provider", fn -> :aborted end) == :aborted
      assert CredentialStore.with_lock(handle, "provider", fn -> {:error, :x} end) == {:error, :x}

      assert CredentialStore.with_lock(handle, "provider", fn ->
               CredentialStore.fetch(handle, "provider")
             end) == {:ok, %{"opaque" => true}}
    end

    test "without the callback, serializes processes on one namespace only" do
      handle = {Store, make_ref()}
      test = self()

      holder =
        spawn(fn ->
          CredentialStore.with_lock(handle, "provider", fn ->
            send(test, :holding)

            receive do
              :release -> :ok
            end
          end)

          send(test, :holder_done)
        end)

      assert_receive :holding

      waiter =
        Task.async(fn ->
          CredentialStore.with_lock(handle, "provider", fn -> send(test, :waiter_ran) end)
        end)

      other =
        Task.async(fn -> CredentialStore.with_lock(handle, "other", fn -> :other_ran end) end)

      assert Task.await(other) == :other_ran
      refute_receive :waiter_ran, 200

      send(holder, :release)
      assert_receive :holder_done
      # `:global` retries a taken lock after a random back-off.
      assert_receive :waiter_ran, 10_000
      assert Task.await(waiter) == :waiter_ran
    end
  end
end
