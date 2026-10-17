defmodule Tackle.Web.FeedbackTest do
  @moduledoc """
  Feedback on posted findings (docs/TACKLE_WEB_PLAN.md §7.13): resolved
  review threads, through the webhook and the job, and reactions.
  """

  use Tackle.Web.ConnCase, async: false
  use Oban.Testing, repo: Tackle.Web.Repo

  import Tackle.Web.GitHubFixtures

  alias Tackle.Web.Feedback
  alias Tackle.Web.Feedback.Job
  alias Tackle.Web.Forge.GitHub
  alias Tackle.Web.Reviews.{Dismissal, Finding, ReviewRequest, ReviewRun}

  setup do
    forge_app!()
    installation = installation!()
    repository = repository!(installation, %{enabled: true})
    finding = posted_finding!(repository, "1001", "fp-cache")
    {:ok, installation: installation, repository: repository, finding: finding}
  end

  # A finding tackle posted as the line comment `comment_id` on pull request 7.
  defp posted_finding!(repository, comment_id, fingerprint) do
    request =
      ReviewRequest.request!(%{
        repository_id: repository.id,
        pull_number: 7,
        head_sha: sha("head-#{fingerprint}"),
        base_sha: sha("base"),
        base_ref: "main",
        trigger: :command,
        profile: :default
      })

    run =
      ReviewRun
      |> Ash.Changeset.for_create(:create, %{
        request_id: request.id,
        summary: %{},
        usage: %{},
        duration_ms: 1,
        verdict: :blocking
      })
      |> Ash.create!()

    finding =
      Finding
      |> Ash.Changeset.for_create(:create, %{
        run_id: run.id,
        fingerprint: fingerprint,
        state: :shown,
        title: "Cache key ignores the tenant",
        category: :security,
        severity: :high,
        blocking: true,
        confidence: 0.9,
        path: "lib/cache.ex",
        side: :new,
        start_line: 1,
        end_line: 1,
        trigger: "always",
        body: "Body.",
        support: 1
      })
      |> Ash.create!()

    finding
    |> Ash.Changeset.for_update(:record_comment, %{forge_comment_id: comment_id})
    |> Ash.update!()
  end

  defp thread_payload(installation, repository, action, comment_ids, sender \\ "ada") do
    %{
      "action" => action,
      "installation" => %{"id" => String.to_integer(installation.external_id)},
      "repository" => repository_payload(repository),
      "pull_request" => %{"number" => 7},
      "thread" => %{
        "node_id" => "PRRT_1",
        "comments" =>
          Enum.map(comment_ids, &%{"id" => &1, "body" => "<!-- tackle-finding:fp-cache -->"})
      },
      "sender" => %{"login" => sender, "type" => "User"}
    }
  end

  defp deliver(conn, event, payload) do
    body = JSON.encode!(payload)

    headers(event, body)
    |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> post("/webhooks/github", body)
  end

  defp stub_github(permission, comments \\ []) do
    expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    Req.Test.stub(GitHub, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _rest ->
          Req.Test.json(conn, %{"token" => "ghs_test", "expires_at" => expires_at})

        "/repos/acme/widgets/collaborators/" <> _rest ->
          Req.Test.json(conn, %{"permission" => permission})

        # A one-page list, answered like the installations list.
        "/repos/acme/widgets/pulls/7/comments" ->
          installations_page(conn, comments)
      end
    end)
  end

  describe "resolved review threads" do
    test "a thread of tackle's comment is queued; anything else is not", %{
      conn: conn,
      installation: installation,
      repository: repository
    } do
      ours = thread_payload(installation, repository, "resolved", [1001, 5])

      assert %{"outcome" => "feedback_queued"} =
               conn |> deliver("pull_request_review_thread", ours) |> json_response(200)

      assert_enqueued(
        worker: Job,
        args: %{kind: "thread", comment_ids: ["1001", "5"], action: "resolved", login: "ada"}
      )

      # A marker in someone else's comment does not make it tackle's.
      theirs = thread_payload(installation, repository, "resolved", [5])

      assert %{"outcome" => "not_ours"} =
               build_conn() |> deliver("pull_request_review_thread", theirs) |> json_response(200)
    end

    test "someone with write access dismisses the finding, and restores it", %{
      repository: repository,
      finding: finding
    } do
      stub_github("write")
      args = %{kind: "thread", repository_id: repository.id, comment_ids: ["1001"], login: "ada"}

      assert :ok = perform_job(Job, Map.put(args, :action, "resolved"))

      assert {:ok, %Dismissal{source: :forge, by: "ada", pull_number: 7, title: title}} =
               Dismissal.get(repository.id, finding.fingerprint)

      assert title == finding.title
      assert Feedback.dismissed_fingerprints(repository.id) == [finding.fingerprint]

      # A redelivery changes nothing.
      assert :ok = perform_job(Job, Map.put(args, :action, "resolved"))
      assert [_one] = Ash.read!(Dismissal)

      assert :ok = perform_job(Job, Map.put(args, :action, "unresolved"))
      assert Ash.read!(Dismissal) == []
      assert :ok = perform_job(Job, Map.put(args, :action, "unresolved"))
    end

    test "without write access (a pull request's author) nothing changes", %{
      repository: repository
    } do
      stub_github("read")

      args = %{
        kind: "thread",
        repository_id: repository.id,
        comment_ids: ["1001"],
        login: "author",
        action: "resolved"
      }

      assert {:cancel, reason} = perform_job(Job, args)
      assert reason =~ "no write access"
      assert Ash.read!(Dismissal) == []
    end

    test "a comment id of another repository does not count", %{installation: installation} do
      other = repository!(installation)
      stub_github("write")

      args = %{
        kind: "thread",
        repository_id: other.id,
        comment_ids: ["1001"],
        login: "ada",
        action: "resolved"
      }

      assert {:cancel, _reason} = perform_job(Job, args)
      assert Ash.read!(Dismissal) == []
    end

    test "bots' thread changes are ignored" do
      payload = %{
        "action" => "resolved",
        "sender" => %{"login" => "other[bot]", "type" => "Bot"}
      }

      assert {:ok, %{type: :ignored}} = GitHub.parse_event("pull_request_review_thread", payload)
    end
  end

  describe "reactions" do
    test "a new head of a pull request with posted comments queues reading them", %{
      conn: conn,
      installation: installation,
      repository: repository
    } do
      payload =
        pull_request_payload(installation, repository, "synchronize", %{"number" => 7})

      assert json_response(deliver(conn, "pull_request", payload), 200)
      assert_enqueued(worker: Job, args: %{kind: "reactions", pull_number: 7})

      other = pull_request_payload(installation, repository, "closed", %{"number" => 8})
      assert json_response(deliver(build_conn(), "pull_request", other), 200)
      refute_enqueued(worker: Job, args: %{kind: "reactions", pull_number: 8})
    end

    test "the counts are stored on the posted findings", %{
      repository: repository,
      finding: finding
    } do
      stub_github("write", [
        %{"id" => 1001, "reactions" => %{"+1" => 3, "-1" => 1, "laugh" => 2}},
        %{"id" => 2002, "reactions" => %{"+1" => 9}},
        %{"id" => 3003}
      ])

      args = %{kind: "reactions", repository_id: repository.id, pull_number: 7}
      assert :ok = perform_job(Job, args)
      assert %{reactions_up: 3, reactions_down: 1} = Ash.get!(Finding, finding.id)
      # Reactions never dismiss anything.
      assert Ash.read!(Dismissal) == []
    end
  end
end
