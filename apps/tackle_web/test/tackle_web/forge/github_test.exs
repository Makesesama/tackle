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
               author: "octocat",
               title: "Add widgets"
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

      assert event.installation == %{external_id: "11", account: "acme", owner: nil}

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

    test "an installation's owner: the sender who created it, or a user account itself" do
      by_sender =
        installation_payload("created", 11, "acme", [],
          sender: {7, "octocat"},
          account_type: "Organization",
          account_id: 99
        )

      assert {:ok, %Event{installation: %{owner: %{external_id: "7", login: "octocat"}}}} =
               GitHub.parse_event("installation", by_sender)

      # Only the event that created the installation names who installed it.
      for action <- ["deleted", "suspend", "unsuspend"] do
        payload =
          installation_payload(action, 11, "acme", [],
            sender: {7, "octocat"},
            account_type: "Organization",
            account_id: 99
          )

        assert {:ok, %Event{installation: %{owner: nil}}} =
                 GitHub.parse_event("installation", payload)
      end

      on_user =
        installation_payload("suspend", 12, "octocat", [],
          sender: {8, "someone"},
          account_type: "User",
          account_id: 7
        )

      assert {:ok, %Event{installation: %{owner: %{external_id: "7", login: "octocat"}}}} =
               GitHub.parse_event("installation", on_user)

      # A bot or malformed sender names nobody.
      bot =
        by_sender
        |> put_in(["sender", "type"], "Bot")

      assert {:ok, %Event{installation: %{owner: nil}}} = GitHub.parse_event("installation", bot)
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

  describe "posting API" do
    setup %{forge_app: forge_app} do
      Req.Test.verify_on_exit!()
      installation = %{external_id: to_string(unique_id()), account: "acme"}
      repository = %{owner: "acme", name: "widgets"}
      {:ok, forge_app: forge_app, installation: installation, repository: repository}
    end

    test "post_review sends one COMMENT review at the head and returns its id", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      stub_token("ghs_test")
      head = sha("head")

      Req.Test.expect(GitHub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/repos/acme/widgets/pulls/7/reviews"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ghs_test"]
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        assert JSON.decode!(raw) == %{
                 "event" => "COMMENT",
                 "commit_id" => head,
                 "body" => "Summary <!-- tackle-review:1 -->",
                 "comments" => [
                   %{"path" => "lib/a.ex", "side" => "RIGHT", "line" => 3, "body" => "one"},
                   %{
                     "path" => "lib/b.ex",
                     "side" => "LEFT",
                     "line" => 9,
                     "start_line" => 7,
                     "start_side" => "LEFT",
                     "body" => "two"
                   }
                 ]
               }

        conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"id" => 80, "state" => "COMMENTED"})
      end)

      comments = [
        %{path: "lib/a.ex", side: :new, line: 3, start_line: nil, body: "one"},
        %{path: "lib/b.ex", side: :old, line: 9, start_line: 7, body: "two"}
      ]

      assert GitHub.post_review(
               forge_app,
               installation,
               repository,
               7,
               head,
               "Summary <!-- tackle-review:1 -->",
               comments
             ) == {:ok, "80"}
    end

    test "post_review rejects invalid input before any request", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      post = &GitHub.post_review(forge_app, installation, repository, 7, &1, &2, &3)
      comment = %{path: "a", side: :new, line: 3, body: "x"}

      assert post.("main", "b", []) == {:error, :invalid_head_sha}
      assert post.(sha("h"), nil, []) == {:error, :invalid_body}
      assert post.(sha("h"), "b", :none) == {:error, :invalid_comments}

      for invalid <- [
            %{comment | side: :right},
            %{comment | line: 0},
            %{comment | path: ""},
            Map.put(comment, :start_line, 3),
            Map.put(comment, :start_line, 5),
            Map.delete(comment, :body)
          ] do
        assert post.(sha("h"), "b", [comment, invalid]) == {:error, {:invalid_comment, 1}}
      end
    end

    test "post_review neither follows redirects nor retries", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      stub_token("ghs_test")

      Req.Test.expect(GitHub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.test/reviews")
        |> Plug.Conn.send_resp(307, "")
      end)

      assert {:error, {:github, 307, _message}} =
               GitHub.post_review(forge_app, installation, repository, 7, sha("h"), "b", [])

      Req.Test.expect(GitHub, fn conn ->
        conn |> Plug.Conn.put_status(502) |> Req.Test.json(%{"message" => "Bad Gateway"})
      end)

      assert GitHub.post_review(forge_app, installation, repository, 7, sha("h"), "b", []) ==
               {:error, {:github, 502, "Bad Gateway"}}
    end

    test "post_review fails on a response without a review id", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      stub_token("ghs_test")

      for body <- [%{"state" => "COMMENTED"}, %{"id" => "80"}, [%{"id" => 80}]] do
        Req.Test.expect(GitHub, &Req.Test.json(&1, body))

        assert GitHub.post_review(forge_app, installation, repository, 7, sha("h"), "b", []) ==
                 {:error, {:github, :unexpected_response, "/repos/acme/widgets/pulls/7/reviews"}}
      end
    end

    test "find_review reads every page and matches only the app's own reviews", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      marker = "<!-- tackle-review:42 -->"
      stub_app("tackle")
      stub_token("ghs_test")

      first_page =
        [
          review(1, "tackle", "Bot", "an older run <!-- tackle-review:41 -->"),
          review(2, "mallory", "User", "copied " <> marker),
          review(3, "other", "Bot", marker),
          %{"id" => 4, "user" => nil, "body" => marker},
          review(5, "tackle", "Bot", nil)
        ] ++ for(id <- 6..100, do: review(id, "ada", "User", "looks good"))

      expect_page("/repos/acme/widgets/pulls/7/reviews", 1, first_page)

      expect_page("/repos/acme/widgets/pulls/7/reviews", 2, [
        review(101, "tackle", "Bot", "Verdict\n" <> marker),
        review(102, "tackle", "Bot", marker)
      ])

      assert GitHub.find_review(forge_app, installation, repository, 7, marker) == {:ok, "101"}
    end

    test "find_review answers nil when no review carries the marker", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      stub_app("tackle")
      stub_token("ghs_test")

      expect_page("/repos/acme/widgets/pulls/7/reviews", 1, [
        review(1, "tackle", "Bot", "<!-- tackle-review:1 -->")
      ])

      assert GitHub.find_review(
               forge_app,
               installation,
               repository,
               7,
               "<!-- tackle-review:2 -->"
             ) == {:ok, nil}
    end

    test "find_review fails closed on malformed responses", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      path = "/repos/acme/widgets/pulls/7/reviews"
      # Cache the token, so each lookup reads the app and then the reviews.
      stub_token("ghs_test")
      assert {:ok, "ghs_test"} = GitHub.installation_token(forge_app, installation)

      for page <- [
            %{"reviews" => []},
            [%{"user" => %{"login" => "tackle[bot]"}, "body" => "m"}],
            [%{"id" => "1", "user" => nil, "body" => "m"}],
            [%{"id" => 1, "user" => "tackle[bot]", "body" => "m"}],
            [%{"id" => 1, "user" => nil, "body" => 5}]
          ] do
        stub_app("tackle")
        expect_page(path, 1, page)

        assert GitHub.find_review(forge_app, installation, repository, 7, "m") ==
                 {:error, {:github, :unexpected_response, path}}
      end

      # A malformed later page fails the whole lookup.
      stub_app("tackle")
      expect_page(path, 1, for(id <- 1..100, do: review(id, "ada", "User", "m")))
      expect_page(path, 2, [:oops])

      assert GitHub.find_review(forge_app, installation, repository, 7, "m") ==
               {:error, {:github, :unexpected_response, path}}

      Req.Test.expect(GitHub, &Req.Test.json(&1, %{"id" => 1}))

      assert GitHub.find_review(forge_app, installation, repository, 7, "m") ==
               {:error, {:github, :unexpected_response, "/app"}}
    end

    test "list reads are bounded", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      path = "/repos/acme/widgets/pulls/7/files"
      stub_token("ghs_test")
      full_page = for n <- 1..100, do: %{"filename" => "f#{n}", "patch" => "@@"}

      Req.Test.expect(GitHub, 101, fn conn ->
        assert conn.request_path == path
        Req.Test.json(conn, full_page)
      end)

      assert GitHub.pull_request_files(forge_app, installation, repository, 7) ==
               {:error, {:github, :too_many_pages, path}}
    end

    test "an exactly full final page at the limit is accepted", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      path = "/repos/acme/widgets/pulls/7/files"
      stub_token("ghs_test")
      full_page = for n <- 1..100, do: %{"filename" => "f#{n}"}
      Req.Test.expect(GitHub, 100, &Req.Test.json(&1, full_page))
      expect_page(path, 101, [])

      assert {:ok, files} = GitHub.pull_request_files(forge_app, installation, repository, 7)
      assert Enum.count(files) == 10_000
    end

    test "review_comments lists a review's comments across pages", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      path = "/repos/acme/widgets/pulls/7/reviews/80/comments"
      stub_token("ghs_test")

      expect_page(
        path,
        1,
        for(id <- 1..100, do: %{"id" => id, "body" => "c#{id}", "path" => "a"})
      )

      expect_page(path, 2, [%{"id" => 101, "body" => "c101"}])

      assert {:ok, comments} =
               GitHub.review_comments(forge_app, installation, repository, 7, "80")

      assert comments == for(id <- 1..101, do: %{id: to_string(id), body: "c#{id}"})
    end

    test "review_comments rejects a bad id and malformed comments", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context

      for review_id <- ["", "0", "8/../9", "80?x=1", 80] do
        assert GitHub.review_comments(forge_app, installation, repository, 7, review_id) ==
                 {:error, :invalid_review_id}
      end

      path = "/repos/acme/widgets/pulls/7/reviews/80/comments"
      stub_token("ghs_test")
      expect_page(path, 1, [%{"id" => 1, "body" => nil}])

      assert GitHub.review_comments(forge_app, installation, repository, 7, "80") ==
               {:error, {:github, :unexpected_response, path}}
    end

    test "pull_request_files lists every file with its patch", context do
      %{forge_app: forge_app, installation: installation, repository: repository} = context
      path = "/repos/acme/widgets/pulls/7/files"
      stub_token("ghs_test")

      expect_page(path, 1, for(n <- 1..100, do: %{"filename" => "f#{n}", "patch" => "@@ #{n}"}))

      expect_page(path, 2, [
        %{"filename" => "image.png", "status" => "added"},
        %{"filename" => "big.txt", "patch" => nil}
      ])

      assert {:ok, files} = GitHub.pull_request_files(forge_app, installation, repository, 7)

      assert files ==
               for(n <- 1..100, do: %{path: "f#{n}", patch: "@@ #{n}"}) ++
                 [%{path: "image.png", patch: nil}, %{path: "big.txt", patch: nil}]

      for page <- [%{}, [%{"patch" => "@@"}], [%{"filename" => "a", "patch" => 1}]] do
        expect_page(path, 1, page)

        assert GitHub.pull_request_files(forge_app, installation, repository, 7) ==
                 {:error, {:github, :unexpected_response, path}}
      end
    end

    defp stub_app(slug) do
      Req.Test.expect(GitHub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/app"
        assert ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
        assert [_header, _claims, _signature] = String.split(jwt, ".")
        Req.Test.json(conn, %{"id" => 4242, "slug" => slug})
      end)
    end

    defp expect_page(path, page, body) do
      Req.Test.expect(GitHub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == path
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ghs_test"]
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params == %{"per_page" => "100", "page" => to_string(page)}
        Req.Test.json(conn, body)
      end)
    end

    defp review(id, login, type, body) do
      bot_login = if type == "Bot", do: login <> "[bot]", else: login
      %{"id" => id, "user" => %{"login" => bot_login, "type" => type}, "body" => body}
    end
  end
end
