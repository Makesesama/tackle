defmodule Tackle.Web.SetupTest do
  use Tackle.Web.ConnCase, async: false

  import ExUnit.CaptureLog
  import Tackle.Web.AccountsFixtures
  import Tackle.Web.GitHubFixtures

  alias Tackle.Web.Accounts.User
  alias Tackle.Web.Forge.GitHub
  alias Tackle.Web.Forges.{ForgeApp, Installation}
  alias Tackle.Web.Setup

  @moduletag :capture_log

  defp unlocked(conn),
    do: Plug.Test.init_test_session(conn, %{"setup_unlocked_at" => System.os_time(:second)})

  defp stub_github(installation_id) do
    expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
    installation_path = "/app/installations/#{installation_id}"

    Req.Test.stub(GitHub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app-manifests/c0de/conversions"} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "id" => 4242,
            "client_id" => "Iv23.client",
            "client_secret" => "client-secret",
            "webhook_secret" => nil,
            "pem" => private_key_pem(),
            "html_url" => "https://github.test/apps/tackle-acme"
          })

        {"GET", ^installation_path} ->
          Req.Test.json(conn, %{
            "id" => String.to_integer(installation_id),
            "account" => %{"login" => "acme"},
            "suspended_at" => nil
          })

        {"GET", "/app/installations/" <> _other} ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})

        {"POST", ^installation_path <> "/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_test", "expires_at" => expires_at})

        {"GET", "/installation/repositories"} ->
          Req.Test.json(conn, %{
            "repositories" => [%{"id" => 7, "name" => "widgets", "owner" => %{"login" => "acme"}}]
          })

        {"GET", "/app"} ->
          Req.Test.json(conn, %{"html_url" => "https://github.test/apps/tackle-acme"})
      end
    end)
  end

  describe "Setup" do
    test "the token works only while setup is incomplete" do
      refute Setup.valid_token?("wrong")
      refute Setup.valid_token?(nil)
      assert Setup.valid_token?(Setup.token())
      assert Setup.valid_token?(" " <> Setup.token() <> "\n")

      forge_app!()
      assert Setup.valid_token?(Setup.token())
      admin!()
      refute Setup.valid_token?(Setup.token())
      refute Setup.unlocked?(System.os_time(:second))
    end

    test "an unlock expires" do
      assert Setup.unlocked?(System.os_time(:second))
      refute Setup.unlocked?(System.os_time(:second) - Setup.unlock_ttl() - 1)
      refute Setup.unlocked?(nil)
    end

    test "announce logs the URL and token only while setup is incomplete" do
      log = capture_log([level: :warning], fn -> Setup.announce() end)
      assert log =~ "http://localhost:4002/setup"
      assert log =~ Setup.token()

      forge_app!()
      admin!()
      assert capture_log([level: :warning], fn -> Setup.announce() end) == ""
    end
  end

  test "from the token to the first admin, in the browser", %{conn: conn} do
    installation_id = to_string(unique_id())
    stub_github(installation_id)

    # 1. Locked: the page asks for the token, and a wrong one is refused.
    assert html_response(get(conn, "/setup"), 200) =~ "Unlock setup"
    assert html_response(post(conn, "/setup/unlock", %{"token" => "nope"}), 403)

    conn = post(conn, "/setup/unlock", %{"token" => Setup.token()})
    assert redirected_to(conn, 302) == "/setup"
    assert html_response(get(recycle(conn), "/setup"), 200) =~ "Create the GitHub App"

    # 2. The registration form posts a manifest to GitHub with a state.
    page = post(recycle(conn), "/setup/github", %{"owner" => "acme", "name" => "tackle-acme"})
    html = html_response(page, 200)

    [action] = Regex.run(~r/action="(https:[^"]+)"/, html, capture: :all_but_first)

    assert String.starts_with?(
             action,
             "https://github.test/organizations/acme/settings/apps/new?"
           )

    %{"state" => state} = action |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert html =~ ~s(name="manifest")
    # localhost: GitHub cannot deliver webhooks, so none is registered.
    assert html =~ "the App is created without"

    # 3. GitHub's redirect: the App is stored and the browser goes to install it.
    callback = get(recycle(page), "/setup/github/callback", %{"code" => "c0de", "state" => state})

    assert redirected_to(callback, 302) ==
             "https://github.test/apps/tackle-acme/installations/new"

    forge_app = ForgeApp.get!(:github) |> Ash.load!([:client_secret, :webhook_secret])
    assert %{app_id: "4242", client_id: "Iv23.client", client_secret: "client-secret"} = forge_app
    # No webhook secret from GitHub: a random one, so forged deliveries fail.
    assert byte_size(forge_app.webhook_secret) >= 32

    # 4. GitHub's redirect after installing: confirmed and recorded.
    installed =
      get(recycle(callback), "/setup/github/installed", %{
        "installation_id" => installation_id,
        "setup_action" => "install"
      })

    assert redirected_to(installed, 302) == "/setup"

    assert %{account: "acme", status: :active} =
             Installation.get_external!(:github, installation_id)

    setup_page = html_response(get(recycle(installed), "/setup"), 200)
    assert setup_page =~ "Sign in with GitHub"
    # The manifest cannot carry a logo; the page offers it for upload.
    assert setup_page =~ ~s(href="/assets/logo.png")

    # 5. Signing in from this browser claims admin (AuthControllerTest);
    # afterwards setup is complete and closed.
    admin!()
    assert redirected_to(get(recycle(installed), "/setup"), 302) == "/"
    refute Setup.valid_token?(Setup.token())
  end

  test "without the unlock, nothing can be registered or recorded", %{conn: conn} do
    stub_github("1")

    assert html_response(post(conn, "/setup/github", %{}), 403) =~ "Setup is locked"

    assert html_response(
             get(conn, "/setup/github/callback", %{"code" => "c0de", "state" => "s"}),
             403
           )

    assert html_response(post(conn, "/setup/sync"), 403)
    assert html_response(get(conn, "/setup/github/install"), 403)

    # GitHub's post-install redirect from someone else's browser: a thank-you page.
    page = get(conn, "/setup/github/installed", %{"installation_id" => "1"})
    assert html_response(page, 200) =~ "Installed"

    assert ForgeApp.get!(:github) == nil
    assert Ash.read!(Installation) == []
  end

  test "the state is checked, and an App is never replaced", %{conn: conn} do
    stub_github("1")
    conn = unlocked(conn)

    page = post(conn, "/setup/github", %{})
    wrong = get(recycle(page), "/setup/github/callback", %{"code" => "c0de", "state" => "other"})
    assert html_response(wrong, 400) =~ "expired"

    # An App stored meanwhile (another setup) is never replaced.
    existing = forge_app!()
    assert html_response(post(conn, "/setup/github", %{}), 409)
    assert ForgeApp.get!(:github).id == existing.id
  end

  test "a forged installation id records nothing", %{conn: conn} do
    stub_github("1")
    forge_app!()

    page = conn |> unlocked() |> get("/setup/github/installed", %{"installation_id" => "999"})
    assert html_response(page, 404) =~ "does not know that installation"
    assert Ash.read!(Installation) == []

    assert html_response(
             conn |> unlocked() |> get("/setup/github/installed", %{"installation_id" => "x"}),
             404
           )
  end

  test "admins sync from GitHub and install on more accounts after setup", %{conn: conn} do
    installation_id = to_string(unique_id())
    stub_github(installation_id)
    forge_app!()
    admin = admin!()
    conn = sign_in(conn, admin)

    home = html_response(get(conn, "/repos"), 200)
    assert home =~ "/setup/github/install"
    assert home =~ ~s(action="/setup/sync")
    refute home =~ "Not set up yet"

    stub_installations_list(installation_id)
    synced = post(conn, "/setup/sync")
    assert html_response(synced, 200) =~ "1 installation(s) with 1 repositories"

    assert redirected_to(get(conn, "/setup/github/install"), 302) ==
             "https://github.test/apps/tackle-acme/installations/new"

    # Signed in, but not an admin: no.
    user = user!()
    assert html_response(build_conn() |> sign_in(user) |> post("/setup/sync"), 403)
    assert %User{admin: false} = Ash.get!(User, user.id)
  end

  test "signed-in users install the App; the redirect records it, never its owner", %{
    conn: conn
  } do
    installation_id = to_string(unique_id())
    stub_github(installation_id)
    forge_app!()
    admin!()
    user = user!()
    conn = sign_in(conn, user)

    home = html_response(get(conn, "/repos"), 200)
    assert home =~ ~s(href="/setup/github/install")
    refute home =~ ~s(action="/setup/sync")

    assert redirected_to(get(conn, "/setup/github/install"), 302) ==
             "https://github.test/apps/tackle-acme/installations/new"

    installed = get(conn, "/setup/github/installed", %{"installation_id" => installation_id})
    assert redirected_to(installed, 302) == "/"

    # The browser's redirect cannot say who installed it (§7.12).
    assert %{account: "acme", owner_external_id: nil} =
             Installation.get_external!(:github, installation_id)

    page = get(conn, "/setup/github/installed", %{"installation_id" => "999"})
    assert html_response(page, 404) =~ "does not know that installation"
  end

  defp stub_installations_list(installation_id) do
    expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    Req.Test.stub(GitHub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/app/installations"} ->
          installations_page(conn, [
            %{
              "id" => String.to_integer(installation_id),
              "account" => %{"login" => "acme"},
              "suspended_at" => nil
            }
          ])

        {"POST", "/app/installations/" <> _rest} ->
          Req.Test.json(conn, %{"token" => "ghs_test", "expires_at" => expires_at})

        {"GET", "/installation/repositories"} ->
          Req.Test.json(conn, %{
            "repositories" => [%{"id" => 7, "name" => "widgets", "owner" => %{"login" => "acme"}}]
          })

        {"GET", "/app"} ->
          Req.Test.json(conn, %{"html_url" => "https://github.test/apps/tackle-acme"})
      end
    end)
  end
end
