defmodule Tackle.Web.ModelsTest do
  use Tackle.Web.DataCase, async: true

  import Tackle.Web.AccountsFixtures

  alias Ash.Resource.Info
  alias Tackle.Lib.CredentialStore, as: Store
  alias Tackle.Web.{CredentialStore, Models, Repo}
  alias Tackle.Web.Models.{Provider, ReviewDefaults}

  @model "openai-codex/gpt-6.1-sol"

  setup do
    %{owner: user!()}
  end

  # Trusted registration for `owner`, as the console would do it.
  defp register!(owner, name, adapter, attrs \\ %{}),
    do: Provider.register!(name, adapter, Map.put(attrs, :owner_id, owner.id))

  defp defaults!(owner, attrs), do: ReviewDefaults.configure!(Map.put(attrs, :user_id, owner.id))
  defp defaults(owner, attrs), do: ReviewDefaults.configure(Map.put(attrs, :user_id, owner.id))

  test "provider names and adapters are constrained, settings are JSON, credentials are not accepted by configure",
       %{owner: owner} do
    for name <- ["Bad", "-bad", "bad-", "a/b", "a b"] do
      assert {:error, _error} = Provider.register(name, :codex, %{owner_id: owner.id})
    end

    assert {:error, _error} = Provider.register("custom", :unknown, %{owner_id: owner.id})

    assert {:error, _error} =
             Provider.register("custom", :codex, %{owner_id: owner.id, settings: %{atom: true}})

    assert {:error, _error} = Provider.register("custom", :codex)
    provider = register!(owner, "custom", :codex)
    assert {:error, _error} = Provider.configure(provider, %{credentials: %{"token" => "no"}})
    assert {:error, _error} = Provider.configure(provider, %{adapter: :openrouter})
    assert {:error, _error} = Provider.configure(provider, %{name: "other"})
    assert {:error, _error} = Provider.register("custom", :codex, %{owner_id: owner.id})
    assert %Provider{name: "custom"} = register!(user!(), "custom", :codex)
  end

  test "enabled providers use the allowlist, preserve settings, belong to one owner, and do not load secrets",
       %{owner: owner} do
    register!(owner, "disabled", :codex)

    register!(owner, "router", :openrouter, %{
      enabled: true,
      settings: %{"provider_routing" => %{"order" => ["test"]}}
    })

    register!(user!(), "other", :codex, %{enabled: true})

    assert {:ok, [provider]} = Models.enabled_providers(owner.id)
    assert provider.id == "router"
    assert provider.adapter == Tackle.Plugins.OpenRouter
    assert provider.settings == %{"provider_routing" => %{"order" => ["test"]}}
    assert Models.enabled_providers(nil) == {:ok, []}
  end

  test "OpenRouter key action encrypts and redacts secrets, and refuses Codex or empty keys",
       %{owner: owner} do
    provider = register!(owner, "router", :openrouter)
    Provider.set_credentials!(provider, "private-api-key")
    assert {:ok, read} = Provider.get(provider.id)
    assert %Ash.NotLoaded{} = read.credentials
    assert Info.field(Provider, :credentials).sensitive?

    assert Info.action(Provider, :set_credentials).arguments
           |> hd()
           |> Map.fetch!(:sensitive?)

    {:ok, %{rows: [[ciphertext]]}} =
      Repo.query(
        "select encrypted_credentials from providers where id = $1",
        [Ecto.UUID.dump!(provider.id)]
      )

    refute String.contains?(ciphertext, "private-api-key")

    assert Store.fetch(CredentialStore.handle(owner.id), "router") ==
             {:ok, %{"api_key" => "private-api-key"}}

    assert Store.fetch(CredentialStore.handle(user!().id), "router") == :error
    assert {:error, _error} = Provider.set_credentials(provider, "   ")
    codex = register!(owner, "codex", :codex)
    assert {:error, _error} = Provider.set_credentials(codex, "key")
  end

  test "stable DB handle reads fresh credentials; put/delete are transactional and never create providers",
       %{owner: owner} do
    handle = CredentialStore.handle(owner.id)
    assert handle == {CredentialStore, owner.id}
    assert Store.fetch(handle, "missing") == :error
    assert Store.put(handle, "missing", %{}) == {:error, {:unknown_provider, "missing"}}
    assert Store.delete(handle, "missing") == :ok
    register!(owner, "codex", :codex)
    assert Store.fetch(handle, "codex") == :error
    assert Store.put(handle, "codex", %{"refresh_token" => "old"}) == :ok

    fresh = CredentialStore.handle(owner.id)
    assert Store.put(fresh, "codex", %{"refresh_token" => "rotated"}) == :ok

    other = CredentialStore.handle(user!().id)
    assert Store.fetch(other, "codex") == :error

    assert Store.put(other, "codex", %{"refresh_token" => "other"}) ==
             {:error, {:unknown_provider, "codex"}}

    assert Store.fetch(handle, "codex") == {:ok, %{"refresh_token" => "rotated"}}

    for invalid <- [%{"not-json" => self()}, %{"invalid-utf8" => <<255>>}, %{atom: "key"}] do
      assert {:error, _error} = Store.put(handle, "codex", invalid)
    end

    assert Store.fetch(handle, "codex") == {:ok, %{"refresh_token" => "rotated"}}

    assert {:error, :test_rollback} =
             Repo.transaction(fn ->
               :ok = Store.put(handle, "codex", %{"refresh_token" => "rolled-back"})
               Repo.rollback(:test_rollback)
             end)

    assert Store.fetch(handle, "codex") == {:ok, %{"refresh_token" => "rotated"}}
    assert Store.delete(handle, "codex") == :ok
    assert Store.delete(handle, "codex") == :ok
    assert Store.fetch(handle, "codex") == :error
  end

  test "metadata updates cannot overwrite a refreshed credential, and empty maps remain stored",
       %{owner: owner} do
    handle = CredentialStore.handle(owner.id)
    stale = register!(owner, "codex", :codex)
    :ok = Store.put(handle, "codex", %{"refresh_token" => "fresh"})
    Provider.configure!(stale, %{enabled: true, settings: %{"option" => true}})
    assert Store.fetch(handle, "codex") == {:ok, %{"refresh_token" => "fresh"}}
    Provider.store_credentials!(stale, %{})
    assert Store.fetch(handle, "codex") == {:ok, %{}}
    {:ok, read} = Provider.get(stale.id)
    assert read.settings == %{"option" => true}
    assert read.enabled
  end

  test "repository stage models can supply all required models without a default row",
       %{owner: owner} do
    register!(owner, "openai-codex", :codex, %{enabled: true})

    assert {:ok, settings} =
             Models.resolve_settings(owner.id, %{
               "models" => %{"detector" => @model, "verifier" => @model, "scorer" => @model}
             })

    assert settings.models.scorer == @model
    assert settings.thinking == %{}
    assert settings.max_steps == %{}
  end

  test "no implicit models; defaults are one row per user, with repository per-stage precedence",
       %{owner: owner} do
    assert {:error, {:missing_review_models, [:detector, :verifier]}} =
             Models.resolve_settings(owner.id)

    register!(owner, "openai-codex", :codex, %{enabled: true})
    first = defaults!(owner, %{models: %{"detector" => @model}})
    assert {:error, {:missing_review_models, [:verifier]}} = Models.resolve_settings(owner.id)

    second =
      defaults!(owner, %{
        models: %{"detector" => @model, "verifier" => @model},
        thinking: %{"detector" => "low", "verifier" => "medium"}
      })

    assert second.user_id == first.user_id
    assert [_defaults] = Ash.read!(ReviewDefaults)

    # Another user's defaults and providers are their own.
    other = user!()

    assert {:error, {:missing_review_models, [:detector, :verifier]}} =
             Models.resolve_settings(other.id)

    assert {:error, _error} = defaults(other, %{models: %{"detector" => @model}})

    assert {:ok, settings} =
             Models.resolve_settings(
               owner.id,
               %{
                 "models" => %{"verifier" => "openai-codex/gpt-6-sol"},
                 "thinking" => %{"verifier" => "high"},
                 "max_steps" => %{"detector" => 7},
                 "default_rules" => []
               },
               :assertive
             )

    assert settings.models == %{detector: @model, verifier: "openai-codex/gpt-6-sol"}
    assert settings.thinking == %{detector: "low", verifier: "high"}
    assert settings.profile == :assertive
    assert settings.max_steps == %{detector: 7}
    assert settings.default_rules == []
  end

  test "validates settings on save and again after provider disablement", %{owner: owner} do
    provider = register!(owner, "openai-codex", :codex, %{enabled: true})

    for attrs <- [
          %{models: %{"detector" => "openai-codex/no-such-model"}},
          %{models: %{"unknown" => @model}},
          %{thinking: %{"scorer" => "impossible"}}
        ] do
      assert {:error, _error} = defaults(owner, attrs)
    end

    defaults!(owner, %{models: %{"detector" => @model, "verifier" => @model}})
    assert {:ok, _settings} = Models.resolve_settings(owner.id)
    Provider.configure!(provider, %{enabled: false})
    assert {:error, _reason} = Models.resolve_settings(owner.id)
    assert {:error, _error} = defaults(owner, %{models: %{"detector" => @model}})

    assert {:error, :profile_must_be_separate} =
             Models.resolve_settings(owner.id, %{"profile" => "quiet"})
  end
end
