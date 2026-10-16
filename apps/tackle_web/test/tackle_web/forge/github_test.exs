defmodule Tackle.Web.Forge.GitHubTest do
  use Tackle.Web.DataCase, async: true

  import Tackle.Web.GitHubFixtures

  alias Tackle.Web.Forge.{Event, GitHub}

  setup do
    {:ok, forge_app: forge_app!()}
  end

  describe "app_jwt/2" do
    test "signs iat, exp, and iss with RS256", %{forge_app: forge_app} do
      assert {:ok, jwt} = GitHub.app_jwt(forge_app, 1_700_000_000)
      [header, claims, signature] = String.split(jwt, ".")

      assert JSON.decode!(Base.url_decode64!(header, padding: false)) == %{
               "alg" => "RS256",
               "typ" => "JWT"
             }

      assert JSON.decode!(Base.url_decode64!(claims, padding: false)) == %{
               "iat" => 1_700_000_000 - 60,
               "exp" => 1_700_000_000 + 540,
               "iss" => "4242"
             }

      assert :public_key.verify(
               header <> "." <> claims,
               :sha256,
               Base.url_decode64!(signature, padding: false),
               public_key()
             )
    end

    test "fails for a key that is not PEM", %{forge_app: forge_app} do
      forge_app = %{forge_app | private_key: "not a key"}

      assert GitHub.app_jwt(forge_app) == {:error, :invalid_private_key}
    end
  end

  describe "verify_webhook/3" do
    test "accepts a delivery signed with the webhook secret", %{forge_app: forge_app} do
      body = JSON.encode!(%{"zen" => "Keep it logically awesome."})

      assert {:ok, %Event{type: :ping, delivery_id: "delivery-" <> _id}} =
               GitHub.verify_webhook(body, headers("ping", body), forge_app)
    end

    test "rejects a wrong, malformed, or missing signature", %{forge_app: forge_app} do
      body = JSON.encode!(%{"zen" => "x"})

      wrong = headers("ping", body, "another secret")
      assert GitHub.verify_webhook(body, wrong, forge_app) == {:error, :invalid_signature}

      tampered = headers("ping", body)

      assert GitHub.verify_webhook(body <> " ", tampered, forge_app) ==
               {:error, :invalid_signature}

      malformed =
        List.keyreplace(
          headers("ping", body),
          "x-hub-signature-256",
          0,
          {"x-hub-signature-256", "md5=abc"}
        )

      assert GitHub.verify_webhook(body, malformed, forge_app) == {:error, :invalid_signature}

      missing = List.keydelete(headers("ping", body), "x-hub-signature-256", 0)
      assert GitHub.verify_webhook(body, missing, forge_app) == {:error, :invalid_signature}
    end

    test "rejects a signed body that is not a JSON object", %{forge_app: forge_app} do
      assert GitHub.verify_webhook("[1]", headers("ping", "[1]"), forge_app) ==
               {:error, :invalid_payload}

      assert GitHub.verify_webhook("{", headers("ping", "{"), forge_app) ==
               {:error, :invalid_payload}
    end

    test "rejects a signed payload that lacks what its event needs", %{forge_app: forge_app} do
      body = JSON.encode!(%{"action" => "opened", "pull_request" => %{"number" => 1}})

      assert GitHub.verify_webhook(body, headers("pull_request", body), forge_app) ==
               {:error, :invalid_payload}
    end
  end

  describe "parse_event/2" do
    setup do
      installation = %{external_id: "11", account: "acme"}
      repository = %{external_id: "22", owner: "acme", name: "widgets", installation: nil}
      {:ok, installation: installation, repository: repository}
    end

    test "pull requests", %{installation: installation, repository: repository} do
      payload = pull_request_payload(installation, repository, "opened")

      assert {:ok, %Event{} = event} = GitHub.parse_event("pull_request", payload)
      assert event.type == :pull_request
      assert event.action == :opened
      assert event.installation == %{external_id: "11", account: "acme"}
      assert event.repository == %{external_id: "22", owner: "acme", name: "widgets"}
      assert event.sender == "octocat"

      assert event.pull_request == %{
               number: 7,
               state: :open,
               draft: false,
               head_sha: sha("head"),
               base_sha: sha("base"),
               base_ref: "main",
               head_is_fork: false,
               author: "octocat"
             }
    end

    test "a head in another repository, or in a deleted one, is a fork", %{
      installation: installation,
      repository: repository
    } do
      fork =
        pull_request_payload(installation, repository, "opened", %{
          "head" => %{"sha" => sha("x"), "repo" => %{"id" => 99}}
        })

      deleted =
        pull_request_payload(installation, repository, "opened", %{
          "head" => %{"sha" => sha("x"), "repo" => nil}
        })

      assert {:ok, %{pull_request: %{head_is_fork: true}}} =
               GitHub.parse_event("pull_request", fork)

      assert {:ok, %{pull_request: %{head_is_fork: true}}} =
               GitHub.parse_event("pull_request", deleted)
    end

    test "drafts and other pull request actions", %{
      installation: installation,
      repository: repository
    } do
      draft = pull_request_payload(installation, repository, "opened", %{"draft" => true})
      assert {:ok, %{pull_request: %{draft: true}}} = GitHub.parse_event("pull_request", draft)

      for action <- ~w(reopened ready_for_review synchronize closed) do
        payload = pull_request_payload(installation, repository, action)
        assert {:ok, %Event{type: :pull_request}} = GitHub.parse_event("pull_request", payload)
      end

      labeled = pull_request_payload(installation, repository, "labeled")
      assert {:ok, %Event{type: :ignored}} = GitHub.parse_event("pull_request", labeled)
    end

    test "comments on pull requests, not on issues", %{
      installation: installation,
      repository: repository
    } do
      payload = comment_payload(installation, repository, "/tackle review", author_type: "Bot")

      assert {:ok, %Event{type: :comment, comment: comment}} =
               GitHub.parse_event("issue_comment", payload)

      assert comment == %{
               pull_number: 7,
               body: "/tackle review",
               author: "octocat",
               author_is_bot: true
             }

      issue = comment_payload(installation, repository, "/tackle review", pull_request?: false)
      assert {:ok, %Event{type: :ignored}} = GitHub.parse_event("issue_comment", issue)

      edited = comment_payload(installation, repository, "/tackle review", action: "edited")
      assert {:ok, %Event{type: :ignored}} = GitHub.parse_event("issue_comment", edited)
    end

    test "installations and their repositories" do
      created = installation_payload("created", 11, "acme", [{1, "one"}, {2, "two"}])

      assert {:ok, %Event{type: :installation, action: :created} = event} =
               GitHub.parse_event("installation", created)

      assert event.installation == %{external_id: "11", account: "acme"}

      assert event.repositories == [
               %{external_id: "1", owner: "acme", name: "one"},
               %{external_id: "2", owner: "acme", name: "two"}
             ]

      for {action, parsed} <- [
            {"deleted", :deleted},
            {"suspend", :suspended},
            {"unsuspend", :unsuspended}
          ] do
        payload = installation_payload(action, 11, "acme", [])
        assert {:ok, %Event{action: ^parsed}} = GitHub.parse_event("installation", payload)
      end

      added =
        "added"
        |> installation_payload(11, "acme", [])
        |> Map.put("repositories_added", [
          %{"id" => 3, "name" => "three", "full_name" => "acme/three"}
        ])

      assert {:ok, %Event{type: :repositories_added, repositories: [%{external_id: "3"}]}} =
               GitHub.parse_event("installation_repositories", added)

      removed =
        "removed"
        |> installation_payload(11, "acme", [])
        |> Map.put("repositories_removed", [%{"id" => 3, "name" => "three"}])

      assert {:ok, %Event{type: :repositories_removed, repositories: [%{owner: "acme"}]}} =
               GitHub.parse_event("installation_repositories", removed)
    end

    test "other events are ignored" do
      assert {:ok, %Event{type: :ignored}} = GitHub.parse_event("push", %{})
      assert {:ok, %Event{type: :ignored}} = GitHub.parse_event(nil, %{})
    end
  end

  describe "API calls" do
    setup %{forge_app: forge_app} do
      installation = %{external_id: to_string(unique_id()), account: "acme"}
      repository = %{owner: "acme", name: "widgets"}
      {:ok, forge_app: forge_app, installation: installation, repository: repository}
    end

    test "fetch an installation token once and reuse it", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      token_path = "/app/installations/#{installation.external_id}/access_tokens"
      expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      Req.Test.expect(GitHub, 1, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == token_path
        assert ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
        assert [_header, _claims, _signature] = String.split(jwt, ".")
        Req.Test.json(conn, %{"token" => "ghs_test", "expires_at" => expires_at})
      end)

      Req.Test.expect(GitHub, 2, fn conn ->
        assert conn.request_path == "/repos/acme/widgets/collaborators/ada/permission"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ghs_test"]
        Req.Test.json(conn, %{"permission" => "write"})
      end)

      assert GitHub.can_trigger?(forge_app, installation, repository, "ada") == {:ok, true}
      assert GitHub.can_trigger?(forge_app, installation, repository, "ada") == {:ok, true}
    end

    test "a rejected token is fetched again next time", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      stub_token("ghs_old")

      Req.Test.expect(GitHub, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"message" => "Bad credentials"})
      end)

      assert {:error, {:github, 401, "Bad credentials"}} =
               GitHub.pull_request(forge_app, installation, repository, 7)

      assert :error = GitHub.TokenCache.fetch({forge_app.app_id, installation.external_id})
    end

    test "can_trigger? needs write access", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      stub_token("ghs_test")

      for {permission, allowed} <- [
            {"admin", true},
            {"write", true},
            {"read", false},
            {"none", false}
          ] do
        Req.Test.expect(GitHub, fn conn -> Req.Test.json(conn, %{"permission" => permission}) end)
        assert GitHub.can_trigger?(forge_app, installation, repository, "ada") == {:ok, allowed}
      end

      Req.Test.expect(GitHub, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert GitHub.can_trigger?(forge_app, installation, repository, "ghost") == {:ok, false}
    end

    test "logins and names are escaped in paths", context do
      %{forge_app: forge_app, installation: installation} = context
      stub_token("ghs_test")

      Req.Test.expect(GitHub, fn conn ->
        assert conn.request_path == "/repos/a%2Fb/c%3Fd/collaborators/x%2F..%2Fy/permission"
        Req.Test.json(conn, %{"permission" => "read"})
      end)

      repository = %{owner: "a/b", name: "c?d"}
      assert {:ok, false} = GitHub.can_trigger?(forge_app, installation, repository, "x/../y")
    end

    test "pull_request reads the current head", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      stub_token("ghs_test")

      Req.Test.expect(GitHub, fn conn ->
        assert conn.request_path == "/repos/acme/widgets/pulls/7"

        Req.Test.json(conn, %{
          "number" => 7,
          "state" => "closed",
          "draft" => false,
          "user" => %{"login" => "octocat"},
          "head" => %{"sha" => sha("h"), "repo" => %{"id" => 1}},
          "base" => %{"sha" => sha("b"), "ref" => "main", "repo" => %{"id" => 1}}
        })
      end)

      assert {:ok, %{number: 7, state: :closed, head_sha: head, head_is_fork: false}} =
               GitHub.pull_request(forge_app, installation, repository, 7)

      assert head == sha("h")
    end

    test "transport errors are errors, not crashes", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      stub_token("ghs_test")
      Req.Test.expect(GitHub, &Req.Test.transport_error(&1, :timeout))

      assert {:error, {:github, :transport, _message}} =
               GitHub.pull_request(forge_app, installation, repository, 7)
    end

    defp stub_token(token) do
      expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      Req.Test.expect(GitHub, fn conn ->
        Req.Test.json(conn, %{"token" => token, "expires_at" => expires_at})
      end)
    end
  end
end
