defmodule Tackle.Web.Forge.GitHubSetupTest do
  use Tackle.Web.DataCase, async: true

  import Tackle.Web.GitHubFixtures

  alias Tackle.Web.Forge.GitHub

  @base "https://review.example.test"

  describe "registration_form/3" do
    test "posts a manifest with the app's URLs, permissions, and webhook" do
      assert {:ok, form} =
               GitHub.registration_form(@base, "st4te", owner: "acme", name: "tackle-acme")

      assert form.action ==
               "https://github.test/organizations/acme/settings/apps/new?state=st4te"

      [{"manifest", json}] = form.fields

      assert JSON.decode!(json) == %{
               "name" => "tackle-acme",
               "url" => @base,
               "redirect_url" => @base <> "/setup/github/callback",
               "callback_urls" => [@base <> "/auth/github/callback"],
               "setup_url" => @base <> "/setup/github/installed",
               "setup_on_update" => true,
               "public" => false,
               "request_oauth_on_install" => false,
               "default_permissions" => %{
                 "metadata" => "read",
                 "contents" => "read",
                 "pull_requests" => "write",
                 "issues" => "read",
                 "members" => "read"
               },
               "hook_attributes" => %{"url" => @base <> "/webhooks/github", "active" => true},
               "default_events" => ["pull_request", "issue_comment"]
             }
    end

    test "registers under the personal account, or without a webhook" do
      assert {:ok, form} = GitHub.registration_form(@base, "s", webhook?: false)
      assert form.action == "https://github.test/settings/apps/new?state=s"
      [{"manifest", json}] = form.fields
      manifest = JSON.decode!(json)
      refute Map.has_key?(manifest, "hook_attributes")
      refute Map.has_key?(manifest, "default_events")
    end

    test "refuses an organisation name that is not one" do
      for owner <- ["../evil", "a/b", "-x", "x?y=1"] do
        assert GitHub.registration_form(@base, "s", owner: owner) == {:error, :invalid_owner}
      end
    end
  end

  describe "complete_registration/1" do
    test "exchanges the code, unauthenticated, for the app's settings and secrets" do
      test_pid = self()

      Req.Test.stub(GitHub, fn conn ->
        send(test_pid, {conn.method, conn.request_path, conn.req_headers})

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "id" => 1234,
          "slug" => "tackle-acme",
          "client_id" => "Iv23.client",
          "client_secret" => "client-secret",
          "webhook_secret" => "hook-secret",
          "pem" => "-----BEGIN RSA PRIVATE KEY-----\n...",
          "html_url" => "https://github.test/apps/tackle-acme"
        })
      end)

      assert GitHub.complete_registration("c0de") ==
               {:ok,
                %{
                  app_id: "1234",
                  client_id: "Iv23.client",
                  client_secret: "client-secret",
                  webhook_secret: "hook-secret",
                  private_key: "-----BEGIN RSA PRIVATE KEY-----\n...",
                  install_url: "https://github.test/apps/tackle-acme/installations/new"
                }}

      assert_received {"POST", "/app-manifests/c0de/conversions", headers}
      refute List.keymember?(headers, "authorization", 0)
    end

    test "keeps a missing webhook secret as nil and rejects a used code" do
      Req.Test.stub(GitHub, fn conn ->
        Req.Test.json(conn, %{
          "id" => 1,
          "client_id" => "c",
          "client_secret" => "s",
          "webhook_secret" => nil,
          "pem" => "pem",
          "html_url" => "https://github.test/apps/x"
        })
      end)

      assert {:ok, %{webhook_secret: nil}} = GitHub.complete_registration("c")

      Req.Test.stub(GitHub, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, {:github, 404, _message}} = GitHub.complete_registration("used")
    end
  end

  describe "installations" do
    setup do
      {:ok, forge_app: forge_app!()}
    end

    defp stub_installations(installations, repositories) do
      expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      Req.Test.stub(GitHub, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/app/installations"} ->
            installations_page(conn, installations)

          {"GET", "/app/installations/" <> id} ->
            installation_response(conn, installations, id)

          {"POST", "/app/installations/" <> _rest} ->
            Req.Test.json(conn, %{"token" => "ghs_test", "expires_at" => expires_at})

          {"GET", "/installation/repositories"} ->
            Req.Test.json(conn, %{
              "total_count" => length(repositories),
              "repositories" => repositories
            })
        end
      end)
    end

    defp repo(id, name),
      do: %{"id" => id, "name" => name, "owner" => %{"login" => "acme"}}

    test "lists every installation with its repositories; suspended ones without", %{
      forge_app: forge_app
    } do
      active = unique_id()
      suspended = unique_id()

      stub_installations(
        [
          %{"id" => active, "account" => %{"login" => "acme"}, "suspended_at" => nil},
          %{"id" => suspended, "account" => %{"login" => "other"}, "suspended_at" => "2026-01-01"}
        ],
        [repo(1, "widgets"), repo(2, "gadgets")]
      )

      assert {:ok, [first, second]} = GitHub.installations(forge_app)

      assert first == %{
               installation: %{external_id: Integer.to_string(active), account: "acme"},
               status: :active,
               repositories: [
                 %{external_id: "1", owner: "acme", name: "widgets"},
                 %{external_id: "2", owner: "acme", name: "gadgets"}
               ]
             }

      assert %{status: :suspended, repositories: nil} = second
    end

    test "reads one installation, and only this app's", %{forge_app: forge_app} do
      id = unique_id()

      stub_installations(
        [%{"id" => id, "account" => %{"login" => "acme"}, "suspended_at" => nil}],
        [repo(1, "widgets")]
      )

      assert {:ok, %{status: :active, repositories: [_widgets]}} =
               GitHub.installation(forge_app, Integer.to_string(id))

      assert GitHub.installation(forge_app, "999") == {:error, :not_found}
    end
  end
end
