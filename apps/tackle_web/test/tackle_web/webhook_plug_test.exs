defmodule Tackle.Web.WebhookPlugTest do
  use Tackle.Web.ConnCase, async: true
  use Oban.Testing, repo: Tackle.Web.Repo

  import Tackle.Web.GitHubFixtures

  require Ash.Query

  alias Tackle.Web.Forges.{Installation, Repository}
  alias Tackle.Web.Reviews.ReviewRequest
  alias Tackle.Web.Triggers.CommandJob

  defp deliver(conn, event, payload, opts \\ []) do
    body = Keyword.get_lazy(opts, :body, fn -> JSON.encode!(payload) end)
    headers = Keyword.get_lazy(opts, :headers, fn -> headers(event, body) end)

    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> post("/webhooks/github", body)
  end

  defp requests(repository_id) do
    ReviewRequest |> Ash.Query.filter(repository_id == ^repository_id) |> Ash.read!()
  end

  describe "without a configured GitHub App" do
    test "answers 503", %{conn: conn} do
      conn = deliver(conn, "ping", %{})
      assert json_response(conn, 503) == %{"status" => "not configured"}
    end
  end

  describe "with a configured GitHub App" do
    setup do
      forge_app!()
      :ok
    end

    test "answers a ping", %{conn: conn} do
      assert json_response(deliver(conn, "ping", %{"zen" => "x"}), 200) == %{
               "status" => "ok",
               "outcome" => "pong"
             }
    end

    test "rejects unsigned and wrongly signed deliveries without acting on them", %{conn: conn} do
      payload = installation_payload("created", 501, "acme", [{1, "one"}])
      body = JSON.encode!(payload)

      wrong =
        deliver(conn, "installation", payload, headers: headers("installation", body, "nope"))

      assert json_response(wrong, 401) == %{"status" => "invalid signature"}

      unsigned =
        deliver(conn, "installation", payload,
          headers: List.keydelete(headers("installation", body), "x-hub-signature-256", 0)
        )

      assert json_response(unsigned, 401)
      assert {:ok, nil} = Installation.get_external(:github, "501")
    end

    test "rejects a signed delivery that is not a valid event", %{conn: conn} do
      conn = deliver(conn, "pull_request", nil, body: ~s({"action": "opened"}))
      assert json_response(conn, 400) == %{"status" => "invalid payload"}
    end

    test "an installation creates its repositories with its defaults", %{conn: conn} do
      payload = installation_payload("created", 502, "acme", [{11, "one"}, {12, "two"}])

      assert %{"outcome" => "installation: :active"} =
               json_response(deliver(conn, "installation", payload), 200)

      {:ok, installation} = Installation.get_external(:github, "502")
      assert %{account: "acme", status: :active, review_new_repositories: false} = installation

      repositories =
        Repository |> Ash.Query.filter(installation_id == ^installation.id) |> Ash.read!()

      assert repositories |> Enum.map(& &1.name) |> Enum.sort() == ["one", "two"]
      assert Enum.all?(repositories, &(&1.active and not &1.enabled and &1.auto_review == :off))
    end

    test "the user who installed the app owns it; later events do not change the owner", %{
      conn: conn
    } do
      payload =
        installation_payload("created", 505, "acme", [{31, "one"}],
          sender: {7, "octocat"},
          account_type: "Organization",
          account_id: 99
        )

      deliver(conn, "installation", payload)

      assert %{owner_external_id: "7", owner_login: "octocat"} =
               Installation.get_external!(:github, "505")

      # A later created event, or another event with a different sender, keeps the owner.
      deliver(build_conn(), "installation", put_in(payload, ["sender", "id"], 8))

      for action <- ["suspend", "unsuspend"] do
        other =
          installation_payload(action, 505, "acme", [],
            sender: {8, "mallory"},
            account_type: "Organization",
            account_id: 99
          )

        deliver(build_conn(), "installation", other)
      end

      assert %{owner_external_id: "7"} = Installation.get_external!(:github, "505")

      # An installation without a sender stays unowned.
      deliver(build_conn(), "installation", installation_payload("created", 506, "acme", []))
      assert %{owner_external_id: nil} = Installation.get_external!(:github, "506")
    end

    test "uninstalling marks the installation removed and its repositories inactive", %{
      conn: conn
    } do
      deliver(conn, "installation", installation_payload("created", 503, "acme", [{21, "one"}]))

      deliver(
        build_conn(),
        "installation",
        installation_payload("deleted", 503, "acme", [{21, "one"}])
      )

      {:ok, installation} = Installation.get_external(:github, "503")
      assert installation.status == :removed
      assert {:ok, %{active: false}} = Repository.get_external(installation.id, "21")
    end

    test "repositories added to and removed from an installation", %{conn: conn} do
      deliver(conn, "installation", installation_payload("created", 504, "acme", []))

      added =
        installation_payload("added", 504, "acme", [])
        |> Map.put("repositories_added", [
          %{"id" => 31, "name" => "new", "full_name" => "acme/new"}
        ])

      assert %{"outcome" => "repositories_added"} =
               json_response(deliver(build_conn(), "installation_repositories", added), 200)

      {:ok, installation} = Installation.get_external(:github, "504")
      assert {:ok, %{active: true}} = Repository.get_external(installation.id, "31")

      removed =
        installation_payload("removed", 504, "acme", [])
        |> Map.put("repositories_removed", [%{"id" => 31, "name" => "new"}])

      deliver(build_conn(), "installation_repositories", removed)
      assert {:ok, %{active: false}} = Repository.get_external(installation.id, "31")
    end

    test "repository events do not reactivate a suspended installation", %{conn: conn} do
      deliver(conn, "installation", installation_payload("created", 505, "acme", []))
      deliver(build_conn(), "installation", installation_payload("suspend", 505, "acme", []))

      added =
        installation_payload("added", 505, "acme", [])
        |> Map.put("repositories_added", [%{"id" => 41, "name" => "x", "full_name" => "acme/x"}])

      deliver(build_conn(), "installation_repositories", added)

      assert {:ok, %{status: :suspended}} = Installation.get_external(:github, "505")

      deliver(build_conn(), "installation", installation_payload("unsuspend", 505, "acme", []))
      assert {:ok, %{status: :active}} = Installation.get_external(:github, "505")
    end

    test "an opened pull request is reviewed once, however often it is delivered", %{conn: conn} do
      installation =
        installation!(%{review_new_repositories: true, default_auto_review: :on_open})

      repository = repository!(installation)
      payload = pull_request_payload(installation, repository, "opened")

      assert %{"outcome" => "created"} =
               json_response(deliver(conn, "pull_request", payload), 200)

      assert %{"outcome" => "exists"} =
               json_response(deliver(build_conn(), "pull_request", payload), 200)

      assert [%{pull_number: 7, trigger: :opened, status: :pending}] = requests(repository.id)
    end

    test "a pull request in an unknown installation records both", %{conn: conn} do
      installation = %{external_id: to_string(unique_id()), account: "newco"}
      repository = %{external_id: to_string(unique_id()), owner: "newco", name: "app"}
      payload = pull_request_payload(installation, repository, "opened")

      assert %{"outcome" => "disabled"} =
               json_response(deliver(conn, "pull_request", payload), 200)

      {:ok, recorded} = Installation.get_external(:github, installation.external_id)
      assert recorded.account == "newco"

      assert {:ok, %{name: "app", enabled: false}} =
               Repository.get_external(recorded.id, repository.external_id)
    end

    test "a review command is queued; a bot's is not", %{conn: conn} do
      installation = installation!(%{review_new_repositories: true})
      repository = repository!(installation)

      command = comment_payload(installation, repository, "/tackle review quiet", author: "ada")

      assert %{"outcome" => "command_queued"} =
               json_response(deliver(conn, "issue_comment", command), 200)

      assert_enqueued(worker: CommandJob, args: %{login: "ada", profile: :quiet, pull_number: 7})

      bot = comment_payload(installation, repository, "/tackle review", author_type: "Bot")

      assert %{"outcome" => "bot"} =
               json_response(deliver(build_conn(), "issue_comment", bot), 200)
    end

    test "refuses an oversized body, also when only its length says so", %{conn: conn} do
      payload = %{"zen" => String.duplicate("x", 5_000_001)}
      body = JSON.encode!(payload)
      oversized = deliver(conn, "ping", payload, body: body)
      assert json_response(oversized, 413) == %{"status" => "too large"}

      # Refused from the header alone: the small body is never read.
      small = JSON.encode!(%{"zen" => "x"})

      declared =
        deliver(build_conn(), "ping", nil,
          body: small,
          headers: [{"content-length", "5000001"} | headers("ping", small)]
        )

      assert json_response(declared, 413) == %{"status" => "too large"}
    end

    test "other routes still parse their bodies", %{conn: conn} do
      assert json_response(get(conn, "/health"), 200)

      unknown =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/gitlab", "{}")

      assert json_response(unknown, 404)
    end
  end
end
