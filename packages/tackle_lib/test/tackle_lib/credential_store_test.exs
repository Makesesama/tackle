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
end
