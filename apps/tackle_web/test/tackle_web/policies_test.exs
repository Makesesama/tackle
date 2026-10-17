defmodule Tackle.Web.PoliciesTest do
  @moduledoc """
  What the web interface may do: everything it runs passes the signed-in
  user as the actor, so these policies are its authorisation boundary
  (docs/TACKLE_WEB_PLAN.md §7.9, §7.12). Calls without an actor are trusted
  server code and are not authorised.
  """

  use Tackle.Web.DataCase, async: false

  import Tackle.Web.AccountsFixtures
  import Tackle.Web.GitHubFixtures

  require Ash.Query

  alias Tackle.Web.Accounts.User
  alias Tackle.Web.Forges.{Access, ForgeApp, Installation, Repository}
  alias Tackle.Web.Models.{Provider, ReviewDefaults}
  alias Tackle.Web.Repo
  alias Tackle.Web.Reviews.{Dismissal, Finding, ReviewRequest, ReviewRun}

  setup do
    forge_app!()
    admin = admin!()
    owner = user!()
    user = user!()
    installation = installation!(%{owner: owner})
    repository = repository!(installation)

    {:ok,
     admin: admin, owner: owner, user: user, installation: installation, repository: repository}
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

  # A request with a stored run and one finding.
  defp reviewed!(repository) do
    request = request!(repository)

    run =
      ReviewRun
      |> Ash.Changeset.for_create(:create, %{
        request_id: request.id,
        summary: %{},
        usage: %{},
        duration_ms: 1,
        verdict: :optional
      })
      |> Ash.create!()

    finding =
      Finding
      |> Ash.Changeset.for_create(:create, %{
        run_id: run.id,
        fingerprint: "fp",
        state: :shown,
        title: "A finding",
        category: :correctness,
        severity: :medium,
        blocking: false,
        confidence: 0.9,
        path: "lib/a.ex",
        side: :new,
        start_line: 1,
        end_line: 1,
        trigger: "always",
        body: "Body.",
        support: 1
      })
      |> Ash.create!()

    %{request: request, run: run, finding: finding}
  end

  defp ids(resource, actor) do
    resource |> Ash.read!(actor: actor) |> Enum.map(& &1.id) |> Enum.sort()
  end

  describe "reads" do
    test "owners read their installations and everything in them; others nothing", %{
      admin: admin,
      owner: owner,
      user: user,
      installation: installation,
      repository: repository
    } do
      %{request: request, run: run, finding: finding} = reviewed!(repository)
      other_installation = installation!(%{owner: user!()})
      %{request: other_request} = reviewed!(repository!(other_installation))

      assert ids(Installation, owner) == [installation.id]
      assert ids(Repository, owner) == [repository.id]
      assert ids(ReviewRequest, owner) == [request.id]
      assert ids(ReviewRun, owner) == [run.id]
      assert ids(Finding, owner) == [finding.id]

      for resource <- [Installation, Repository, ReviewRequest, ReviewRun, Finding] do
        assert ids(resource, user) == [], inspect(resource)
        assert {:ok, []} = Ash.read(resource, actor: nil, authorize?: true), inspect(resource)
      end

      # Admins read everything, for the admin interface.
      assert other_request.id in ids(ReviewRequest, admin)
      assert [_first, _second] = ids(Finding, admin)
    end

    test "a grant on one repository shows it and its reviews; one on the installation all of them",
         %{owner: owner, user: user, installation: installation, repository: repository} do
      other = repository!(installation)
      %{request: request, run: run, finding: finding} = reviewed!(repository)
      %{request: other_request} = reviewed!(other)
      grant!(installation, user, repository)

      assert ids(Installation, user) == [installation.id]
      assert ids(Repository, user) == [repository.id]
      assert ids(ReviewRequest, user) == [request.id]
      assert ids(ReviewRun, user) == [run.id]
      assert ids(Finding, user) == [finding.id]

      whole = user!()
      grant!(installation, whole)
      assert ids(Repository, whole) == Enum.sort([repository.id, other.id])
      assert ids(ReviewRequest, whole) == Enum.sort([request.id, other_request.id])

      # A repository added later is covered by the installation-wide grant.
      later = repository!(installation)
      assert later.id in ids(Repository, whole)
      refute later.id in ids(Repository, user)

      # Grants are matched by forge user id, not by login.
      assert ids(Repository, %{owner | external_id: user.external_id}) == [repository.id]
    end

    test "providers and review defaults are read by their owners and admins", %{
      admin: admin,
      owner: owner,
      user: user
    } do
      provider = Provider.register!("router", :openrouter, %{owner_id: owner.id})
      ReviewDefaults.configure!(%{user_id: owner.id, thinking: %{"detector" => "low"}})

      assert ids(Provider, owner) == [provider.id]
      assert ids(Provider, user) == []
      assert ids(Provider, admin) == [provider.id]
      assert [%{user_id: user_id}] = Ash.read!(ReviewDefaults, actor: owner)
      assert user_id == owner.id
      assert Ash.read!(ReviewDefaults, actor: user) == []
      assert [_defaults] = Ash.read!(ReviewDefaults, actor: admin)
    end

    test "users read only themselves, admins everyone; the forge app only admins", %{
      admin: admin,
      owner: owner,
      user: user
    } do
      assert ids(User, user) == [user.id]
      assert Enum.sort([admin.id, owner.id, user.id]) -- ids(User, admin) == []
      assert ids(ForgeApp, user) == []
      assert [_forge_app] = ids(ForgeApp, admin)
    end
  end

  test "trusted server code without an actor skips authorisation", %{repository: repository} do
    assert {:ok, _repository} = Repository.configure(repository, %{enabled: true})
    assert {:ok, _request} = ReviewRequest.skip(request!(repository), "test")
  end

  describe "settings" do
    test "the owner and admins change repositories and installations; grantees do not", %{
      admin: admin,
      owner: owner,
      user: user,
      installation: installation,
      repository: repository
    } do
      grant!(installation, user)

      for actor <- [user, user!()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Repository.configure(repository, %{enabled: true}, actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Repository.apply_installation_defaults(repository, actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Installation.set_defaults(installation, %{review_new_repositories: true},
                   actor: actor
                 )
      end

      for actor <- [owner, admin] do
        assert {:ok, %{enabled: true}} =
                 Repository.configure(repository, %{enabled: true}, actor: actor)

        assert {:ok, _repository} =
                 Repository.apply_installation_defaults(repository, actor: actor)

        assert {:ok, %{review_new_repositories: true}} =
                 Installation.set_defaults(installation, %{review_new_repositories: true},
                   actor: actor
                 )
      end
    end

    test "users register and change only their own providers and defaults", %{
      admin: admin,
      owner: owner,
      user: user
    } do
      # The owner is always the actor, whatever is given.
      assert {:ok, provider} =
               Provider.register("router", :openrouter, %{owner_id: user.id}, actor: owner)

      assert provider.owner_id == owner.id

      for actor <- [user, admin] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Provider.set_credentials(provider, "key", actor: actor)

        assert {:error, %Ash.Error.Forbidden{}} =
                 Provider.configure(provider, %{enabled: true}, actor: actor)
      end

      assert {:ok, _provider} = Provider.set_credentials(provider, "key", actor: owner)

      assert {:ok, %{enabled: true}} =
               Provider.configure(provider, %{enabled: true}, actor: owner)

      # Admins register providers for themselves, like everyone.
      assert {:ok, %{owner_id: admin_id}} =
               Provider.register("router", :openrouter, %{}, actor: admin)

      assert admin_id == admin.id

      assert {:ok, defaults} =
               ReviewDefaults.configure(
                 %{user_id: owner.id, thinking: %{"detector" => "low"}},
                 actor: user
               )

      assert defaults.user_id == user.id
      assert {:ok, nil} = ReviewDefaults.get(owner.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               ReviewDefaults.configure(%{user_id: owner.id, thinking: %{}},
                 actor: nil,
                 authorize?: true
               )
    end

    test "only admins set an installation's owner, to a user of its forge", %{
      admin: admin,
      owner: owner,
      user: user,
      installation: installation
    } do
      assert {:error, %Ash.Error.Forbidden{}} =
               Installation.set_owner(installation, user.id, actor: owner)

      assert {:ok, %{owner_external_id: external_id, owner_login: login}} =
               Installation.set_owner(installation, user.id, actor: admin)

      assert {external_id, login} == {user.external_id, user.login}

      assert {:error, %Ash.Error.Invalid{}} =
               Installation.set_owner(installation, Ecto.UUID.generate(), actor: admin)
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

  describe "grants" do
    test "only the owner grants; the owner and admins revoke; grantees read their own", %{
      admin: admin,
      owner: owner,
      user: user,
      installation: installation,
      repository: repository
    } do
      grantee = user!()
      stub_users([user, grantee])

      for actor <- [user, admin] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Access.grant(installation.id, grantee.login, %{}, actor: actor)
      end

      assert {:ok, access} =
               Access.grant(installation.id, grantee.login, %{repository_id: repository.id},
                 actor: owner
               )

      assert {access.forge_user_id, access.login, access.granted_by_id} ==
               {grantee.external_id, grantee.login, owner.id}

      # Granting again is a no-op.
      assert {:ok, %{id: id}} =
               Access.grant(installation.id, grantee.login, %{repository_id: repository.id},
                 actor: owner
               )

      assert id == access.id
      assert ids(Access, grantee) == [access.id]
      assert ids(Access, owner) == [access.id]
      assert ids(Access, user) == []
      assert ids(Access, admin) == [access.id]
      assert ids(Repository, grantee) == [repository.id]

      assert {:error, %Ash.Error.Forbidden{}} = Access.revoke(access, actor: grantee)
      assert :ok = Access.revoke(access, actor: owner)
      assert ids(Repository, grantee) == []

      other = grant!(installation, grantee)
      assert :ok = Access.revoke(other, actor: admin)
    end

    test "a grant needs a forge user and a repository of the installation", %{
      owner: owner,
      user: user,
      installation: installation
    } do
      stub_users([user])

      assert {:error, %Ash.Error.Invalid{}} =
               Access.grant(installation.id, "nobody", %{}, actor: owner)

      assert {:error, %Ash.Error.Invalid{}} =
               Access.grant(installation.id, "not a login", %{}, actor: owner)

      foreign = repository!(installation!(%{owner: owner}))

      assert {:error, %Ash.Error.Invalid{}} =
               Access.grant(installation.id, user.login, %{repository_id: foreign.id},
                 actor: owner
               )

      assert Ash.read!(Access) == []
    end

    test "an owner cannot grant on another owner's installation", %{
      user: user,
      repository: repository
    } do
      other_owner = user!()
      stub_users([user])

      assert {:error, %Ash.Error.Forbidden{}} =
               Access.grant(repository.installation_id, user.login, %{}, actor: other_owner)
    end
  end

  describe "dismissals" do
    test "the owner dismisses (as themselves, from the web) and restores; grantees read", %{
      admin: admin,
      owner: owner,
      user: user,
      installation: installation,
      repository: repository
    } do
      grant!(installation, user)

      for actor <- [user, admin, user!()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Dismissal.dismiss(repository.id, "fp", %{source: :forge, by: "x"}, actor: actor)
      end

      # Source and login are the actor's, whatever is given.
      assert {:ok, %{source: :web, by: by} = dismissal} =
               Dismissal.dismiss(repository.id, "fp", %{source: :forge, by: "someone"},
                 actor: owner
               )

      assert by == owner.login
      assert ids(Dismissal, user) == [dismissal.id]
      assert ids(Dismissal, user!()) == []
      assert {:error, %Ash.Error.Forbidden{}} = Dismissal.restore(dismissal, actor: user)
      assert :ok = Dismissal.restore(dismissal, actor: owner)

      again = Dismissal.dismiss!(repository.id, "fp", %{source: :forge, by: "ada"})
      assert :ok = Dismissal.restore(again, actor: admin)
    end

    test "an owner cannot dismiss in another owner's repository", %{owner: owner} do
      foreign = repository!(installation!(%{owner: user!()}))

      assert {:error, %Ash.Error.Forbidden{}} =
               Dismissal.dismiss(foreign.id, "fp", %{}, actor: owner)
    end
  end

  test "policies read the actor again: a revoked admin's or deleted user's old struct is refused",
       %{admin: admin, owner: owner, repository: repository} do
    # As an open page would still hold them.
    stale_admin = admin
    stale_owner = owner

    admin!()
    User.set_admin!(admin, false)

    assert {:error, %Ash.Error.Forbidden{}} =
             Repository.configure(repository, %{enabled: true}, actor: stale_admin)

    Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(owner.id)])
    assert {:ok, []} = Ash.read(Repository, actor: stale_owner)

    assert {:error, %Ash.Error.Forbidden{}} =
             Repository.configure(repository, %{enabled: true}, actor: stale_owner)
  end

  test "internal actions are refused even to admins and owners", %{
    admin: admin,
    owner: owner,
    repository: repository
  } do
    request = request!(repository)
    provider = Provider.register!("router", :openrouter, %{owner_id: owner.id})
    unowned = installation!()

    forbidden =
      for actor <- [admin, owner] do
        [
          fn -> Provider.store_credentials(provider, %{"api_key" => "x"}, actor: actor) end,
          fn -> ReviewRequest.skip(request, "no", actor: actor) end,
          fn ->
            request
            |> Ash.Changeset.for_update(:record_progress, %{status: :posted}, actor: actor)
            |> Ash.update()
          end,
          fn -> Repository.deactivate(repository, actor: actor) end,
          fn -> Repository.sync(repository.installation_id, "1", "acme", "x", actor: actor) end,
          fn -> Installation.sync(:github, "1", "acme", :active, actor: actor) end,
          fn -> Installation.record_owner(unowned, "1", "someone", actor: actor) end,
          fn ->
            ForgeApp.configure(
              :github,
              %{app_id: "1", private_key: "key", webhook_secret: "secret"},
              actor: actor
            )
          end,
          fn ->
            ReviewRun
            |> Ash.Changeset.for_create(
              :create,
              %{
                request_id: request.id,
                summary: %{},
                usage: %{},
                duration_ms: 0,
                verdict: :clean
              },
              actor: actor
            )
            |> Ash.create()
          end
        ]
      end

    for call <- List.flatten(forbidden) do
      assert {:error, %Ash.Error.Forbidden{}} = call.()
    end

    assert %{status: :pending} = Ash.get!(ReviewRequest, request.id)

    # A paid rerun stays a console action.
    finished = ReviewRequest.skip!(request, "done")
    assert {:error, %Ash.Error.Forbidden{}} = ReviewRequest.rerun(finished, %{}, actor: admin)
    assert %{status: :skipped} = Ash.get!(ReviewRequest, request.id)
  end

  test "secrets are never decrypted for an actor", %{admin: admin, owner: owner} do
    forge_app = forge_app!()
    provider = Provider.register!("router", :openrouter, %{owner_id: owner.id})
    Provider.set_credentials!(provider, "private-api-key")

    for actor <- [admin, owner] do
      assert {:error, %Ash.Error.Forbidden{}} = Ash.load(provider, :credentials, actor: actor)
    end

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
