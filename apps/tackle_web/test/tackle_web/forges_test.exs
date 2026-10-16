defmodule Tackle.Web.ForgesTest do
  use Tackle.Web.DataCase, async: true

  import Tackle.Web.GitHubFixtures

  alias Ash.Resource.Info
  alias Tackle.Web.Forges.{ForgeApp, Installation, Repository}
  alias Tackle.Web.Forges.Repository.ValidateSettings
  alias Tackle.Web.Models.Provider
  alias Tackle.Web.Repo

  describe "ForgeApp" do
    test "stores secrets encrypted and decrypts them only on request" do
      forge_app_id = forge_app!(%{webhook_secret: "plain-webhook-secret"}).id

      {:ok, %{rows: [[private_key, webhook_secret]]}} =
        Repo.query(
          "select encrypted_private_key, encrypted_webhook_secret from forge_apps where id = $1",
          [Ecto.UUID.dump!(forge_app_id)]
        )

      refute String.contains?(private_key, "PRIVATE KEY")
      refute String.contains?(webhook_secret, "plain-webhook-secret")

      {:ok, read} = ForgeApp.get(:github)
      assert %Ash.NotLoaded{} = read.webhook_secret
      assert Ash.load!(read, :webhook_secret).webhook_secret == "plain-webhook-secret"
    end

    test "configuring again replaces the settings and secrets of the same row" do
      first = forge_app!()
      second = forge_app!(%{app_id: "99", webhook_secret: "rotated"})

      assert second.id == first.id
      {:ok, read} = ForgeApp.get(:github)
      assert read.app_id == "99"
      assert Ash.load!(read, :webhook_secret).webhook_secret == "rotated"
    end

    test "secrets are sensitive" do
      for field <- [:private_key, :webhook_secret, :client_secret] do
        assert Info.field(ForgeApp, field).sensitive?
      end
    end
  end

  describe "Installation.sync" do
    test "updates the account and status, but keeps the review defaults" do
      installation =
        installation!(%{review_new_repositories: true, default_auto_review: :on_open})

      synced = Installation.sync!(:github, installation.external_id, "renamed", :suspended)

      assert synced.id == installation.id
      assert synced.account == "renamed"
      assert synced.status == :suspended
      assert synced.review_new_repositories
      assert synced.default_auto_review == :on_open
    end
  end

  describe "Repository.sync" do
    test "a new repository takes the installation's defaults" do
      off = installation!()
      on = installation!(%{review_new_repositories: true, default_auto_review: :on_open_and_push})

      assert %{enabled: false, auto_review: :off} = repository!(off)
      assert %{enabled: true, auto_review: :on_open_and_push} = repository!(on)
    end

    test "a later sync updates the name and access, never the settings" do
      installation = installation!(%{review_new_repositories: true})
      repository = repository!(installation, %{auto_review: :on_open, profile: :assertive})
      Repository.deactivate!(repository)
      Installation.set_defaults!(installation, %{review_new_repositories: false})

      synced = Repository.sync!(installation.id, repository.external_id, "acme", "renamed")

      assert synced.id == repository.id
      assert synced.name == "renamed"
      assert synced.active
      assert synced.enabled
      assert synced.auto_review == :on_open
      assert synced.profile == :assertive
    end

    test "apply_installation_defaults resets enabled and auto_review" do
      installation = installation!()
      repository = repository!(installation, %{enabled: true, auto_review: :on_open})

      Installation.set_defaults!(installation, %{
        review_new_repositories: false,
        default_auto_review: :on_open_and_push
      })

      assert %{enabled: false, auto_review: :on_open_and_push} =
               Repository.apply_installation_defaults!(repository)
    end
  end

  describe "repository settings" do
    test "accepts review settings in their JSON form" do
      repository = repository!(installation!())

      Provider.register!("openrouter", :openrouter, %{enabled: true})

      settings = %{
        "thinking" => %{"detector" => "low"},
        "max_steps" => %{"verifier" => 4},
        "models" => %{"detector" => "openrouter/openai/gpt-6.1-sol"},
        "default_rules" => ["injection"]
      }

      assert %{settings: ^settings} = Repository.configure!(repository, %{settings: settings})
    end

    test "rejects profile, unknown fields, and invalid values" do
      repository = repository!(installation!())

      for {settings, message} <- [
            {%{"profile" => "quiet"}, "set the profile with the repository's profile"},
            {%{"models" => %{"detector" => "missing/gpt-6.1-sol"}}, "invalid review settings"},
            {%{"colour" => "blue"}, "is not valid review settings"},
            {%{"thinking" => %{"detector" => "enormous"}}, "is not valid review settings"},
            {%{"max_steps" => %{"detector" => 0}}, "is not valid review settings"},
            {%{"max_steps" => %{"scorer" => 3}}, "invalid review settings"},
            {%{"default_rules" => ["no-such-rule"]}, "unknown_default_rules"}
          ] do
        assert {:error, error} = Repository.configure(repository, %{settings: settings})
        assert Exception.message(error) =~ message
      end
    end

    test "check/1 rejects what is not an object" do
      assert ValidateSettings.check([]) == {:error, "must be a JSON object"}
      assert ValidateSettings.check(%{}) == :ok
    end
  end
end
