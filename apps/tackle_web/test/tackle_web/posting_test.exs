defmodule Tackle.Web.PostingTest do
  use Tackle.Web.DataCase, async: false

  import Tackle.Web.GitHubFixtures

  alias Tackle.Review.{Finding, Result}
  alias Tackle.Web.Forge.GitHub
  alias Tackle.Web.Forges.Repository
  alias Tackle.Web.{Posting, Repo, ReviewJob}
  alias Tackle.Web.ReviewJob.Store
  alias Tackle.Web.Reviews.Finding, as: StoredFinding
  alias Tackle.Web.Reviews.{ReviewRequest, ReviewRun}
  alias Tackle.Web.Triggers

  setup do
    forge_app!()
    repository = repository!(installation!(), %{enabled: true})

    remote =
      start_supervised!(
        {Agent,
         fn ->
           %{
             reviews: [],
             posts: 0,
             reads: [],
             head: sha("head"),
             base: sha("base"),
             lose_response: false,
             fail_comments: false,
             fail_post: false,
             fail_lookup: false,
             move_head: false
           }
         end}
      )

    Req.Test.stub(GitHub, &respond(&1, remote))
    {:ok, repository: repository, remote: remote}
  end

  test "stores review/comment IDs; shown out-of-diff findings go in the body", c do
    {request, job, run} = reviewed(c.repository, [finding("inline"), finding("body", 50)])
    assert :ok = Posting.post(request, c.repository, job)
    posted = Ash.get!(ReviewRequest, request.id)
    assert posted.status == :posted
    assert posted.forge_review_id == "100"
    [review] = state(c).reviews
    assert review["event"] == "COMMENT"
    assert review["commit_id"] == request.head_sha
    assert String.starts_with?(review["body"], "<!-- tackle-review:#{run.id} -->")
    assert review["body"] =~ "body"
    assert review["body"] =~ "3 units reviewed"
    assert [%{"side" => "RIGHT", "line" => 2, "id" => 1000}] = review["comments"]
    findings = Ash.load!(run, :findings).findings |> Map.new(&{&1.title, &1})
    assert findings["inline"].forge_comment_id == "1000"
    assert findings["body"].forge_comment_id == nil

    assert MapSet.new(Ash.get!(ReviewRun, run.id).summary["posting"]["fingerprints"]) ==
             MapSet.new([fingerprint("inline"), fingerprint("body")])

    # A stale invocation cannot call the forge, even with the old struct.
    assert :ok = Posting.post(request, c.repository, job)
    assert state(c).posts == 1
  end

  test "lost response is recovered by marker without another POST or model calls", c do
    {request, job, run} = reviewed(c.repository, [finding("inline")])
    Agent.update(c.remote, &%{&1 | lose_response: true})
    assert {:error, message} = Posting.post(request, c.repository, job)
    assert message == Store.posting_error()
    assert Ash.get!(ReviewRequest, request.id).status == :reviewed
    frozen = Ash.get!(ReviewRun, run.id).summary["posting"]
    assert state(c).posts == 1

    # Diff reads are not needed on recovery: the payload was frozen before POST.
    Agent.update(c.remote, &%{&1 | head: sha("new"), reads: []})
    assert :ok = ReviewJob.run(%{request_id: request.id, job: retry!(job)})
    assert state(c).posts == 1
    refute "/repos/acme/widgets/pulls/7/files" in state(c).reads
    assert Ash.get!(ReviewRun, run.id).summary["posting"]["body"] == frozen["body"]
    assert Ash.get!(ReviewRequest, request.id).forge_review_id == "100"
    assert [%{forge_comment_id: "1000"}] = Ash.read!(StoredFinding)
  end

  test "failure listing comments retries recovery, not review creation", c do
    {request, job, _run} = reviewed(c.repository, [finding("inline")])
    Agent.update(c.remote, &%{&1 | fail_comments: true})
    assert {:error, _} = Posting.post(request, c.repository, job)
    assert Ash.get!(ReviewRequest, request.id).status == :reviewed
    Agent.update(c.remote, &%{&1 | fail_comments: false})
    assert :ok = ReviewJob.run(%{request_id: request.id, job: retry!(job)})
    assert state(c).posts == 1
  end

  test "lookup failure never falls through to POST; errors are redacted", c do
    {request, job, _run} = reviewed(c.repository, [])
    Agent.update(c.remote, &%{&1 | fail_lookup: true})
    assert {:error, message} = Posting.post(request, c.repository, job)
    assert message == Store.posting_error()
    refute message =~ "secret"
    assert state(c).posts == 0
  end

  test "body-only and inline fingerprints survive later heads and same-request reruns", c do
    findings = [finding("inline"), finding("body", 50)]
    {request, job, _run} = reviewed(c.repository, findings)
    assert :ok = Posting.post(request, c.repository, job)

    {second, job2, _run2} = reviewed(c.repository, [finding("new", 50) | findings], "head2")
    assert :ok = Posting.post(second, c.repository, job2)
    [_, posted] = state(c).reviews
    assert posted["comments"] == []
    assert posted["body"] =~ "Still present"
    assert posted["body"] =~ "2 already reported"
    assert posted["body"] =~ "<!-- tackle-finding:#{fingerprint("new")} -->"
    refute posted["body"] =~ "<!-- tackle-finding:#{fingerprint("body")} -->"

    request = ReviewRequest.rerun!(Ash.get!(ReviewRequest, request.id), %{})
    {request, job3, _run3} = complete(request, findings)
    assert :ok = Posting.post(request, c.repository, job3)
    assert List.last(state(c).reviews)["body"] =~ "2 already reported"
    assert List.last(state(c).reviews)["comments"] == []
  end

  test "an unresolved earlier POST is reconciled before a newer head posts", c do
    {request, job, _run} = reviewed(c.repository, [finding("inline")])
    Agent.update(c.remote, &%{&1 | lose_response: true})
    assert {:error, _} = Posting.post(request, c.repository, job)
    {next, job2, _run2} = reviewed(c.repository, [finding("inline")], "head2")
    assert :ok = Posting.post(next, c.repository, job2)
    assert List.last(state(c).reviews)["body"] =~ "1 already reported"
    assert List.last(state(c).reviews)["comments"] == []
    assert :ok = ReviewJob.run(%{request_id: request.id, job: retry!(job)})
    assert state(c).posts == 2
  end

  test "a prepared but unsent review blocks later posting until it is retried", c do
    {request, job, _run} = reviewed(c.repository, [finding("inline")])
    Agent.update(c.remote, &%{&1 | fail_post: true})
    assert {:error, _} = Posting.post(request, c.repository, job)
    {next, job2, run2} = reviewed(c.repository, [finding("inline")], "head2")
    Agent.update(c.remote, &%{&1 | fail_post: false})
    assert {:error, _} = Posting.post(next, c.repository, job2)
    assert Ash.get!(ReviewRun, run2.id).summary["posting"] == nil
    assert :ok = ReviewJob.run(%{request_id: request.id, job: retry!(job)})
    assert :ok = ReviewJob.run(%{request_id: next.id, job: retry!(job2)})
    assert List.last(state(c).reviews)["comments"] == []
  end

  test "stale head, changed base and a push during files read all use body-only comments", c do
    for {seed, remote_changes} <- [
          {"stale", %{head: sha("new")}},
          {"base", %{head: sha("base"), base: sha("changed-base")}},
          {"moving", %{head: sha("moving"), base: sha("base"), move_head: true}}
        ] do
      Agent.update(c.remote, &Map.merge(&1, remote_changes))
      {request, job, _run} = reviewed(c.repository, [finding(seed)], seed)
      assert :ok = Posting.post(request, c.repository, job)
      posted = List.last(state(c).reviews)
      assert posted["comments"] == []
      assert posted["body"] =~ seed
      assert posted["commit_id"] == request.head_sha
    end
  end

  test "disabled repositories retain paid results, and a re-enable permits posting", c do
    {request, job, _run} = reviewed(c.repository, [])
    Repository.configure!(c.repository, %{enabled: false})
    assert {:error, _} = Posting.post(request, c.repository, job)
    assert state(c).reads == []
    assert Ash.get!(ReviewRequest, request.id).status == :reviewed
    Repository.configure!(c.repository, %{enabled: true, daily_token_budget: 1})
    assert :ok = ReviewJob.run(%{request_id: request.id, job: retry!(job)})
  end

  test "disabling an integration during lookup prevents submission", c do
    {request, job, _run} = reviewed(c.repository, [finding("inline")])

    Req.Test.stub(GitHub, fn conn ->
      if conn.method == "GET" and String.ends_with?(conn.request_path, "/reviews") do
        Repository.configure!(c.repository, %{enabled: false})
      end

      respond(conn, c.remote)
    end)

    assert {:error, _} = Posting.post(request, c.repository, job)
    assert state(c).posts == 0
    assert Ash.get!(ReviewRequest, request.id).status == :reviewed
  end

  test "deduplication is isolated to the repository and pull request", c do
    {request, job, _run} = reviewed(c.repository, [finding("inline")])
    assert :ok = Posting.post(request, c.repository, job)
    other = repository!(installation!(%{account: "other"}), %{enabled: true})
    {request, job, _run} = reviewed(other, [finding("inline")])
    assert :ok = Posting.post(request, other, job)
    assert [_comment] = List.last(state(c).reviews)["comments"]
  end

  test "a command retries exhausted posting without replacing the stored run", c do
    {request, job, run} = reviewed(c.repository, [])
    job = job |> Ecto.Changeset.change(attempt: 3) |> Repo.update!()

    Repo.query!("UPDATE review_requests SET claimed_attempt = 3 WHERE id = $1", [
      Ecto.UUID.dump!(request.id)
    ])

    assert {:ok, :ok} = Store.failed(request.id, job, "ignored upstream secret")
    job |> Ecto.Changeset.change(state: "discarded") |> Repo.update!()
    pull = %{state: :open, number: 7, head_sha: request.head_sha}

    assert {:ok, :exists, %{status: :reviewed}} =
             Triggers.command(c.repository, pull, nil, "ada")

    assert [%{id: id}] = Ash.read!(ReviewRun)
    assert id == run.id
  end

  test "a rerun during marker lookup fences the mutation and abandons the unsent intent", c do
    {request, job, _run} = reviewed(c.repository, [finding("inline")])

    Req.Test.stub(GitHub, fn conn ->
      if conn.method == "GET" and String.ends_with?(conn.request_path, "/reviews") do
        ReviewRequest.rerun!(Ash.get!(ReviewRequest, request.id), %{})
      end

      respond(conn, c.remote)
    end)

    assert :ok = Posting.post(request, c.repository, job)
    assert state(c).posts == 0
    assert Ash.get!(ReviewRequest, request.id).status == :pending

    Req.Test.stub(GitHub, &respond(&1, c.remote))
    {request, job, _run} = complete(Ash.get!(ReviewRequest, request.id), [finding("inline")])
    assert :ok = Posting.post(request, c.repository, job)
    assert state(c).posts == 1
  end

  test "overlapping heads serialize fingerprint lookup and submission", c do
    {request, job, _run} = reviewed(c.repository, [finding("inline")])
    {next, next_job, _run2} = reviewed(c.repository, [finding("inline")], "head2")

    tasks =
      for {request, job} <- [{request, job}, {next, next_job}] do
        Task.async(fn -> Posting.post(request, c.repository, job) end)
      end

    assert Enum.map(tasks, &Task.await(&1, 10_000)) == [:ok, :ok]
    assert state(c).posts == 2
    bodies = Enum.map(state(c).reviews, & &1["body"])
    assert Enum.count(bodies, &String.contains?(&1, "1 already reported")) == 1
  end

  defp state(c),
    do: Agent.get(c.remote, &Map.update!(&1, :reviews, fn reviews -> Enum.reverse(reviews) end))

  defp reviewed(repository, findings, head \\ "head") do
    request =
      ReviewRequest.request!(%{
        repository_id: repository.id,
        pull_number: 7,
        head_sha: sha(head),
        base_sha: sha("base"),
        base_ref: "main",
        trigger: :command,
        profile: :default
      })

    complete(request, findings)
  end

  defp complete(request, findings) do
    job =
      Repo.insert!(%Oban.Job{
        worker: "Tackle.Web.Reviews.ReviewRequest.RunWorker",
        queue: "reviews",
        args: %{},
        state: "executing",
        attempt: 1,
        max_attempts: 3
      })

    assert {:ok, {:claimed, _, _}} = Store.claim(request.id, job)

    result = %Result{
      blocking: findings,
      summary: %{verdict: :blocking, units: 3},
      usage: %{total_tokens: 123}
    }

    assert {:ok, :ok} = Store.complete(request.id, job, result, 1)
    {:ok, snapshot} = Store.posting_snapshot(request.id, job)
    {snapshot.request, job, snapshot.run}
  end

  defp retry!(job),
    do: job |> Ecto.Changeset.change(attempt: job.attempt + 1) |> Repo.update!()

  defp fingerprint(title), do: :crypto.hash(:md5, title) |> Base.encode16(case: :lower)

  defp finding(title, line \\ 2) do
    %Finding{
      title: title,
      category: :correctness,
      severity: :high,
      blocking: true,
      confidence: 0.95,
      location: %{path: "lib/a.ex", side: :new, start_line: line, end_line: line},
      trigger: "missing key",
      body: "raises @org/team fixes #123 <script>",
      support: 2,
      verdict: :confirmed,
      fingerprint: fingerprint(title)
    }
  end

  defp respond(conn, remote) do
    Agent.update(remote, &Map.update!(&1, :reads, fn reads -> [conn.request_path | reads] end))
    state = Agent.get(remote, & &1)

    cond do
      conn.request_path == "/app" ->
        Req.Test.json(conn, %{"slug" => "tackle"})

      String.starts_with?(conn.request_path, "/app/installations/") ->
        Req.Test.json(conn, %{
          "token" => "test-token",
          "expires_at" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
        })

      String.ends_with?(conn.request_path, "/reviews") ->
        reviews(conn, remote, state)

      String.ends_with?(conn.request_path, "/comments") ->
        if state.fail_comments do
          failure(conn)
        else
          id = conn.request_path |> String.split("/") |> Enum.at(-2) |> String.to_integer()
          review = Enum.find(state.reviews, &(&1["id"] == id))
          Req.Test.json(conn, review["comments"])
        end

      String.ends_with?(conn.request_path, "/files") ->
        if state.move_head, do: Agent.update(remote, &%{&1 | head: sha("moved")})

        Req.Test.json(conn, [
          %{"filename" => "lib/a.ex", "patch" => "@@ -1,2 +1,2 @@\n context\n-old\n+new"}
        ])

      true ->
        Req.Test.json(conn, %{
          "number" => 7,
          "state" => "open",
          "head" => %{"sha" => state.head, "repo" => %{"id" => 1}},
          "base" => %{"sha" => state.base, "ref" => "main", "repo" => %{"id" => 1}}
        })
    end
  end

  defp reviews(%{method: "GET"} = conn, _remote, state) do
    if state.fail_lookup,
      do: failure(conn),
      else: Req.Test.json(conn, Enum.reverse(state.reviews))
  end

  defp reviews(conn, remote, state) do
    if state.fail_post do
      failure(conn)
    else
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = JSON.decode!(body)
      id = 100 + state.posts
      comments = Enum.with_index(payload["comments"], &Map.put(&1, "id", id * 10 + &2))

      review =
        Map.merge(payload, %{
          "id" => id,
          "comments" => comments,
          "user" => %{"login" => "tackle[bot]", "type" => "Bot"}
        })

      Agent.update(
        remote,
        &%{&1 | reviews: [review | &1.reviews], posts: &1.posts + 1, lose_response: false}
      )

      if state.lose_response,
        do: Req.Test.transport_error(conn, :timeout),
        else: Req.Test.json(conn, %{"id" => id})
    end
  end

  defp failure(conn),
    do: conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"message" => "private secret"})
end
