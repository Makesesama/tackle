defmodule Tackle.Hub.UpdatesTest do
  use Tackle.Hub.DataCase, async: false

  import Tackle.Hub.AccountsFixtures
  import Tackle.Hub.GitHubFixtures

  alias Tackle.Hub.{CredentialStore, Repo, Updates}
  alias Tackle.Hub.Forges.Repository
  alias Tackle.Hub.Models.Provider
  alias Tackle.Hub.ReviewJob.Store
  alias Tackle.Hub.Reviews.{Dismissal, Finding, ReviewRequest, ReviewRun}

  setup do
    forge_app!()
    owner = user!()
    installation = installation!(%{owner: owner})
    repository = repository!(installation, %{enabled: true})
    %{owner: owner, installation: installation, repository: repository}
  end

  defp request!(repository, attrs \\ %{}) do
    ReviewRequest.request!(
      Map.merge(
        %{
          repository_id: repository.id,
          pull_number: 7,
          head_sha: sha("head-#{System.unique_integer()}"),
          base_sha: sha("base"),
          base_ref: "main",
          trigger: :command,
          profile: :default
        },
        attrs
      )
    )
  end

  defp subscribe(topics), do: Enum.each(topics, &(:ok = Updates.subscribe(&1)))

  defp job!(attempt \\ 1) do
    Repo.insert!(%Oban.Job{
      worker: "Tackle.Hub.Reviews.ReviewRequest.RunWorker",
      queue: "reviews",
      args: %{},
      state: "executing",
      attempt: attempt,
      max_attempts: attempt,
      attempted_at: DateTime.utc_now()
    })
  end

  test "a review request tells its own and its repository's topic", %{repository: repository} do
    subscribe([Updates.repository(repository.id)])
    request = request!(repository)
    review = Updates.review(request.id)
    repository_topic = Updates.repository(repository.id)

    assert_received {Updates, ^repository_topic}

    subscribe([review])
    ReviewRequest.skip!(request, "superseded")
    assert_received {Updates, ^review}
    assert_received {Updates, ^repository_topic}
  end

  test "bulk updates notify, as when a newer head supersedes pending requests", %{
    repository: repository
  } do
    older = request!(repository)
    subscribe([Updates.review(older.id)])

    assert :ok = ReviewRequest.skip_pending(repository.id, 7, "newer", "superseded")
    topic = Updates.review(older.id)
    assert_received {Updates, ^topic}
  end

  test "nothing is sent for a write rolled back with its transaction", %{repository: repository} do
    subscribe([Updates.repository(repository.id)])

    assert {:error, _rolled_back} =
             Ash.transact(ReviewRequest, fn ->
               request!(repository)
               {:error, :rolled_back}
             end)

    refute_received {Updates, _topic}
  end

  test "the review job's writes are sent once their transaction commits", %{
    repository: repository
  } do
    request = request!(repository)
    job = job!()
    topic = Updates.review(request.id)
    subscribe([topic])

    assert {:ok, {:claimed, _request, _repository}} = Store.claim(request.id, job)
    assert_received {Updates, ^topic}
    assert %{status: :running} = Ash.get!(ReviewRequest, request.id)

    # A stale read aborts before any write, and sends nothing.
    assert {:error, :stale} = Store.posting_snapshot(request.id, job)
    refute_received {Updates, _topic}

    assert {:ok, :ok} = Store.failed(request.id, job, "boom")
    assert_received {Updates, ^topic}
  end

  test "runs, findings, dismissals, repositories, grants, and providers", %{
    owner: owner,
    installation: installation,
    repository: repository
  } do
    request = request!(repository)
    subscribe([Updates.review(request.id)])

    run =
      ReviewRun
      |> Ash.Changeset.for_create(:create, %{
        request_id: request.id,
        summary: %{},
        usage: %{},
        duration_ms: 1,
        verdict: :clean
      })
      |> Ash.create!()

    review = Updates.review(request.id)
    assert_received {Updates, ^review}

    subscribe([Updates.run(run.id)])

    finding =
      Finding
      |> Ash.Changeset.for_create(:create, %{
        run_id: run.id,
        fingerprint: "f1",
        state: :shown,
        title: "A finding",
        category: :security,
        severity: :high,
        blocking: true,
        confidence: 0.9,
        path: "lib/a.ex",
        side: :new,
        start_line: 1,
        end_line: 1,
        trigger: "always",
        body: "Body.",
        support: 1
      })
      |> Ash.create!()

    run_topic = Updates.run(run.id)
    assert_received {Updates, ^run_topic}

    finding
    |> Ash.Changeset.for_update(:record_reactions, %{reactions_up: 1, reactions_down: 0})
    |> Ash.update!()

    assert_received {Updates, ^run_topic}

    dismissals = Updates.dismissals(repository.id)
    subscribe([dismissals])
    Dismissal.dismiss!(repository.id, "f1", %{source: :forge, by: "olivia"})
    assert_received {Updates, ^dismissals}

    installation_topic = Updates.installation(installation.id)
    installations = Updates.installations()
    repository_topic = Updates.repository(repository.id)
    subscribe([installation_topic, installations, repository_topic])

    Repository.configure!(repository, %{profile: :quiet})
    assert_received {Updates, ^repository_topic}
    assert_received {Updates, ^installation_topic}

    grant!(installation, user!())
    assert_received {Updates, ^installation_topic}
    assert_received {Updates, ^installations}

    user_topic = Updates.user(owner.id)
    subscribe([user_topic])
    Provider.register!("codex", :codex, %{owner_id: owner.id})
    assert_received {Updates, ^user_topic}

    # Credentials are written in a transaction; sent once it commits.
    handle = CredentialStore.handle(owner.id)
    assert :ok = Tackle.Lib.CredentialStore.put(handle, "codex", %{"refresh_token" => "t"})
    assert_received {Updates, ^user_topic}
  end

  test "messages carry only the topic" do
    assert Updates.topics(Tackle.Hub.Accounts.User, %{}) == []

    request = %ReviewRequest{id: "r", repository_id: "p"}
    assert Updates.topics(ReviewRequest, request) == ["review:r", "repository:p"]
  end
end
