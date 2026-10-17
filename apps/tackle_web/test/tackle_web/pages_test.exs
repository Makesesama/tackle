defmodule Tackle.Web.PagesTest do
  @moduledoc """
  The signed-in pages (phase 8): who sees what on the HTTP render, and the
  pages' events, called directly on a socket. (`Phoenix.LiveViewTest`
  needs the `lazy_html` package, which is not a dependency.)
  """

  use Tackle.Web.ConnCase, async: false

  import Tackle.Web.AccountsFixtures
  import Tackle.Web.GitHubFixtures

  alias Phoenix.LiveView.Socket
  alias Tackle.Plugins.Codex
  alias Tackle.Web.Forges.{Access, Installation, Repository}
  alias Tackle.Web.Models.{Provider, ReviewDefaults}
  alias Tackle.Web.Reviews.{Finding, ReviewRequest, ReviewRun}

  alias Tackle.Web.{
    GrantsComponent,
    InstallationLive,
    RepositoryLive,
    ReviewLive,
    SettingsLive
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

    test "the logo is served", %{conn: conn} do
      assert conn |> get("/assets/logo.svg") |> response(200) =~ "<svg"
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

    test "admins get the sync button", %{conn: conn} do
      assert conn |> page(admin!(), "/repos") |> html_response(200) =~ ~s(action="/setup/sync")
      refute build_conn() |> page(user!(), "/repos") |> html_response(200) =~ "/setup/sync"
    end
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

      {:noreply, socket} = SettingsLive.handle_event("toggle", %{"id" => provider.id}, socket)
      assert [%{enabled: true}] = socket.assigns.providers

      {:noreply, socket} =
        SettingsLive.handle_event(
          "set_key",
          %{"provider" => provider.id, "api_key" => "sk-secret"},
          socket
        )

      assert socket.assigns.flash["info"] =~ "Stored the API key"

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
    end
  end
end
