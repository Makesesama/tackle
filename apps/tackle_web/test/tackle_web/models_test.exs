defmodule Tackle.Web.ModelsTest do
  use Tackle.Web.DataCase, async: true

  alias Ash.Resource.Info
  alias Tackle.Lib.CredentialStore, as: Store
  alias Tackle.Web.{CredentialStore, Models, Repo}
  alias Tackle.Web.Models.{Provider, ReviewDefaults}

  @model "openai-codex/gpt-6.1-sol"

  test "provider ids and adapters are constrained, settings are JSON, credentials are not accepted by configure" do
    for id <- ["Bad", "-bad", "bad-", "a/b", "a b"] do
      assert {:error, _error} = Provider.register(id, :codex)
    end

    assert {:error, _error} = Provider.register("custom", :unknown)
    assert {:error, _error} = Provider.register("custom", :codex, %{settings: %{atom: true}})
    provider = Provider.register!("custom", :codex)
    assert {:error, _error} = Provider.configure(provider, %{credentials: %{"token" => "no"}})
    assert {:error, _error} = Provider.configure(provider, %{adapter: :openrouter})
  end

  test "enabled providers use the allowlist, preserve settings and do not load secrets" do
    Provider.register!("disabled", :codex)

    Provider.register!("router", :openrouter, %{
      enabled: true,
      settings: %{"provider_routing" => %{"order" => ["test"]}}
    })

    assert {:ok, [provider]} = Models.enabled_providers()
    assert provider.id == "router"
    assert provider.adapter == Tackle.Plugins.OpenRouter
    assert provider.settings == %{"provider_routing" => %{"order" => ["test"]}}
  end

  test "OpenRouter key action encrypts and redacts secrets, and refuses Codex or empty keys" do
    provider = Provider.register!("router", :openrouter)
    Provider.set_credentials!(provider, "private-api-key")
    assert {:ok, read} = Provider.get("router")
    assert %Ash.NotLoaded{} = read.credentials
    assert Info.field(Provider, :credentials).sensitive?

    assert Info.action(Provider, :set_credentials).arguments
           |> hd()
           |> Map.fetch!(:sensitive?)

    {:ok, %{rows: [[ciphertext]]}} =
      Repo.query(
        "select encrypted_credentials from providers where id = $1",
        ["router"]
      )

    refute String.contains?(ciphertext, "private-api-key")

    assert Store.fetch(CredentialStore.handle(), "router") ==
             {:ok, %{"api_key" => "private-api-key"}}

    assert {:error, _error} = Provider.set_credentials(provider, "   ")
    codex = Provider.register!("codex", :codex)
    assert {:error, _error} = Provider.set_credentials(codex, "key")
  end

  test "stable DB handle reads fresh credentials; put/delete are transactional and never create providers" do
    handle = CredentialStore.handle()
    assert handle == {CredentialStore, :default}
    assert Store.fetch(handle, "missing") == :error
    assert Store.put(handle, "missing", %{}) == {:error, {:unknown_provider, "missing"}}
    assert Store.delete(handle, "missing") == :ok
    provider = Provider.register!("codex", :codex)
    assert Store.fetch(handle, provider.id) == :error
    assert Store.put(handle, provider.id, %{"refresh_token" => "old"}) == :ok

    assert Store.put(CredentialStore.handle(), provider.id, %{"refresh_token" => "rotated"}) ==
             :ok

    assert Store.fetch(handle, provider.id) == {:ok, %{"refresh_token" => "rotated"}}

    for invalid <- [%{"not-json" => self()}, %{"invalid-utf8" => <<255>>}, %{atom: "key"}] do
      assert {:error, _error} = Store.put(handle, provider.id, invalid)
    end

    assert Store.fetch(handle, provider.id) == {:ok, %{"refresh_token" => "rotated"}}

    assert {:error, :test_rollback} =
             Repo.transaction(fn ->
               :ok = Store.put(handle, provider.id, %{"refresh_token" => "rolled-back"})
               Repo.rollback(:test_rollback)
             end)

    assert Store.fetch(handle, provider.id) == {:ok, %{"refresh_token" => "rotated"}}
    assert Store.delete(handle, provider.id) == :ok
    assert Store.delete(handle, provider.id) == :ok
    assert Store.fetch(handle, provider.id) == :error
  end

  test "metadata updates cannot overwrite a refreshed credential, and empty maps remain stored" do
    stale = Provider.register!("codex", :codex)
    :ok = Store.put(CredentialStore.handle(), stale.id, %{"refresh_token" => "fresh"})
    Provider.configure!(stale, %{enabled: true, settings: %{"option" => true}})
    assert Store.fetch(CredentialStore.handle(), stale.id) == {:ok, %{"refresh_token" => "fresh"}}
    Provider.store_credentials!(stale, %{})
    assert Store.fetch(CredentialStore.handle(), stale.id) == {:ok, %{}}
    {:ok, read} = Provider.get(stale.id)
    assert read.settings == %{"option" => true}
    assert read.enabled
  end

  test "repository stage models can supply all required models without a default row" do
    Provider.register!("openai-codex", :codex, %{enabled: true})

    assert {:ok, settings} =
             Models.resolve_settings(%{
               "models" => %{"detector" => @model, "verifier" => @model, "scorer" => @model}
             })

    assert settings.models.scorer == @model
    assert settings.thinking == %{}
    assert settings.max_steps == %{}
  end

  test "no implicit models; defaults are a singleton, with repository per-stage precedence" do
    assert {:error, {:missing_review_models, [:detector, :verifier]}} = Models.resolve_settings()
    Provider.register!("openai-codex", :codex, %{enabled: true})
    first = ReviewDefaults.configure!(%{models: %{"detector" => @model}})
    assert {:error, {:missing_review_models, [:verifier]}} = Models.resolve_settings()

    second =
      ReviewDefaults.configure!(%{
        models: %{"detector" => @model, "verifier" => @model},
        thinking: %{"detector" => "low", "verifier" => "medium"}
      })

    assert second.id == first.id
    assert [_defaults] = Ash.read!(ReviewDefaults)

    assert {:ok, settings} =
             Models.resolve_settings(
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

  test "validates settings on save and again after provider disablement" do
    provider = Provider.register!("openai-codex", :codex, %{enabled: true})

    for attrs <- [
          %{models: %{"detector" => "openai-codex/no-such-model"}},
          %{models: %{"unknown" => @model}},
          %{thinking: %{"scorer" => "impossible"}}
        ] do
      assert {:error, _error} = ReviewDefaults.configure(attrs)
    end

    ReviewDefaults.configure!(%{models: %{"detector" => @model, "verifier" => @model}})
    assert {:ok, _settings} = Models.resolve_settings()
    Provider.configure!(provider, %{enabled: false})
    assert {:error, _reason} = Models.resolve_settings()
    assert {:error, _error} = ReviewDefaults.configure(%{models: %{"detector" => @model}})
    assert {:error, :profile_must_be_separate} = Models.resolve_settings(%{"profile" => "quiet"})
  end
end
