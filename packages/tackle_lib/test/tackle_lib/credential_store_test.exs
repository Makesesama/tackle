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
end
