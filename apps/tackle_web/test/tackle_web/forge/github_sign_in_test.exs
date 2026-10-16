defmodule Tackle.Web.Forge.GitHubSignInTest do
  use Tackle.Web.DataCase, async: true

  import Tackle.Web.GitHubFixtures

  alias Tackle.Web.Forge.GitHub

  @redirect_uri "https://review.example.test/auth/github/callback"

  setup do
    {:ok, forge_app: forge_app!()}
  end

  describe "authorize_url/3" do
    test "sends the browser to GitHub with the client id, state, and callback", %{
      forge_app: forge_app
    } do
      assert {:ok, url} = GitHub.authorize_url(forge_app, "the-state", @redirect_uri)

      uri = URI.parse(url)

      assert "#{uri.scheme}://#{uri.host}#{uri.path}" ==
               "https://github.test/login/oauth/authorize"

      assert URI.decode_query(uri.query) == %{
               "client_id" => "Iv1.test",
               "state" => "the-state",
               "redirect_uri" => @redirect_uri,
               "allow_signup" => "false"
             }
    end

    test "needs the client id and secret" do
      without_secret = forge_app!(%{client_secret: nil})

      assert GitHub.authorize_url(without_secret, "s", @redirect_uri) ==
               {:error, :sign_in_not_configured}

      without_id = forge_app!(%{client_id: nil, client_secret: "secret"})

      assert GitHub.authorize_url(without_id, "s", @redirect_uri) ==
               {:error, :sign_in_not_configured}
    end
  end

  describe "sign_in/3" do
    test "exchanges the code, reads the user, and revokes the token", %{forge_app: forge_app} do
      test_pid = self()

      Req.Test.stub(GitHub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {conn.method, conn.host, conn.request_path, conn.req_headers, body})

        case {conn.method, conn.request_path} do
          {"POST", "/login/oauth/access_token"} ->
            Req.Test.json(conn, %{"access_token" => "ghu_user", "token_type" => "bearer"})

          {"GET", "/user"} ->
            Req.Test.json(conn, %{"id" => 583_231, "login" => "octocat", "name" => "The Octocat"})

          {"DELETE", "/applications/Iv1.test/token"} ->
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert GitHub.sign_in(forge_app, "the-code", @redirect_uri) ==
               {:ok, %{external_id: "583231", login: "octocat", name: "The Octocat"}}

      assert_received {"POST", "github.test", "/login/oauth/access_token", headers, body}
      assert {"accept", "application/json"} in headers

      assert JSON.decode!(body) == %{
               "client_id" => "Iv1.test",
               "client_secret" => "test-client-secret",
               "code" => "the-code",
               "redirect_uri" => @redirect_uri
             }

      assert_received {"GET", "api.github.test", "/user", headers, ""}
      assert {"authorization", "Bearer ghu_user"} in headers

      assert_received {"DELETE", "api.github.test", "/applications/Iv1.test/token", headers, body}
      basic = "Basic " <> Base.encode64("Iv1.test:test-client-secret")
      assert {"authorization", basic} in headers
      assert JSON.decode!(body) == %{"access_token" => "ghu_user"}
    end

    @tag :capture_log
    test "a failed revocation does not fail the sign-in", %{forge_app: forge_app} do
      Req.Test.stub(GitHub, fn conn ->
        case conn.request_path do
          "/login/oauth/access_token" -> Req.Test.json(conn, %{"access_token" => "ghu_user"})
          "/user" -> Req.Test.json(conn, %{"id" => 1, "login" => "ada", "name" => nil})
          "/applications/" <> _rest -> Plug.Conn.send_resp(conn, 500, "")
        end
      end)

      assert {:ok, %{login: "ada", name: nil}} = GitHub.sign_in(forge_app, "code", @redirect_uri)
    end

    test "keeps only GitHub's error code for a rejected code", %{forge_app: forge_app} do
      Req.Test.stub(GitHub, fn conn ->
        "/login/oauth/access_token" = conn.request_path

        Req.Test.json(conn, %{
          "error" => "bad_verification_code",
          "error_description" => "The code passed is incorrect or expired."
        })
      end)

      assert GitHub.sign_in(forge_app, "stale", @redirect_uri) ==
               {:error, {:github, :oauth, "bad_verification_code"}}
    end

    test "fails on an unexpected user", %{forge_app: forge_app} do
      Req.Test.stub(GitHub, fn conn ->
        case conn.request_path do
          "/login/oauth/access_token" -> Req.Test.json(conn, %{"access_token" => "ghu_user"})
          "/user" -> Req.Test.json(conn, %{"login" => "no-id"})
          "/applications/" <> _rest -> Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert GitHub.sign_in(forge_app, "code", @redirect_uri) ==
               {:error, {:github, :unexpected_response, "/user"}}
    end
  end

  describe "member?/3" do
    setup do
      installation = installation!(%{account: "acme"})
      {:ok, installation: installation}
    end

    defp stub_membership(installation, account, member_status) do
      expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
      installation_path = "/app/installations/#{installation.external_id}"

      Req.Test.stub(GitHub, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", ^installation_path} ->
            Req.Test.json(conn, %{"id" => 1, "account" => account})

          {"POST", "/app/installations/" <> _rest} ->
            Req.Test.json(conn, %{"token" => "ghs_test", "expires_at" => expires_at})

          {"GET", "/orgs/acme/members/" <> _login} ->
            Plug.Conn.send_resp(conn, member_status, "")
        end
      end)
    end

    @organisation %{"login" => "acme", "id" => 99, "type" => "Organization"}
    @user %{external_id: "1", login: "ada"}

    test "asks the organisation for its members", %{forge_app: forge_app, installation: i} do
      stub_membership(i, @organisation, 204)
      assert GitHub.member?(forge_app, i, @user) == {:ok, true}

      stub_membership(i, @organisation, 404)
      assert GitHub.member?(forge_app, i, @user) == {:ok, false}

      stub_membership(i, @organisation, 302)
      assert GitHub.member?(forge_app, i, @user) == {:ok, false}

      stub_membership(i, @organisation, 500)
      assert {:error, {:github, 500, _message}} = GitHub.member?(forge_app, i, @user)
    end

    test "compares account ids for an installation on a user account, not logins", %{
      forge_app: forge_app,
      installation: i
    } do
      account = %{"login" => "ada", "id" => 1, "type" => "User"}
      stub_membership(i, account, 500)
      assert GitHub.member?(forge_app, i, @user) == {:ok, true}

      # Someone who took over the login of a renamed account is not the owner.
      assert GitHub.member?(forge_app, i, %{external_id: "2", login: "ada"}) == {:ok, false}
    end
  end
end
