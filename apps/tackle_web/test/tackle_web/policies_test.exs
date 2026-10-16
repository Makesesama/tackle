defmodule Tackle.Web.PoliciesTest do
  @moduledoc """
  What the web interface may do: everything it runs passes the signed-in
  user as the actor, so these policies are its authorisation boundary.
  Calls without an actor are trusted server code and are not authorised.
  """

  use Tackle.Web.DataCase, async: false

  import Tackle.Web.AccountsFixtures
  import Tackle.Web.GitHubFixtures

  require Ash.Query

  alias Tackle.Web.Accounts.User
  alias Tackle.Web.Forges.{ForgeApp, Installation, Repository}
  alias Tackle.Web.Models.{Provider, ReviewDefaults}
  alias Tackle.Web.Repo
  alias Tackle.Web.Reviews.{Finding, ReviewRequest, ReviewRun}

  setup do
    admin = admin!()
    user = user!()
    installation = installation!()
    repository = repository!(installation)
    {:ok, admin: admin, user: user, installation: installation, repository: repository}
  end

  defp request!(repository) do
    ReviewRequest.request!(%{
      repository_id: repository.id,
      pull_number: 7,
      head_sha: sha("head"),
      base_sha: sha("base"),
      base_ref: "main",
      trigger: :command,
      profile: :default
    })
  end

  # Reads that a policy forbids are filtered to nothing rather than failing
  # (`no_filter_static_forbidden_reads?: false` in config/ash.exs).
  test "signed-in users read every resource; reads with authorisation but no actor see nothing",
       %{user: user, repository: repository} do
    forge_app!()
    Provider.register!("router", :openrouter)
    ReviewDefaults.configure!(%{thinking: %{"detector" => "low"}})
    request!(repository)

    for resource <- [ForgeApp, Installation, Repository, Provider, ReviewDefaults, ReviewRequest] do
      assert {:ok, [_ | _]} = Ash.read(resource, actor: user), inspect(resource)
      assert {:ok, []} = Ash.read(resource, actor: nil, authorize?: true), inspect(resource)
    end

    for resource <- [ReviewRun, Finding] do
      assert {:ok, []} = Ash.read(resource, actor: user), inspect(resource)
    end
  end

  test "trusted server code without an actor is not authorised", %{repository: repository} do
    assert {:ok, _repository} = Repository.configure(repository, %{enabled: true})
    assert {:ok, _request} = ReviewRequest.skip(request!(repository), "test")
  end

  describe "settings" do
    test "only admins change repositories and installations", %{
      admin: admin,
      user: user,
      installation: installation,
      repository: repository
    } do
      assert {:error, %Ash.Error.Forbidden{}} =
               Repository.configure(repository, %{enabled: true}, actor: user)

      assert {:error, %Ash.Error.Forbidden{}} =
               Installation.set_defaults(installation, %{review_new_repositories: true},
                 actor: user
               )

      assert {:ok, %{enabled: true}} =
               Repository.configure(repository, %{enabled: true}, actor: admin)

      assert {:ok, _repository} = Repository.apply_installation_defaults(repository, actor: admin)

      assert {:ok, %{review_new_repositories: true}} =
               Installation.set_defaults(installation, %{review_new_repositories: true},
                 actor: admin
               )
    end

    test "only admins register and configure providers and set API keys", %{
      admin: admin,
      user: user
    } do
      assert {:error, %Ash.Error.Forbidden{}} =
               Provider.register("router", :openrouter, %{}, actor: user)

      assert {:ok, provider} = Provider.register("router", :openrouter, %{}, actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Provider.set_credentials(provider, "key", actor: user)

      assert {:ok, provider} = Provider.set_credentials(provider, "key", actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               Provider.configure(provider, %{enabled: true}, actor: user)

      assert {:ok, %{enabled: true}} =
               Provider.configure(provider, %{enabled: true}, actor: admin)

      assert {:error, %Ash.Error.Forbidden{}} =
               ReviewDefaults.configure(%{thinking: %{"detector" => "low"}}, actor: user)

      assert {:ok, _defaults} =
               ReviewDefaults.configure(%{thinking: %{"detector" => "low"}}, actor: admin)
    end

    test "set_defaults can apply the new defaults to the existing repositories", %{
      admin: admin,
      installation: installation,
      repository: repository
    } do
      other = repository!(installation)
      unrelated = repository!(installation!())

      Installation.set_defaults!(
        installation,
        %{
          review_new_repositories: true,
          default_auto_review: :on_open,
          apply_to_repositories: true
        },
        actor: admin
      )

      for repo <- [repository, other] do
        assert %{enabled: true, auto_review: :on_open} = Ash.get!(Repository, repo.id)
      end

      assert %{enabled: false, auto_review: :off} = Ash.get!(Repository, unrelated.id)

      # Without the argument, existing repositories keep their settings.
      Installation.set_defaults!(installation, %{default_auto_review: :off}, actor: admin)
      assert %{auto_review: :on_open} = Ash.get!(Repository, repository.id)
    end
  end

  test "policies read the actor again: a revoked admin's or deleted user's old struct is refused",
       %{admin: admin, user: user, repository: repository} do
    # As an open page would still hold them.
    stale_admin = admin
    stale_user = user

    User.set_admin!(admin, false)

    assert {:error, %Ash.Error.Forbidden{}} =
             Repository.configure(repository, %{enabled: true}, actor: stale_admin)

    Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
    assert {:ok, []} = Ash.read(Repository, actor: stale_user)
  end

  test "internal actions are refused even to admins", %{admin: admin, repository: repository} do
    request = request!(repository)
    provider = Provider.register!("router", :openrouter)

    forbidden = [
      fn -> Provider.store_credentials(provider, %{"api_key" => "x"}, actor: admin) end,
      fn -> ReviewRequest.skip(request, "no", actor: admin) end,
      fn ->
        request
        |> Ash.Changeset.for_update(:record_progress, %{status: :posted}, actor: admin)
        |> Ash.update()
      end,
      fn -> Repository.deactivate(repository, actor: admin) end,
      fn -> Repository.sync(repository.installation_id, "1", "acme", "x", actor: admin) end,
      fn -> Installation.sync(:github, "1", "acme", :active, actor: admin) end,
      fn ->
        ForgeApp.configure(
          :github,
          %{app_id: "1", private_key: "key", webhook_secret: "secret"},
          actor: admin
        )
      end,
      fn ->
        ReviewRun
        |> Ash.Changeset.for_create(
          :create,
          %{request_id: request.id, summary: %{}, usage: %{}, duration_ms: 0, verdict: :clean},
          actor: admin
        )
        |> Ash.create()
      end
    ]

    for call <- forbidden do
      assert {:error, %Ash.Error.Forbidden{}} = call.()
    end

    assert %{status: :pending} = Ash.get!(ReviewRequest, request.id)

    # A paid rerun stays a console action.
    finished = ReviewRequest.skip!(request, "done")
    assert {:error, %Ash.Error.Forbidden{}} = ReviewRequest.rerun(finished, %{}, actor: admin)
    assert %{status: :skipped} = Ash.get!(ReviewRequest, request.id)
  end

  test "secrets are never decrypted for an actor", %{admin: admin} do
    forge_app = forge_app!()
    provider = Provider.register!("router", :openrouter)
    Provider.set_credentials!(provider, "private-api-key")

    assert {:error, %Ash.Error.Forbidden{}} = Ash.load(provider, :credentials, actor: admin)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.load(forge_app, [:private_key, :client_secret], actor: admin)

    # Trusted server code still decrypts them.
    assert %{credentials: %{"api_key" => "private-api-key"}} = Ash.load!(provider, :credentials)
    assert %{client_secret: "test-client-secret"} = Ash.load!(forge_app, :client_secret)
  end

  test "AshOban's scheduler still reads requests under authorisation", %{repository: repository} do
    request = request!(repository)

    assert [%{id: id}] =
             ReviewRequest
             |> Ash.Query.filter(id == ^request.id)
             |> Ash.Query.set_context(%{private: %{ash_oban?: true}})
             |> Ash.read!(authorize?: true, actor: nil)

    assert id == request.id
  end
end
