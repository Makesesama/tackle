defmodule Tackle.Web.PagesTest do
  @moduledoc """
  The signed-in pages (phase 8): who sees what on the HTTP render, and the
  pages' events, called directly on a socket. (`Phoenix.LiveViewTest`
  needs the `lazy_html` package, which is not a dependency.)
  """

  use Tackle.Web.ConnCase, async: false

  import Tackle.Web.AccountsFixtures
  import Tackle.Web.GitHubFixtures

  alias Phoenix.HTML.Safe
  alias Phoenix.LiveView.Socket
  alias Tackle.Lib.CredentialStore, as: Credentials
  alias Tackle.Plugins.Codex
  alias Tackle.Web.Forge.GitHub
  alias Tackle.Web.Forges.{Access, Installation, Repository}
  alias Tackle.Web.Models.{Provider, ReviewDefaults}
  alias Tackle.Web.ReviewJob.Store
  alias Tackle.Web.Reviews.{Dismissal, Finding, ReviewRequest, ReviewRun}

  alias Tackle.Web.{
    CodexLoginLive,
    CredentialStore,
    GrantsComponent,
    InstallationLive,
    Live,
    RepositoryLive,
    ReposLive,
    ReviewLive,
    ReviewProgress,
    ReviewRequestComponent,
    SettingsLive,
    Triggers,
    Updates
  }

  setup do
    forge_app!()
    owner = user!(%{login: "olivia"})
    installation = installation!(%{account: "acme", owner: owner})
    repository = repository!(installation, %{enabled: true, auto_review: :on_open})
    %{owner: owner, installation: installation, repository: repository}
  end

  defp request!(repository, attrs \\ %{}) do
    ReviewRequest.request!(
      Map.merge(
        %{
          repository_id: repository.id,
          pull_number: 42,
          title: "Add widgets",
          head_sha: sha("head-#{System.unique_integer()}"),
          base_sha: sha("base"),
          base_ref: "main",
          trigger: :command,
          profile: :default,
          requested_by: "olivia"
        },
        attrs
      )
    )
  end

  defp run!(request, findings) do
    run =
      ReviewRun
      |> Ash.Changeset.for_create(:create, %{
        request_id: request.id,
        summary: %{},
        usage: %{"total_tokens" => 1234},
        duration_ms: 65_000,
        verdict: :blocking
      })
      |> Ash.create!()

    for {state, title, body} <- findings do
      Finding
      |> Ash.Changeset.for_create(:create, %{
        run_id: run.id,
        fingerprint: title,
        state: state,
        title: title,
        category: :security,
        severity: :high,
        blocking: state == :shown,
        confidence: 0.9,
        path: "lib/widgets.ex",
        side: :new,
        start_line: 3,
        end_line: 5,
        trigger: "always",
        body: body,
        support: 1
      })
      |> Ash.create!()
    end

    run
  end

  # A socket as the `:require_user` hook leaves it.
  defp socket(user) do
    %Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        signed_in_at: System.os_time(:second)
      }
    }
  end

  defp page(conn, user, path), do: conn |> sign_in(user) |> get(path)

  describe "the start page" do
    test "shows the logo and sign-in; signed-in users go to their repositories", %{
      conn: conn,
      owner: owner
    } do
      html = conn |> get("/") |> html_response(200)
      assert html =~ ~s(src="/assets/logo.svg")
      assert html =~ "Sign in with GitHub"

      assert redirected_to(page(build_conn(), owner, "/"), 302) == "/repos"
    end

    test "the logo is served, and as a PNG for the GitHub App", %{conn: conn} do
      assert conn |> get("/assets/logo.svg") |> response(200) =~ "<svg"

      assert <<137, "PNG", _rest::binary>> =
               build_conn() |> get("/assets/logo.png") |> response(200)
    end

    test "every user page needs a sign-in", %{conn: conn, repository: repository} do
      for path <- ["/repos", "/repos/#{repository.id}", "/settings", "/codex-login"] do
        assert redirected_to(get(conn, path), 302) == "/"
      end
    end
  end

  describe "/repos" do
    test "the owner sees their installation, repositories, and latest reviews", %{
      conn: conn,
      owner: owner,
      repository: repository
    } do
      request!(repository)
      html = conn |> page(owner, "/repos") |> html_response(200)

      assert html =~ "acme"
      assert html =~ "Yours"
      assert html =~ ~s(href="/repos/#{repository.id}")
      assert html =~ "New pull requests"
      assert html =~ "Queued"
      assert html =~ "#42 Add widgets"
      assert html =~ "olivia"
    end

    test "a grantee sees only what was granted; others and admins see only their own", %{
      conn: conn,
      installation: installation,
      repository: repository
    } do
      hidden = repository!(installation)
      Repository.configure!(hidden, %{})
      grantee = user!()
      grant!(installation, grantee, repository)

      html = conn |> page(grantee, "/repos") |> html_response(200)
      assert html =~ "Shared with you"
      assert html =~ ~s(href="/repos/#{repository.id}")
      refute html =~ ~s(href="/repos/#{hidden.id}")
      refute html =~ ~s(href="/installations/)

      for user <- [user!(), admin!()] do
        html = build_conn() |> page(user, "/repos") |> html_response(200)
        assert html =~ "No repositories yet"
        refute html =~ repository.id
      end
    end

    test "a checklist says what the owner's reviews still need, until they can run", %{
      conn: conn,
      owner: owner,
      repository: repository
    } do
      html = conn |> page(owner, "/repos") |> html_response(200)
      assert html =~ "Getting started"

      assert steps(owner) == %{install: true, provider: false, models: false, review: false}

      # A connected Codex provider is enabled with its first credentials.
      Provider.register!("openai-codex", :codex, %{owner_id: owner.id})
      :ok = Credentials.put(CredentialStore.handle(owner.id), "openai-codex", %{"token" => "t"})
      assert %{provider: true, models: false} = steps(owner)

      model = "openai-codex/" <> hd(Codex.models())

      ReviewDefaults.configure!(%{
        user_id: owner.id,
        models: %{"detector" => model, "verifier" => model}
      })

      assert %{provider: true, models: true, review: false} = steps(owner)

      request!(repository)
      {:ok, socket} = ReposLive.mount(%{}, %{}, socket(owner))
      assert socket.assigns.steps == []
      refute build_conn() |> page(owner, "/repos") |> html_response(200) =~ "Getting started"
    end

    test "users without installations get the checklist; those only given access do not", %{
      conn: conn,
      installation: installation
    } do
      newcomer = user!()
      html = conn |> page(newcomer, "/repos") |> html_response(200)
      assert html =~ "Getting started"
      assert html =~ "No repositories yet"
      assert %{install: false} = steps(newcomer)

      grantee = user!()
      grant!(installation, grantee)
      {:ok, socket} = ReposLive.mount(%{}, %{}, socket(grantee))
      assert socket.assigns.steps == []
    end

    test "admins get the sync button", %{conn: conn} do
      assert conn |> page(admin!(), "/repos") |> html_response(200) =~ ~s(action="/setup/sync")
      refute build_conn() |> page(user!(), "/repos") |> html_response(200) =~ "/setup/sync"
    end
  end

  defp steps(user) do
    {:ok, socket} = ReposLive.mount(%{}, %{}, socket(user))
    Map.new(socket.assigns.steps, &{&1.id, &1.done})
  end

  describe "/repos/:id" do
    test "the owner sees the reviews, the settings, and access", %{
      conn: conn,
      owner: owner,
      repository: repository
    } do
      request!(repository)
      html = conn |> page(owner, "/repos/#{repository.id}") |> html_response(200)

      assert html =~ "acme/widgets"
      assert html =~ "#42 Add widgets"
      assert html =~ "Review settings (JSON)"
      assert html =~ "Give access"
      assert html =~ ~s(/acme/widgets")
      assert html =~ ~s(name="pull_number")
    end

    test "a grantee reads it without settings; others are sent away; a crafted save is ignored",
         %{
           conn: conn,
           installation: installation,
           repository: repository
         } do
      grantee = user!()
      grant!(installation, grantee, repository)

      html = conn |> page(grantee, "/repos/#{repository.id}") |> html_response(200)
      assert html =~ "acme/widgets"
      refute html =~ "Review settings"
      refute html =~ "Give access"
      refute html =~ ~s(name="pull_number")

      assert redirected_to(page(build_conn(), user!(), "/repos/#{repository.id}"), 302) ==
               "/repos"

      # Admins read every repository (they reach it from the admin interface).
      assert build_conn() |> page(admin!(), "/repos/#{repository.id}") |> html_response(200)

      assert redirected_to(page(build_conn(), grantee, "/repos/not-a-uuid"), 302) == "/repos"

      {:ok, socket} = RepositoryLive.mount(%{"id" => repository.id}, %{}, socket(grantee))
      params = %{"form" => %{"enabled" => "false"}}
      assert {:noreply, ^socket} = RepositoryLive.handle_event("save", params, socket)
      assert %{enabled: true} = Ash.get!(Repository, repository.id)
    end

    test "the owner saves settings; JSON is checked", %{owner: owner, repository: repository} do
      {:ok, socket} = RepositoryLive.mount(%{"id" => repository.id}, %{}, socket(owner))

      params = %{
        "enabled" => "true",
        "auto_review" => "on_open_and_push",
        "auto_review_drafts" => "true",
        "auto_review_forks" => "false",
        "profile" => "quiet",
        "daily_token_budget" => "",
        "settings" => ~s({"default_rules": []})
      }

      assert {:noreply, saved} = RepositoryLive.handle_event("save", %{"form" => params}, socket)
      assert saved.assigns.flash["info"] == "Settings saved."

      assert %{
               auto_review: :on_open_and_push,
               auto_review_drafts: true,
               profile: :quiet,
               daily_token_budget: nil,
               settings: %{"default_rules" => []}
             } = Ash.get!(Repository, repository.id)

      invalid = Map.put(params, "settings", "{not json")

      assert {:noreply, failed} =
               RepositoryLive.handle_event("save", %{"form" => invalid}, saved)

      assert failed.assigns.form[:settings].errors != []
      assert %{settings: %{"default_rules" => []}} = Ash.get!(Repository, repository.id)
    end

    test "a page left open stops at the next event once the sign-in expired", %{
      owner: owner,
      repository: repository
    } do
      {:ok, socket} = RepositoryLive.mount(%{"id" => repository.id}, %{}, socket(owner))
      expired = put_in(socket.assigns.signed_in_at, 0)

      assert {:noreply, %Socket{redirected: {:redirect, %{to: "/"}}}} =
               RepositoryLive.handle_event("save", %{"form" => %{}}, expired)
    end
  end

  describe "requesting reviews" do
    defp request_component(user, repository, attrs \\ %{}) do
      {:ok, socket} =
        ReviewRequestComponent.update(
          Map.merge(
            %{
              id: "review-request",
              label: "Review",
              repository: repository,
              current_user: user,
              signed_in_at: System.os_time(:second)
            },
            attrs
          ),
          %Socket{assigns: %{__changed__: %{}, flash: %{}, myself: nil}}
        )

      socket
    end

    # The token request, the owner's permission, and pull request 42.
    defp stub_pull_request(owner, permission, state \\ "open") do
      expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      Req.Test.stub(GitHub, fn conn ->
        case conn.request_path do
          "/app/installations/" <> _rest ->
            Req.Test.json(conn, %{"token" => "ghs_test", "expires_at" => expires_at})

          "/repos/acme/widgets/collaborators/" <> rest ->
            assert rest == "#{owner.login}/permission"
            Req.Test.json(conn, %{"permission" => permission})

          "/repos/acme/widgets/pulls/42" ->
            repo = %{"id" => 1}

            Req.Test.json(conn, %{
              "number" => 42,
              "title" => "Add widgets",
              "state" => state,
              "draft" => false,
              "head" => %{"sha" => sha("web-head"), "repo" => repo},
              "base" => %{"sha" => sha("base"), "ref" => "main", "repo" => repo}
            })
        end
      end)
    end

    # The event, then the result of its async task, run here.
    defp request_review(socket, user, repository, params) do
      {:noreply, busy} = ReviewRequestComponent.handle_event("request", params, socket)
      assert busy.assigns.busy

      profile =
        if params["profile"] in [nil, ""],
          do: nil,
          else: String.to_existing_atom(params["profile"])

      number = socket.assigns.pull_number || String.to_integer(params["pull_number"])
      result = Triggers.owner_command(user, repository, number, profile)

      {:noreply, done} =
        ReviewRequestComponent.handle_async(:request, {:ok, {number, result}}, busy)

      refute done.assigns.busy
      done
    end

    test "the owner requests a review of a pull request and is sent to it", %{
      owner: owner,
      repository: repository
    } do
      stub_pull_request(owner, "write")
      socket = request_component(owner, repository)

      done = request_review(socket, owner, repository, %{"pull_number" => "42", "profile" => ""})

      assert {:ok, %ReviewRequest{id: id, requested_by: "olivia", trigger: :command}} =
               ReviewRequest.get_head(repository.id, 42, sha("web-head"))

      assert {:live, :redirect, %{to: to}} = done.redirected
      assert to == "/reviews/#{id}"
      assert done.assigns.flash["info"] =~ "Reviewing #42"

      # Again with the same profile: already reviewed once it is posted.
      ReviewRequest
      |> Ash.get!(id)
      |> Ash.Changeset.for_update(:record_progress, %{status: :posted})
      |> Ash.update!()

      again = request_review(socket, owner, repository, %{"pull_number" => "42", "profile" => ""})
      assert {:reviewed, %{id: ^id}} = again.assigns.notice
      assert again.redirected == nil
    end

    test "says why nothing was requested", %{owner: owner, repository: repository} do
      socket = request_component(owner, repository)

      {:noreply, invalid} =
        ReviewRequestComponent.handle_event("request", %{"pull_number" => "x"}, socket)

      assert invalid.assigns.notice == "Enter the number of a pull request."
      refute invalid.assigns.busy

      stub_pull_request(owner, "read")
      denied = request_review(socket, owner, repository, %{"pull_number" => "42"})
      assert denied.assigns.notice =~ "no write access"

      stub_pull_request(owner, "admin", "closed")
      closed = request_review(socket, owner, repository, %{"pull_number" => "42"})
      assert closed.assigns.notice == "Pull request #42 is closed."

      # Someone else, even when the form is sent anyway.
      other = user!()

      refused =
        request_review(request_component(other, repository), other, repository, %{
          "pull_number" => "42"
        })

      assert refused.assigns.notice =~ "Only the installation's owner"
      assert {:ok, nil} = ReviewRequest.get_head(repository.id, 42, sha("web-head"))
    end

    test "the review page reviews its pull request again; only the owner sees it", %{
      conn: conn,
      owner: owner,
      installation: installation,
      repository: repository
    } do
      request = request!(repository)
      html = conn |> page(owner, "/reviews/#{request.id}") |> html_response(200)
      assert html =~ "Review again"
      refute html =~ ~s(name="pull_number")

      grantee = user!()
      grant!(installation, grantee)

      refute build_conn() |> page(grantee, "/reviews/#{request.id}") |> html_response(200) =~
               "Review again"

      stub_pull_request(owner, "write")
      socket = request_component(owner, repository, %{pull_number: 42, label: "Review again"})
      done = request_review(socket, owner, repository, %{"profile" => "assertive"})

      assert {:ok, %{profile: :assertive}} =
               ReviewRequest.get_head(repository.id, 42, sha("web-head"))

      assert {:live, :redirect, _to} = done.redirected
    end

    test "the owner retries posting a review whose posting failed", %{
      conn: conn,
      owner: owner,
      installation: installation,
      repository: repository
    } do
      request = request!(repository)
      run!(request, [{:shown, "Injection in widgets", "Body."}])

      request
      |> Ash.Changeset.for_update(:record_progress, %{
        status: :failed,
        error: Store.posting_error()
      })
      |> Ash.update!()

      html = conn |> page(owner, "/reviews/#{request.id}") |> html_response(200)
      assert html =~ "Retry posting"

      grantee = user!()
      grant!(installation, grantee)
      {:ok, theirs} = ReviewLive.mount(%{"id" => request.id}, %{}, socket(grantee))
      {:noreply, refused} = ReviewLive.handle_event("retry_posting", %{}, theirs)
      assert refused.assigns.flash["error"]
      assert %{status: :failed} = Ash.get!(ReviewRequest, request.id)

      {:ok, socket} = ReviewLive.mount(%{"id" => request.id}, %{}, socket(owner))
      {:noreply, retried} = ReviewLive.handle_event("retry_posting", %{}, socket)
      assert retried.assigns.flash["info"] =~ "Posting again"
      assert %{status: :reviewed, error: nil} = retried.assigns.request
    end
  end

  describe "grants" do
    defp component(user, installation, repository) do
      {:ok, socket} =
        GrantsComponent.update(
          %{
            id: "grants",
            installation: installation,
            repository: repository,
            current_user: user,
            signed_in_at: System.os_time(:second)
          },
          %Socket{assigns: %{__changed__: %{}, flash: %{}, myself: nil}}
        )

      socket
    end

    test "the owner grants a login access and revokes it", %{
      owner: owner,
      installation: installation,
      repository: repository
    } do
      grantee = user!()
      stub_users([grantee])
      socket = component(owner, installation, repository)

      assert {:noreply, granted} =
               GrantsComponent.handle_event(
                 "grant",
                 %{"form" => %{"login" => grantee.login, "scope" => "repository"}},
                 socket
               )

      assert [%{login: login, repository_id: repository_id} = access] = granted.assigns.grants
      assert {login, repository_id} == {grantee.login, repository.id}
      assert granted.assigns.notice =~ "can now see it"

      assert {:noreply, revoked} =
               GrantsComponent.handle_event("revoke", %{"id" => access.id}, granted)

      assert revoked.assigns.grants == []
      assert Ash.read!(Access) == []
    end

    test "the whole installation, unknown logins, and someone else's installation", %{
      owner: owner,
      installation: installation,
      repository: repository
    } do
      grantee = user!()
      stub_users([grantee])
      socket = component(owner, installation, repository)

      {:noreply, socket} =
        GrantsComponent.handle_event(
          "grant",
          %{"form" => %{"login" => grantee.login, "scope" => "installation"}},
          socket
        )

      assert [%{repository_id: nil}] = socket.assigns.grants

      {:noreply, failed} =
        GrantsComponent.handle_event("grant", %{"form" => %{"login" => "nobody"}}, socket)

      assert [_error | _] = failed.assigns.form[:login].errors

      # Not the owner: the policies refuse, whatever the page shows.
      other = component(user!(), installation, repository)

      {:noreply, refused} =
        GrantsComponent.handle_event("grant", %{"form" => %{"login" => grantee.login}}, other)

      assert refused.assigns.notice == "Only the installation's owner gives access."
      assert [_one] = Ash.read!(Access)
    end
  end

  describe "/reviews/:id" do
    test "shows the run and its findings as text, posted ones first", %{
      conn: conn,
      owner: owner,
      repository: repository
    } do
      request = request!(repository)

      run!(request, [
        {:shown, "Injection in widgets", "Unescaped <script>alert(1)</script> input."},
        {:rejected, "A false alarm", "Not a problem."}
      ])

      html = conn |> page(owner, "/reviews/#{request.id}") |> html_response(200)

      assert html =~ "Injection in widgets"
      assert html =~ "Unescaped &lt;script&gt;alert(1)&lt;/script&gt; input."
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "Posted on the pull request"
      assert html =~ "Rejected by verification"
      assert html =~ "lib/widgets.ex:3–5"
      assert html =~ "Blocking"
      assert html =~ "1 min 5 s"
      assert html =~ "1234"
      assert html =~ "/acme/widgets/pull/42"

      {shown, rejected} =
        :binary.match(html, "Posted on the pull request")
        |> elem(0)
        |> then(&{&1, html |> :binary.match("Rejected by verification") |> elem(0)})

      assert shown < rejected
    end

    test "is hidden from users without access", %{conn: conn, repository: repository} do
      request = request!(repository)
      assert redirected_to(page(conn, user!(), "/reviews/#{request.id}"), 302) == "/repos"
    end

    test "a queued review says so", %{owner: owner, repository: repository} do
      request = request!(repository)
      {:ok, socket} = ReviewLive.mount(%{"id" => request.id}, %{}, socket(owner))
      assert socket.assigns.run == nil
      assert socket.assigns.request.status == :pending
    end
  end

  describe "feedback on the pages" do
    test "the owner dismisses a finding on the review page and restores it on the repository's",
         %{owner: owner, repository: repository} do
      request = request!(repository)
      run!(request, [{:shown, "Injection in widgets", "Body."}])
      {:ok, socket} = ReviewLive.mount(%{"id" => request.id}, %{}, socket(owner))
      [finding] = socket.assigns.run.findings

      {:noreply, socket} = ReviewLive.handle_event("dismiss", %{"id" => finding.id}, socket)
      assert socket.assigns.flash["info"] =~ "Dismissed"
      assert %{source: :web, by: "olivia"} = socket.assigns.dismissed[finding.fingerprint]

      html = build_conn() |> page(owner, "/repos/#{repository.id}") |> html_response(200)
      assert html =~ "Dismissed findings"
      assert html =~ "Injection in widgets"

      {:ok, repo_socket} = RepositoryLive.mount(%{"id" => repository.id}, %{}, socket(owner))
      [dismissal] = repo_socket.assigns.dismissals

      {:noreply, repo_socket} =
        RepositoryLive.handle_event("restore", %{"id" => dismissal.id}, repo_socket)

      assert repo_socket.assigns.dismissals == []
      assert Ash.read!(Dismissal) == []

      # A finding id from elsewhere is not on the page.
      {:noreply, refused} =
        ReviewLive.handle_event("dismiss", %{"id" => Ecto.UUID.generate()}, socket)

      assert refused.assigns.flash["error"]
    end

    test "grantees see dismissals and reactions but cannot dismiss", %{
      conn: conn,
      installation: installation,
      repository: repository
    } do
      request = request!(repository)
      run!(request, [{:shown, "Injection in widgets", "Body."}])
      [finding] = Ash.read!(Finding)

      finding
      |> Ash.Changeset.for_update(:record_reactions, %{reactions_up: 4, reactions_down: 2})
      |> Ash.update!()

      Dismissal.dismiss!(repository.id, finding.fingerprint, %{
        source: :forge,
        by: "ada",
        title: finding.title
      })

      grantee = user!()
      grant!(installation, grantee)

      html = conn |> page(grantee, "/reviews/#{request.id}") |> html_response(200)
      assert html =~ "👍 4 👎 2"
      assert html =~ "dismissed by ada (resolved on GitHub)"
      refute html =~ ~s(phx-click="restore")
      refute html =~ ~s(phx-click="dismiss")

      {:ok, socket} = ReviewLive.mount(%{"id" => request.id}, %{}, socket(grantee))
      {:noreply, refused} = ReviewLive.handle_event("restore", %{"id" => finding.id}, socket)
      assert refused.assigns.flash["error"]
      assert [_still] = Ash.read!(Dismissal)
    end
  end

  describe "/installations/:id" do
    test "the owner changes the defaults; a grantee only reads", %{
      conn: conn,
      owner: owner,
      installation: installation,
      repository: repository
    } do
      html = conn |> page(owner, "/installations/#{installation.id}") |> html_response(200)
      assert html =~ "Defaults for new repositories"
      assert html =~ "installed by olivia"

      grantee = user!()
      grant!(installation, grantee)

      html =
        build_conn() |> page(grantee, "/installations/#{installation.id}") |> html_response(200)

      assert html =~ ~s(href="/repos/#{repository.id}")
      refute html =~ "Defaults for new repositories"

      {:ok, socket} = InstallationLive.mount(%{"id" => installation.id}, %{}, socket(owner))

      params = %{
        "review_new_repositories" => "true",
        "default_auto_review" => "on_open",
        "apply_to_repositories" => "false"
      }

      assert {:noreply, _saved} =
               InstallationLive.handle_event("save", %{"form" => params}, socket)

      assert %{review_new_repositories: true, default_auto_review: :on_open} =
               Ash.get!(Installation, installation.id)
    end
  end

  describe "/settings" do
    test "lists only the user's own providers and defaults", %{conn: conn, owner: owner} do
      Provider.register!("mine", :openrouter, %{owner_id: owner.id})
      Provider.register!("theirs", :codex, %{owner_id: admin!().id})

      html = conn |> page(owner, "/settings") |> html_response(200)
      assert html =~ "mine"
      refute html =~ "theirs"
      assert html =~ "Detector model"
      assert html =~ "No API key yet"
    end

    test "registers, enables, and stores an API key for the user's own providers only", %{
      owner: owner
    } do
      {:ok, socket} = SettingsLive.mount(%{}, %{}, socket(owner))

      {:noreply, socket} =
        SettingsLive.handle_event(
          "register",
          %{"form" => %{"name" => "openrouter", "adapter" => "openrouter"}},
          socket
        )

      assert [%Provider{name: "openrouter", enabled: false} = provider] = socket.assigns.providers
      assert provider.owner_id == owner.id
      assert socket.assigns.flash["info"] =~ "Store its API key to use it."

      # The first key enables it.
      {:noreply, socket} =
        SettingsLive.handle_event(
          "set_key",
          %{"provider" => provider.id, "api_key" => "sk-secret"},
          socket
        )

      assert socket.assigns.flash["info"] =~
               "Stored the API key of openrouter; openrouter is enabled."

      assert [%{enabled: true, connected: true}] = socket.assigns.providers

      {:noreply, socket} = SettingsLive.handle_event("toggle", %{"id" => provider.id}, socket)
      assert [%{enabled: false}] = socket.assigns.providers
      {:noreply, socket} = SettingsLive.handle_event("toggle", %{"id" => provider.id}, socket)
      assert [%{enabled: true}] = socket.assigns.providers

      assert %{credentials: %{"api_key" => "sk-secret"}} =
               Ash.load!(Ash.get!(Provider, provider.id), :credentials)

      # Another user's provider, by id: refused.
      theirs = Provider.register!("theirs", :openrouter, %{owner_id: user!().id})

      for {event, params} <- [
            {"toggle", %{"id" => theirs.id}},
            {"set_key", %{"provider" => theirs.id, "api_key" => "x"}}
          ] do
        {:noreply, refused} = SettingsLive.handle_event(event, params, socket)
        assert refused.assigns.flash["error"]
      end

      assert %{enabled: false} = Ash.get!(Provider, theirs.id)
    end

    test "saves review defaults from the per-stage inputs, checked against the providers", %{
      owner: owner
    } do
      Provider.register!("openai-codex", :codex, %{owner_id: owner.id, enabled: true})
      model = "openai-codex/" <> hd(Codex.models())
      {:ok, socket} = SettingsLive.mount(%{}, %{}, socket(owner))

      params = %{
        "detector_model" => model,
        "detector_thinking" => "low",
        "verifier_model" => model,
        "verifier_thinking" => "",
        "scorer_model" => " ",
        "scorer_thinking" => ""
      }

      {:noreply, saved} = SettingsLive.handle_event("save_defaults", %{"form" => params}, socket)
      assert saved.assigns.flash["info"] == "Review defaults saved."

      assert {:ok, %{models: models, thinking: %{"detector" => "low"} = thinking}} =
               ReviewDefaults.get(owner.id)

      assert models == %{"detector" => model, "verifier" => model}
      assert map_size(thinking) == 1

      # The form shows what is stored.
      assert saved.assigns.defaults_form[:detector_model].value == model

      bad = Map.put(params, "detector_model", "missing/model")
      {:noreply, failed} = SettingsLive.handle_event("save_defaults", %{"form" => bad}, saved)
      assert failed.assigns.defaults_form[:models].errors != []
      assert {:ok, %{models: ^models}} = ReviewDefaults.get(owner.id)
      # The rejected reference stays selected, so the form shows what failed.
      assert render_html(failed) =~
               ~s{<option selected value="missing/model">missing/model (unavailable)</option>}
    end

    test "offers the enabled providers' models; keeps a saved model that is no longer offered", %{
      conn: conn,
      owner: owner
    } do
      codex = Provider.register!("openai-codex", :codex, %{owner_id: owner.id, enabled: true})
      Provider.register!("router", :openrouter, %{owner_id: owner.id})
      model = "openai-codex/" <> hd(Codex.models())

      html = conn |> page(owner, "/settings") |> html_response(200)
      assert html =~ ~s(<optgroup label="openai-codex">)
      assert html =~ ~s(<option value="#{model}">#{hd(Codex.models())}</option>)
      refute html =~ ~s(value="router/)
      assert html =~ "Choose a model"
      assert html =~ "Verifier&#39;s model"
      refute html =~ "(unavailable)"

      ReviewDefaults.configure!(%{
        user_id: owner.id,
        models: %{"detector" => model, "verifier" => model}
      })

      html = build_conn() |> page(owner, "/settings") |> html_response(200)
      assert html =~ ~s(<option selected value="#{model}">#{hd(Codex.models())}</option>)

      Provider.configure!(codex, %{enabled: false})

      html = build_conn() |> page(owner, "/settings") |> html_response(200)
      refute html =~ ~s(<optgroup label="openai-codex">)
      assert html =~ ~s{<option selected value="#{model}">#{model} (unavailable)</option>}
    end
  end

  describe "/codex-login" do
    test "the Models page links a Codex provider's login, which preselects it", %{
      conn: conn,
      owner: owner
    } do
      Provider.register!("first", :codex, %{owner_id: owner.id})
      Provider.register!("second", :codex, %{owner_id: owner.id})

      html = conn |> page(owner, "/settings") |> html_response(200)
      assert html =~ ~s(href="/codex-login?provider=second")
      assert html =~ "Not connected yet"

      {:ok, socket} = CodexLoginLive.mount(%{"provider" => "second"}, %{}, socket(owner))
      assert socket.assigns.selected == "second"

      # Only the user's own providers.
      Provider.register!("theirs", :codex, %{owner_id: user!().id})
      {:ok, socket} = CodexLoginLive.mount(%{"provider" => "theirs"}, %{}, socket(owner))
      assert socket.assigns.selected == nil
    end
  end

  describe "live pages" do
    # A connected page whose process is the test: it subscribes the test
    # process, so the test gets what the page would.
    defp connected(socket), do: %{socket | transport_pid: self()}

    defp set_status(request, status) do
      request
      |> Ash.Changeset.for_update(:record_progress, %{status: status})
      |> Ash.update!()
    end

    # What the page does with an update: one reload for a burst of them.
    defp update(module, socket, topic) do
      assert_received {Updates, ^topic}
      {:noreply, socket} = module.handle_info({Updates, topic}, socket)
      {:noreply, socket} = module.handle_info({Updates, topic}, socket)
      assert_received :reload
      refute_received :reload
      {:noreply, socket} = module.handle_info(:reload, socket)
      refute socket.assigns.reload_pending
      socket
    end

    defp flush_updates do
      receive do
        {Updates, _topic} -> flush_updates()
      after
        0 -> :ok
      end
    end

    test "the review page follows its request, its run, and reads again on a change", %{
      owner: owner,
      installation: installation,
      repository: repository
    } do
      request = request!(repository)
      {:ok, socket} = ReviewLive.mount(%{"id" => request.id}, %{}, connected(socket(owner)))

      assert MapSet.new([
               Updates.review(request.id),
               Updates.dismissals(repository.id),
               Updates.installation(installation.id)
             ]) == socket.assigns.followed

      set_status(request, :running)
      socket = update(ReviewLive, socket, Updates.review(request.id))
      assert socket.assigns.request.status == :running

      run = run!(request, [{:shown, "Injection in widgets", "Body."}])
      flush_updates()
      set_status(request, :posted)
      socket = update(ReviewLive, socket, Updates.review(request.id))
      assert socket.assigns.run.id == run.id
      assert MapSet.member?(socket.assigns.followed, Updates.run(run.id))
      assert socket.assigns.progress == %{}
    end

    test "the pages say what a review in flight is doing", %{
      conn: conn,
      owner: owner,
      repository: repository
    } do
      request = request!(repository) |> set_status(:running)
      flush_updates()

      ReviewProgress.track(request.id, :checkout, fn ->
        ReviewProgress.report(request.id, {:started, %{units: 2}})
        ReviewProgress.report(request.id, {:unit, "lib/a.ex#0", :done})
        ReviewProgress.report(request.id, {:unit, "lib/b.ex#0", {:failed, :timeout}})

        for {print, title, verdict} <- [
              {"p1", "Unescaped <i>input</i>", :confirmed},
              {"p2", "Slow", nil}
            ] do
          location = %{path: "lib/a.ex", start_line: 3, end_line: 5}
          finding = %{fingerprint: print, title: title, severity: :high, location: location}
          ReviewProgress.report(request.id, {:candidate, finding})
          if verdict, do: ReviewProgress.report(request.id, {:verdict, print, verdict})
        end

        html = conn |> page(owner, "/reviews/#{request.id}") |> html_response(200)
        assert html =~ "Progress"
        assert html =~ "Verifying findings: 1 of 2 checked"
        assert html =~ "2 of 2 parts reviewed"
        assert html =~ ", 1 failed"
        assert html =~ "Unescaped &lt;i&gt;input&lt;/i&gt;"
        refute html =~ "<i>input</i>"
        assert html =~ "lib/a.ex:3–5"
        assert html =~ "Confirmed"
        assert html =~ "badge candidate-verifying"

        html = build_conn() |> page(owner, "/repos/#{repository.id}") |> html_response(200)
        assert html =~ "Verifying findings: 1 of 2 checked"

        html = build_conn() |> page(owner, "/repos") |> html_response(200)
        assert html =~ "Verifying findings: 1 of 2 checked"

        {:ok, socket} = ReviewLive.mount(%{"id" => request.id}, %{}, connected(socket(owner)))
        assert %ReviewProgress{total: 2} = progress(socket, request.id)

        # Messages: newer ones are taken, older and other requests' are not.
        candidate = %{
          fingerprint: "f1",
          title: "Injection <b>here</b>",
          severity: :high,
          location: %{path: "lib/a.ex", start_line: 3, end_line: 3}
        }

        ReviewProgress.report(request.id, {:candidate, candidate})
        assert_received {ReviewProgress, id, version, newer}
        {:noreply, socket} = ReviewLive.handle_info({ReviewProgress, id, version, newer}, socket)

        assert [%{title: "Injection <b>here</b>"} | _earlier] =
                 progress(socket, request.id).candidates

        {:noreply, same} =
          ReviewLive.handle_info({ReviewProgress, id, version - 1, nil}, socket)

        assert progress(same, request.id) == newer

        {:noreply, same} =
          ReviewLive.handle_info({ReviewProgress, Ecto.UUID.generate(), version + 1, nil}, same)

        assert progress(same, request.id) == newer
      end)

      # The job stopped reporting.
      assert_received {ReviewProgress, _id, _version, nil}
      html = build_conn() |> page(owner, "/reviews/#{request.id}") |> html_response(200)
      refute html =~ "parts reviewed"
      assert html =~ "The review is running"
    end

    test "the repository page follows new reviews and keeps a settings form being edited", %{
      owner: owner,
      installation: installation,
      repository: repository
    } do
      {:ok, socket} =
        RepositoryLive.mount(%{"id" => repository.id}, %{}, connected(socket(owner)))

      assert socket.assigns.requests == []
      form = socket.assigns.form

      request = request!(repository) |> set_status(:running)
      socket = update(RepositoryLive, socket, Updates.repository(repository.id))
      assert [%{id: id}] = socket.assigns.requests
      assert id == request.id
      assert socket.assigns.form == form
      # A review in flight: the page follows its progress too.
      assert MapSet.member?(socket.assigns.followed, Updates.review(request.id))
      assert Map.has_key?(socket.assigns.progress, request.id)
      flush_updates()

      # Grants changed elsewhere: the component reads them again.
      grant!(installation, user!())
      update(RepositoryLive, socket, Updates.installation(installation.id))
      assert_received {:phoenix, :send_update, _update}
    end

    test "a page whose access was revoked leaves on the next update", %{
      installation: installation,
      repository: repository
    } do
      grantee = user!()
      access = grant!(installation, grantee)

      {:ok, socket} =
        RepositoryLive.mount(%{"id" => repository.id}, %{}, connected(socket(grantee)))

      Access.revoke!(access)
      socket = update(RepositoryLive, socket, Updates.installation(installation.id))
      assert {:live, :redirect, %{to: "/repos"}} = socket.redirected
    end

    test "the repositories and installation pages follow what they list", %{
      owner: owner,
      installation: installation,
      repository: repository
    } do
      {:ok, repos} = ReposLive.mount(%{}, %{}, connected(socket(owner)))

      assert MapSet.subset?(
               MapSet.new([
                 Updates.installations(),
                 Updates.user(owner.id),
                 Updates.installation(installation.id),
                 Updates.repository(repository.id)
               ]),
               repos.assigns.followed
             )

      {:ok, page} =
        InstallationLive.mount(%{"id" => installation.id}, %{}, connected(socket(owner)))

      form = page.assigns.form

      other =
        Repository.sync!(installation.id, to_string(unique_id()), installation.account, "gadgets")

      flush_updates()
      Repository.configure!(other, %{enabled: true})
      page = update(InstallationLive, page, Updates.installation(installation.id))
      assert Enum.map(page.assigns.repositories, & &1.name) == ["gadgets", "widgets"]
      assert page.assigns.form == form

      repos = update(ReposLive, repos, Updates.installation(installation.id))
      assert [%{repositories: [_gadgets, _widgets]}] = repos.assigns.groups
    end
  end

  defp progress(socket, id), do: Live.progress(socket.assigns.progress, id)

  defp render_html(socket) do
    socket.assigns
    |> SettingsLive.render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
