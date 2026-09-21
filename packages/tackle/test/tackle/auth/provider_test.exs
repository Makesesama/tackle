defmodule Tackle.Auth.ProviderTest do
  use ExUnit.Case, async: false

  alias Tackle.Auth
  alias Tackle.Auth.Provider

  defmodule FullAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "full"

    @impl true
    def models, do: ["one"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}

    @impl true
    def login(opts) do
      send(self(), {:login, opts})
      {:ok, %{"token" => "secret"}}
    end

    @impl true
    def logout(opts) do
      send(self(), {:logout, opts})
      :ok
    end

    @impl true
    def status(opts) do
      send(self(), {:status, opts})
      {:ok, :expired}
    end

    @impl true
    def usage(opts) do
      send(self(), {:usage, opts})
      {:ok, %{"plan" => "pro"}}
    end
  end

  defmodule StoreAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "store-only"

    @impl true
    def models, do: ["one"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}
  end

  defmodule BrokenAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "broken"

    @impl true
    def models, do: ["one"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}

    @impl true
    def login(_opts), do: raise("boom")
  end

  defmodule InvalidCredentialsAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "invalid-credentials"

    @impl true
    def models, do: ["one"]

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}

    @impl true
    def login(_opts), do: {:ok, :not_a_map}
  end

  setup do
    on_exit(fn ->
      Auth.delete("full")
      Auth.delete("store-only")
      Auth.delete("broken")
    end)

    :ok
  end

  test "lists providers with their account-flow capabilities" do
    assert {:ok, [provider]} = Provider.list(adapters: [FullAdapter])
    assert provider.id == "full"
    assert provider.module == FullAdapter
    assert provider.models == ["one"]

    assert provider.capabilities == %{
             login: true,
             logout: true,
             status: true,
             usage: true
           }

    assert {:ok, [store_only]} = Provider.list(adapters: [StoreAdapter])

    assert store_only.capabilities == %{
             login: false,
             logout: false,
             status: false,
             usage: false
           }
  end

  test "login delegates to the adapter and stores the returned credentials" do
    assert :ok = Provider.login("full", adapters: [FullAdapter], marker: true)
    assert_receive {:login, opts}
    assert opts[:marker] == true
    assert {Tackle.Auth.Store, _reference} = opts[:credential_store]
    assert {:ok, %{"token" => "secret"}} = Auth.fetch("full")
  end

  test "logout and status fall back to the credential store when unimplemented" do
    assert :ok = Auth.put("store-only", %{"token" => "stored"})

    assert {:ok, :stored} = Provider.status("store-only", adapters: [StoreAdapter])
    assert :ok = Provider.logout("store-only", adapters: [StoreAdapter])
    assert :error = Auth.fetch("store-only")
    assert {:ok, :missing} = Provider.status("store-only", adapters: [StoreAdapter])
  end

  test "adapter callbacks take precedence for logout, status, and usage" do
    assert :ok = Provider.logout("full", adapters: [FullAdapter])
    assert_received {:logout, _opts}

    assert {:ok, :expired} = Provider.status("full", adapters: [FullAdapter])
    assert_received {:status, _opts}

    assert {:ok, %{"plan" => "pro"}} = Provider.usage("full", adapters: [FullAdapter])
    assert_received {:usage, _opts}
  end

  test "rejects unknown providers and unimplemented flows" do
    assert {:error, {:unsupported_auth_provider, "missing", {:supported, ["full"]}}} =
             Provider.login("missing", adapters: [FullAdapter])

    assert {:error, {:unsupported_provider_flow, "store-only", :login}} =
             Provider.login("store-only", adapters: [StoreAdapter])

    assert {:error, {:unsupported_provider_flow, "store-only", :usage}} =
             Provider.usage("store-only", adapters: [StoreAdapter])
  end

  test "reports adapter callback failures explicitly" do
    assert {:error, {:adapter_callback_failed, BrokenAdapter, :login, "boom"}} =
             Provider.login("broken", adapters: [BrokenAdapter])
  end

  test "rejects non-map credentials returned by an adapter" do
    assert {:error, {:invalid_credentials, :not_a_map}} =
             Provider.login("invalid-credentials", adapters: [InvalidCredentialsAdapter])
  end
end
