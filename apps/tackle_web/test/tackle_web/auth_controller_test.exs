defmodule Tackle.Web.AuthControllerTest do
  use Tackle.Web.ConnCase, async: false

  import Tackle.Web.AccountsFixtures
  import Tackle.Web.GitHubFixtures

  alias Tackle.Web.Accounts.User
  alias Tackle.Web.{Auth, Repo, Setup}
  alias Tackle.Web.Forge.GitHub
  alias Tackle.Web.Forges.Installation

  @moduletag :capture_log

  setup do
    {:ok, forge_app: forge_app!(), installation: installation!(%{account: "acme"})}
  end

  # GitHub for one user: the code exchange, `/user`, revocation, the
  # installation's account, an installation token, and the org membership.
  defp stub_github(installation, opts \\ []) do
    member_status = Keyword.get(opts, :member_status, 204)
    user_id = Keyword.get(opts, :user_id, 583_231)
    expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
    installation_path = "/app/installations/#{installation.external_id}"

    Req.Test.stub(GitHub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/login/oauth/access_token"} ->
          Req.Test.json(conn, %{"access_token" => "ghu_user"})

        {"GET", "/user"} ->
          Req.Test.json(conn, %{"id" => user_id, "login" => "octocat", "name" => "The Octocat"})

        {"DELETE", "/applications/" <> _rest} ->
          Plug.Conn.send_resp(conn, 204, "")

        {"GET", ^installation_path} ->
          Req.Test.json(conn, %{
            "account" => %{"login" => "acme", "id" => 9, "type" => "Organization"}
          })

        {"POST", ^installation_path <> "/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_test", "expires_at" => expires_at})

        {"GET", "/orgs/acme/members/octocat"} ->
          Plug.Conn.send_resp(conn, member_status, "")
      end
    end)
  end

  # Starts a sign-in and returns the conn (with its session) and the state.
  defp start_sign_in(conn) do
    conn = get(conn, "/auth/github")
    location = redirected_to(conn, 302)
    assert String.starts_with?(location, "https://github.test/login/oauth/authorize?")

    %{"state" => state, "redirect_uri" => redirect_uri} =
      location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert redirect_uri == "http://localhost:4002/auth/github/callback"
    {conn, state}
  end

  test "signs in a member of an installed organisation in a renewed session", %{
    conn: conn,
    installation: installation
  } do
    stub_github(installation)

    # Something planted in the session before sign-in does not survive it.
    conn = Plug.Test.init_test_session(conn, %{"planted" => "value"})
    {conn, state} = start_sign_in(conn)

    conn = get(recycle(conn), "/auth/github/callback", %{"code" => "c0de", "state" => state})
    assert redirected_to(conn, 302) == "/"

    user_id = get_session(conn, :user_id)
    assert %User{login: "octocat", external_id: "583231", admin: false} = Ash.get!(User, user_id)
    assert get_session(conn, :planted) == nil
    assert get_session(conn, :oauth_state) == nil
    assert conn.private.plug_session_info == :renew

    # Signed in, the start page leads to the repositories, with the login on top.
    assert redirected_to(get(recycle(conn), "/"), 302) == "/repos"
    page = get(recycle(conn), "/repos")
    assert html_response(page, 200) =~ "octocat"
  end

  test "signing in from a browser that unlocked setup claims admin, once", %{
    conn: conn,
    installation: installation
  } do
    stub_github(installation)

    conn =
      Plug.Test.init_test_session(conn, %{"setup_unlocked_at" => System.os_time(:second)})

    {conn, state} = start_sign_in(conn)
    conn = get(recycle(conn), "/auth/github/callback", %{"code" => "c0de", "state" => state})

    assert %User{admin: true} = Ash.get!(User, get_session(conn, :user_id))
    # The renewed session no longer holds the unlock.
    assert get_session(conn, :setup_unlocked_at) == nil
  end

  test "an expired setup unlock claims nothing", %{conn: conn, installation: installation} do
    stub_github(installation)
    expired = System.os_time(:second) - Setup.unlock_ttl() - 1
    conn = Plug.Test.init_test_session(conn, %{"setup_unlocked_at" => expired})

    {conn, state} = start_sign_in(conn)
    conn = get(recycle(conn), "/auth/github/callback", %{"code" => "c0de", "state" => state})

    assert %User{admin: false} = Ash.get!(User, get_session(conn, :user_id))
  end

  test "the state is checked, and works once", %{conn: conn, installation: installation} do
    stub_github(installation)
    {conn, state} = start_sign_in(conn)

    wrong = get(recycle(conn), "/auth/github/callback", %{"code" => "c0de", "state" => "other"})
    assert html_response(wrong, 400) =~ "expired or did not start here"

    # The failed attempt used up the state.
    again = get(recycle(wrong), "/auth/github/callback", %{"code" => "c0de", "state" => state})
    assert html_response(again, 400) =~ "expired or did not start here"

    no_session = get(build_conn(), "/auth/github/callback", %{"code" => "c0de", "state" => state})
    assert html_response(no_session, 400)

    assert Ash.read!(User) == []
  end

  test "refuses someone who is not a member", %{conn: conn, installation: installation} do
    stub_github(installation, member_status: 404)
    {conn, state} = start_sign_in(conn)

    conn = get(recycle(conn), "/auth/github/callback", %{"code" => "c0de", "state" => state})
    assert html_response(conn, 403) =~ "not a member"
    assert get_session(conn, :user_id) == nil
    assert Ash.read!(User) == []
  end

  test "nobody signs in before the app is installed", %{conn: conn, installation: installation} do
    stub_github(installation)

    Ash.Changeset.for_create(Installation, :sync, %{
      forge: :github,
      external_id: installation.external_id,
      account: "acme",
      status: :removed
    })
    |> Ash.create!()

    {conn, state} = start_sign_in(conn)
    conn = get(recycle(conn), "/auth/github/callback", %{"code" => "c0de", "state" => state})
    assert html_response(conn, 403)
    assert Ash.read!(User) == []
  end

  test "reports a cancelled sign-in, an unknown forge, and a missing OAuth client", %{conn: conn} do
    {conn, state} = start_sign_in(conn)

    cancelled =
      get(recycle(conn), "/auth/github/callback", %{"error" => "access_denied", "state" => state})

    assert html_response(cancelled, 400) =~ "cancelled"

    assert html_response(get(build_conn(), "/auth/gitlab"), 404)

    forge_app!(%{client_secret: nil})
    assert html_response(get(build_conn(), "/auth/github"), 503) =~ "not set up"
  end

  test "sign-out drops the session and needs the CSRF token", %{conn: conn} do
    user = user!()
    # Test conns skip CSRF protection unless told otherwise.
    conn = conn |> sign_in(user) |> put_private(:plug_skip_csrf_protection, false)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(conn, "/sign-out")
    end

    page = get(conn, "/repos")

    [token] =
      Regex.run(~r/name="_csrf_token" value="([^"]+)"/, html_response(page, 200),
        capture: :all_but_first
      )

    conn =
      page
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/sign-out", %{"_csrf_token" => token})

    assert redirected_to(conn, 302) == "/"
    assert conn.private.plug_session_info == :drop
  end

  test "an expired sign-in or a deleted user is signed out", %{conn: conn} do
    user = user!()

    expired = conn |> sign_in(user, Auth.max_age() + 1) |> get("/")
    assert html_response(expired, 200) =~ "Sign in with GitHub"
    assert get_session(expired, :user_id) == nil

    # Users have no destroy action; an operator deletes the row.
    Repo.query!("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
    deleted = build_conn() |> sign_in(user) |> get("/")
    assert html_response(deleted, 200) =~ "Sign in with GitHub"
  end
end
