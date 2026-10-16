defmodule Tackle.Web.SignInTest do
  use Tackle.Web.DataCase, async: false

  import Tackle.Web.GitHubFixtures

  alias Tackle.Web.Accounts.User
  alias Tackle.Web.Forge.GitHub
  alias Tackle.Web.{Repo, SignIn}

  @moduletag :capture_log
  @redirect_uri "https://review.example.test/auth/github/callback"

  setup do
    forge_app!()
    :ok
  end

  # GitHub for octocat. `installations` lists `{installation, organisation,
  # status}`: the organisation each installation is on, and what its
  # membership check answers.
  defp stub_github(installations) do
    expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    accounts =
      Map.new(installations, fn {installation, org, _status} ->
        {"/app/installations/#{installation.external_id}", org}
      end)

    statuses = Map.new(installations, fn {_installation, org, status} -> {org, status} end)

    Req.Test.stub(GitHub, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/login/oauth/access_token"} ->
          Req.Test.json(conn, %{"access_token" => "ghu_user"})

        {"GET", "/user"} ->
          Req.Test.json(conn, %{"id" => 7, "login" => "octocat"})

        {"DELETE", "/applications/" <> _rest} ->
          Plug.Conn.send_resp(conn, 204, "")

        {"POST", "/app/installations/" <> _rest} ->
          Req.Test.json(conn, %{"token" => "ghs_test", "expires_at" => expires_at})

        {"GET", "/app/installations/" <> _id = path} ->
          org = Map.fetch!(accounts, path)

          Req.Test.json(conn, %{
            "account" => %{"login" => org, "id" => 1, "type" => "Organization"}
          })

        {"GET", "/orgs/" <> rest} ->
          [org, "members", "octocat"] = String.split(rest, "/")
          Plug.Conn.send_resp(conn, Map.fetch!(statuses, org), "")
      end
    end)
  end

  test "nobody signs in without an installation" do
    stub_github([])
    assert SignIn.complete(:github, "code", @redirect_uri) == {:error, :not_a_member}
    assert Ash.read!(User) == []
  end

  test "one confirming installation is enough, even after a failed check" do
    failing = installation!(%{account: "down"})
    confirming = installation!(%{account: "acme"})
    stub_github([{failing, "down", 500}, {confirming, "acme", 204}])

    assert {:ok, %User{login: "octocat"}} = SignIn.complete(:github, "code", @redirect_uri)
  end

  test "a failed check that nothing confirms is reported as unverified, not as refused" do
    failing = installation!(%{account: "down"})
    refusing = installation!(%{account: "acme"})
    stub_github([{failing, "down", 500}, {refusing, "acme", 404}])

    assert SignIn.complete(:github, "code", @redirect_uri) == {:error, :membership_unverified}
    assert Ash.read!(User) == []
  end

  test "a rejected code is reported without GitHub's details" do
    Req.Test.stub(GitHub, fn conn ->
      Req.Test.json(conn, %{"error" => "bad_verification_code"})
    end)

    assert SignIn.complete(:github, "stale", @redirect_uri) == {:error, :forge_rejected}
  end

  test "without a stored GitHub App there is no sign-in" do
    Repo.query!("DELETE FROM forge_apps")
    assert SignIn.authorize_url(:github, "s", @redirect_uri) == {:error, :sign_in_not_configured}
    assert SignIn.complete(:github, "c", @redirect_uri) == {:error, :sign_in_not_configured}
  end
end
