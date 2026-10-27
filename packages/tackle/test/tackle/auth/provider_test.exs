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

  # An adapter with two default providers whose settings choose the models;
  # its type id "multi" names none of them.
  defmodule MultiAdapter do
    @behaviour Tackle.Lib.LLM

    @impl true
    def adapter_id, do: "multi"

    @impl true
    def default_providers,
      do: [{"multi-local", %{"models" => ["one"]}}, {"multi-cloud", %{"models" => ["big"]}}]

    @impl true
    def models(settings), do: Map.get(settings, "models", ["fallback"])

    @impl true
    def generate(_schema, _opts), do: {:error, :not_used}

    @impl true
    def login(opts) do
      send(self(), {:login, opts})
      send(self(), {:accounts_during_login, Auth.accounts()})

      case Keyword.get(opts, :fail_with) do
        nil -> {:ok, %{"token" => "for-" <> opts[:provider_id]}}
        reason -> {:error, reason}
      end
    end
  end

  setup do
    on_exit(fn ->
      for id <- ~w(full store-only broken work multi-local multi-cloud mine mine2 local) do
        Auth.delete(id)
        Auth.delete_account(id)
      end
    end)

    :ok
  end

  test "lists providers with their account-flow capabilities" do
    assert {:ok, [provider]} = Provider.list([FullAdapter])
    assert provider.id == "full"
    assert provider.module == FullAdapter
    assert provider.models == ["one"]

    assert provider.capabilities == %{
             login: true,
             logout: true,
             status: true,
             usage: true
           }

    assert {:ok, [store_only]} = Provider.list([StoreAdapter])

    assert store_only.capabilities == %{
             login: false,
             logout: false,
             status: false,
             usage: false
           }
  end

  test "login delegates to the adapter and stores the returned credentials" do
    assert :ok = Provider.login([FullAdapter], "full", marker: true)
    assert_receive {:login, opts}
    assert opts[:marker] == true
    assert opts[:provider_id] == "full"
    assert opts[:provider_settings] == %{}
    assert {Tackle.Auth.Store, _reference} = opts[:credential_store]
    assert {:ok, %{"token" => "secret"}} = Auth.fetch("full")
  end

  # Login stores, logout deletes, and status reads through Tackle.Auth, so an
  # adapter given another store would refresh or read credentials elsewhere.
  test "adapters always receive the store the flows use" do
    adapters = [FullAdapter]
    opts = [credential_store: {Tackle.Auth.Store, :another_store}]

    assert :ok = Provider.login(adapters, "full", opts)
    assert :ok = Provider.logout(adapters, "full", opts)
    assert {:ok, :expired} = Provider.status(adapters, "full", opts)
    assert {:ok, %{"plan" => "pro"}} = Provider.usage(adapters, "full", opts)

    for flow <- [:login, :logout, :status, :usage] do
      assert_received {^flow, flow_opts}
      assert flow_opts[:credential_store] == Auth.credential_store()
    end
  end

  test "flows resolve providers by id and pass that provider's settings" do
    adapters = [MultiAdapter]
    opts = [config_providers: %{}]

    assert :ok = Provider.login(adapters, "multi-cloud", opts)
    assert_receive {:login, login_opts}
    assert login_opts[:provider_id] == "multi-cloud"
    assert login_opts[:provider_settings] == %{"models" => ["big"]}

    assert {:ok, %{"token" => "for-multi-cloud"}} = Auth.fetch("multi-cloud")
    assert :error = Auth.fetch("multi-local")
    assert {:ok, :stored} = Provider.status(adapters, "multi-cloud", opts)
    assert {:ok, :missing} = Provider.status(adapters, "multi-local", opts)
  end

  test "lists providers with their adapter type and source" do
    assert :ok = Auth.put_account("work", %{"adapter" => "multi"})

    assert {:ok, providers} =
             Provider.list([FullAdapter, MultiAdapter],
               config_providers: %{
                 "mine" => %{"adapter" => "multi", "models" => ["custom"]},
                 "multi-local" => %{"adapter" => "multi", "models" => ["two"]}
               }
             )

    assert Enum.map(providers, &{&1.id, &1.adapter, &1.module, &1.source, &1.models}) == [
             {"full", "full", FullAdapter, :default, ["one"]},
             {"multi-local", "multi", MultiAdapter, :default, ["two"]},
             {"multi-cloud", "multi", MultiAdapter, :default, ["big"]},
             {"work", "multi", MultiAdapter, :account, ["fallback"]},
             {"mine", "multi", MultiAdapter, :config, ["custom"]}
           ]
  end

  test "login as a name stores credentials under it, then records the account" do
    adapters = [FullAdapter, MultiAdapter]
    opts = [config_providers: %{}]

    # From an adapter type id, the account starts without settings.
    assert :ok = Provider.login(adapters, "multi", Keyword.put(opts, :as, "work"))
    assert_receive {:login, login_opts}
    assert login_opts[:provider_id] == "work"
    assert login_opts[:provider_settings] == %{}
    refute Keyword.has_key?(login_opts, :as)

    # The account is recorded only after the adapter's login succeeded.
    assert_receive {:accounts_during_login, {:ok, accounts}}
    refute Map.has_key?(accounts, "work")

    assert accounts()["work"] == %{"adapter" => "multi"}
    assert {:ok, %{"token" => "for-work"}} = Auth.fetch("work")
    assert :error = Auth.fetch("multi-local")

    # From a provider id, the account inherits that provider's settings.
    assert :ok = Provider.login(adapters, "multi-cloud", Keyword.put(opts, :as, "mine"))
    assert_receive {:login, login_opts}
    assert login_opts[:provider_settings] == %{"models" => ["big"]}
    assert accounts()["mine"] == %{"adapter" => "multi", "base" => "multi-cloud"}

    assert {:ok, providers} = Provider.list(adapters, opts)
    assert %{source: :account, adapter: "multi"} = Enum.find(providers, &(&1.id == "work"))
    assert %{source: :account, models: ["big"]} = Enum.find(providers, &(&1.id == "mine"))

    # Logging in from an account reuses its base instead of chaining accounts.
    assert :ok = Provider.login(adapters, "mine", Keyword.put(opts, :as, "mine2"))
    assert accounts()["mine2"] == %{"adapter" => "multi", "base" => "multi-cloud"}

    # Logging in again keeps the account and replaces its credentials.
    assert :ok = Provider.login(adapters, "multi", Keyword.put(opts, :as, "work"))
    assert accounts()["work"] == %{"adapter" => "multi"}
  end

  test "login as a name merges config.json settings declared for that name" do
    adapters = [MultiAdapter]

    opts = [
      config_providers: %{"work" => %{"adapter" => "multi", "base_url" => "http://work"}}
    ]

    assert :ok = Provider.login(adapters, "multi", Keyword.put(opts, :as, "work"))
    assert_receive {:login, login_opts}
    assert login_opts[:provider_settings] == %{"base_url" => "http://work"}

    assert :ok = Provider.login(adapters, "multi-cloud", Keyword.put(opts, :as, "work"))
    assert_receive {:login, login_opts}
    assert login_opts[:provider_settings] == %{"models" => ["big"], "base_url" => "http://work"}
  end

  test "a failed login as a name leaves no account and no credentials" do
    adapters = [MultiAdapter]
    opts = [config_providers: %{}, as: "work"]

    assert {:error, :denied} =
             Provider.login(adapters, "multi", Keyword.put(opts, :fail_with, :denied))

    refute Map.has_key?(accounts(), "work")
    assert :error = Auth.fetch("work")

    # A failed re-login keeps the account and the credentials that existed.
    assert :ok = Provider.login(adapters, "multi", opts)

    assert {:error, :denied} =
             Provider.login(adapters, "multi", Keyword.put(opts, :fail_with, :denied))

    assert accounts()["work"] == %{"adapter" => "multi"}
    assert {:ok, %{"token" => "for-work"}} = Auth.fetch("work")
  end

  test "login as rejects invalid names, unknown adapters, and adapter conflicts" do
    adapters = [FullAdapter, MultiAdapter]
    opts = [config_providers: %{}]

    assert {:error, {:invalid_provider_id, "Bad Name"}} =
             Provider.login(adapters, "multi", Keyword.put(opts, :as, "Bad Name"))

    assert {:error, {:unsupported_auth_provider, "missing", {:supported, supported}}} =
             Provider.login(adapters, "missing", Keyword.put(opts, :as, "work"))

    assert "multi-cloud" in supported
    assert "multi" in supported

    # A config.json provider of another adapter owns its name.
    assert {:error, {:provider_adapter_conflict, "local"}} =
             Provider.login(
               adapters,
               "multi",
               Keyword.merge(opts,
                 as: "local",
                 config_providers: %{"local" => %{"adapter" => "full"}}
               )
             )

    assert {:error, {:invalid_option, :accounts, :none}} =
             Provider.login(adapters, "multi", Keyword.merge(opts, as: "work", accounts: :none))

    # An adapter without login records nothing.
    assert {:error, {:unsupported_provider_flow, "work", :login}} =
             Provider.login([StoreAdapter], "store-only", as: "work")

    refute_received {:login, _opts}
    refute Map.has_key?(accounts(), "work")
    refute Map.has_key?(accounts(), "full")
    refute Map.has_key?(accounts(), "local")
    assert :error = Auth.fetch("work")
  end

  # The merge skips an account named like a default provider, of its own
  # adapter or another, so such an account would be recorded but never used.
  test "login as refuses the id of any default provider" do
    adapters = [FullAdapter, MultiAdapter]
    opts = [config_providers: %{}]

    for {id, name} <- [
          {"multi", "multi-local"},
          {"multi-cloud", "multi-local"},
          {"multi", "full"}
        ] do
      assert {:error, {:default_provider_name, ^name}} =
               Provider.login(adapters, id, Keyword.put(opts, :as, name))
    end

    refute_received {:login, _opts}
    refute Map.has_key?(accounts(), "multi-local")
    refute Map.has_key?(accounts(), "full")
    assert :error = Auth.fetch("multi-local")
    assert :error = Auth.fetch("full")
  end

  test "login as never replaces an account of another adapter" do
    adapters = [MultiAdapter]
    opts = [config_providers: %{}]

    # The merge skips this account because its adapter is not installed here.
    assert :ok = Auth.put_account("work", %{"adapter" => "not-installed"})
    assert :ok = Auth.put("work", %{"token" => "other-host"})

    assert {:error, {:provider_adapter_conflict, "work"}} =
             Provider.login(adapters, "multi", Keyword.put(opts, :as, "work"))

    refute_received {:login, _opts}
    assert accounts()["work"] == %{"adapter" => "not-installed"}
    assert {:ok, %{"token" => "other-host"}} = Auth.fetch("work")
  end

  test "logout of an account deletes its record; default providers keep theirs" do
    adapters = [MultiAdapter]
    opts = [config_providers: %{}]

    assert :ok = Provider.login(adapters, "multi", Keyword.put(opts, :as, "work"))
    assert :ok = Provider.login(adapters, "multi-local", opts)

    assert :ok = Provider.logout(adapters, "work", opts)
    assert :error = Auth.fetch("work")
    refute Map.has_key?(accounts(), "work")

    assert {:error, {:unsupported_auth_provider, "work", _supported}} =
             Provider.status(adapters, "work", opts)

    assert :ok = Provider.logout(adapters, "multi-local", opts)
    assert :error = Auth.fetch("multi-local")
    assert {:ok, :missing} = Provider.status(adapters, "multi-local", opts)
  end

  test "logout keeps an account of the same name that belongs to another adapter" do
    assert :ok = Auth.put_account("full", %{"adapter" => "not-installed"})

    assert :ok = Provider.logout([FullAdapter], "full", config_providers: %{})
    assert accounts()["full"] == %{"adapter" => "not-installed"}
  end

  test "accounts whose adapter is not configured are skipped" do
    assert :ok = Auth.put_account("work", %{"adapter" => "not-installed"})

    assert {:ok, providers} = Provider.list([FullAdapter], config_providers: %{})
    assert Enum.map(providers, & &1.id) == ["full"]
  end

  test "logout and status fall back to the credential store when unimplemented" do
    assert :ok = Auth.put("store-only", %{"token" => "stored"})

    assert {:ok, :stored} = Provider.status([StoreAdapter], "store-only")
    assert :ok = Provider.logout([StoreAdapter], "store-only")
    assert :error = Auth.fetch("store-only")
    assert {:ok, :missing} = Provider.status([StoreAdapter], "store-only")
  end

  test "adapter callbacks take precedence for logout, status, and usage" do
    assert :ok = Provider.logout([FullAdapter], "full")
    assert_received {:logout, _opts}

    assert {:ok, :expired} = Provider.status([FullAdapter], "full")
    assert_received {:status, _opts}

    assert {:ok, %{"plan" => "pro"}} = Provider.usage([FullAdapter], "full")
    assert_received {:usage, _opts}
  end

  test "rejects unknown providers and unimplemented flows" do
    assert {:error, {:unsupported_auth_provider, "missing", {:supported, ["full"]}}} =
             Provider.login([FullAdapter], "missing")

    assert {:error, {:unsupported_provider_flow, "store-only", :login}} =
             Provider.login([StoreAdapter], "store-only")

    assert {:error, {:unsupported_provider_flow, "store-only", :usage}} =
             Provider.usage([StoreAdapter], "store-only")
  end

  test "reports adapter callback failures explicitly" do
    assert {:error, {:adapter_callback_failed, BrokenAdapter, :login, "boom"}} =
             Provider.login([BrokenAdapter], "broken")
  end

  test "rejects non-map credentials returned by an adapter" do
    assert {:error, {:invalid_credentials, :not_a_map}} =
             Provider.login([InvalidCredentialsAdapter], "invalid-credentials")
  end

  defp accounts do
    assert {:ok, accounts} = Auth.accounts()
    accounts
  end
end
