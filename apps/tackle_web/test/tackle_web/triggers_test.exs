defmodule Tackle.Web.TriggersTest do
  use Tackle.Web.DataCase, async: true
  use Oban.Testing, repo: Tackle.Web.Repo

  import Tackle.Web.GitHubFixtures

  require Ash.Query

  alias Tackle.Web.Forges.Repository
  alias Tackle.Web.Repo
  alias Tackle.Web.Reviews.ReviewRequest
  alias Tackle.Web.Triggers
  alias Tackle.Web.Triggers.CommandJob

  defp pull_request(attrs \\ %{}) do
    Map.merge(
      %{
        number: 7,
        state: :open,
        draft: false,
        head_sha: sha("head"),
        base_sha: sha("base"),
        base_ref: "main",
        head_is_fork: false,
        author: "octocat"
      },
      attrs
    )
  end

  defp repository_with(settings) do
    repository!(installation!(), Map.merge(%{enabled: true}, settings))
  end

  defp requests(repository) do
    ReviewRequest
    |> Ash.Query.filter(repository_id == ^repository.id)
    |> Ash.Query.sort(:inserted_at)
    |> Ash.read!()
  end

  describe "automatic reviews" do
    test "on_open reviews opened, reopened, and ready pull requests, not pushes" do
      repository = repository_with(%{auto_review: :on_open, profile: :quiet})

      assert {:ok, :created, request} =
               Triggers.pull_request(repository, :opened, pull_request(), "octocat")

      assert %{trigger: :opened, profile: :quiet, status: :pending, requested_by: "octocat"} =
               request

      assert request.head_sha == sha("head")
      assert request.base_ref == "main"

      for action <- [:reopened, :ready_for_review] do
        assert {:ok, :exists, _request} =
                 Triggers.pull_request(repository, action, pull_request(), "octocat")
      end

      new_head = pull_request(%{head_sha: sha("next")})

      assert {:ok, :not_automatic, nil} =
               Triggers.pull_request(repository, :synchronize, new_head, "octocat")
    end

    test "on_open_and_push reviews every new head" do
      repository = repository_with(%{auto_review: :on_open_and_push})

      assert {:ok, :created, %{trigger: :pushed}} =
               Triggers.pull_request(repository, :synchronize, pull_request(), "octocat")
    end

    test "off, disabled, and inaccessible repositories are not reviewed" do
      off = repository_with(%{auto_review: :off})
      assert {:ok, :not_automatic, nil} = Triggers.pull_request(off, :opened, pull_request(), nil)

      disabled = repository_with(%{enabled: false, auto_review: :on_open})
      assert {:ok, :disabled, nil} = Triggers.pull_request(disabled, :opened, pull_request(), nil)

      inactive = repository_with(%{auto_review: :on_open})
      inactive = Repository.deactivate!(inactive)
      assert {:ok, :disabled, nil} = Triggers.pull_request(inactive, :opened, pull_request(), nil)
    end

    test "drafts and forks only when the repository allows them" do
      repository = repository_with(%{auto_review: :on_open})
      draft = pull_request(%{draft: true})
      fork = pull_request(%{head_is_fork: true})

      assert {:ok, :draft, nil} = Triggers.pull_request(repository, :opened, draft, nil)
      assert {:ok, :fork, nil} = Triggers.pull_request(repository, :opened, fork, nil)

      allowing =
        repository_with(%{
          auto_review: :on_open,
          auto_review_drafts: true,
          auto_review_forks: true
        })

      assert {:ok, :created, _request} = Triggers.pull_request(allowing, :opened, draft, nil)

      assert {:ok, :created, %{head_is_fork: true}} =
               Triggers.pull_request(allowing, :opened, %{fork | head_sha: sha("fork")}, nil)
    end

    test "a new head skips pending requests for older heads" do
      repository = repository_with(%{auto_review: :on_open_and_push})
      {:ok, :created, old} = Triggers.pull_request(repository, :opened, pull_request(), nil)

      {:ok, :created, new} =
        Triggers.pull_request(
          repository,
          :synchronize,
          pull_request(%{head_sha: sha("new")}),
          nil
        )

      assert [
               %{id: old_id, status: :skipped, error: "superseded by " <> short},
               %{status: :pending}
             ] =
               requests(repository)

      assert old_id == old.id
      assert String.starts_with?(sha("new"), short)
      assert new.status == :pending
    end

    test "other pull requests and finished requests are not superseded" do
      repository = repository_with(%{auto_review: :on_open_and_push})

      {:ok, :created, other} =
        Triggers.pull_request(repository, :opened, pull_request(%{number: 8}), nil)

      {:ok, :created, _first} = Triggers.pull_request(repository, :opened, pull_request(), nil)

      assert {:ok, :created, _new} =
               Triggers.pull_request(
                 repository,
                 :synchronize,
                 pull_request(%{head_sha: sha("new")}),
                 nil
               )

      assert Ash.get!(ReviewRequest, other.id).status == :pending
    end

    test "closing skips pending requests; reopening the same head runs it again" do
      repository = repository_with(%{auto_review: :on_open})
      {:ok, :created, request} = Triggers.pull_request(repository, :opened, pull_request(), nil)

      assert {:ok, :closed, nil} =
               Triggers.pull_request(repository, :closed, pull_request(%{state: :closed}), nil)

      assert %{status: :skipped, error: "the pull request was closed"} =
               Ash.get!(ReviewRequest, request.id)

      assert {:ok, :rerun, %{id: id, status: :pending, error: nil}} =
               Triggers.pull_request(repository, :reopened, pull_request(), nil)

      assert id == request.id
    end
  end

  describe "commands" do
    test "a review command queues the permission check" do
      repository = repository_with(%{})

      comment = %{
        pull_number: 7,
        body: "/tackle review assertive",
        author: "ada",
        author_is_bot: false
      }

      assert {:ok, :command_queued, nil} = Triggers.comment(repository, comment)

      assert_enqueued(
        worker: CommandJob,
        args: %{repository_id: repository.id, pull_number: 7, login: "ada", profile: :assertive}
      )
    end

    test "other comments, bots, malformed commands, and disabled repositories queue nothing" do
      repository = repository_with(%{})
      comment = %{pull_number: 7, body: "/tackle review", author: "ada", author_is_bot: false}

      assert {:ok, :not_a_command, nil} = Triggers.comment(repository, %{comment | body: "LGTM"})
      assert {:ok, :bot, nil} = Triggers.comment(repository, %{comment | author_is_bot: true})

      assert {:ok, {:invalid_command, {:unknown_profile, "loud"}}, nil} =
               Triggers.comment(repository, %{comment | body: "/tackle review loud"})

      disabled = repository_with(%{enabled: false})
      assert {:ok, :disabled, nil} = Triggers.comment(disabled, comment)

      refute_enqueued(worker: CommandJob)
    end

    test "commands review forks and drafts whatever auto_review says" do
      repository = repository_with(%{auto_review: :off})
      pull_request = pull_request(%{draft: true, head_is_fork: true})

      assert {:ok, :created, %{trigger: :command, requested_by: "ada", profile: :default}} =
               Triggers.command(repository, pull_request, nil, "ada")
    end

    test "a command on a closed pull request does nothing" do
      repository = repository_with(%{})

      assert {:ok, :closed, nil} =
               Triggers.command(repository, pull_request(%{state: :closed}), nil, "ada")
    end

    test "a command after an automatic review of the same head is a no-op" do
      repository = repository_with(%{auto_review: :on_open})
      {:ok, :created, request} = Triggers.pull_request(repository, :opened, pull_request(), nil)

      assert {:ok, :exists, %{id: id}} = Triggers.command(repository, pull_request(), nil, "ada")
      assert id == request.id
    end

    test "a command reruns a failed or skipped head, and a posted one with another profile" do
      repository = repository_with(%{})
      {:ok, :created, request} = Triggers.command(repository, pull_request(), nil, "ada")

      for status <- [:failed, :skipped] do
        set_status(request, status)

        assert {:ok, :rerun, %{status: :pending, requested_by: "bob"}} =
                 Triggers.command(repository, pull_request(), nil, "bob")
      end

      set_status(request, :posted)

      assert {:ok, :exists, _request} =
               Triggers.command(repository, pull_request(), :default, "bob")

      assert {:ok, :rerun, %{profile: :assertive, status: :pending}} =
               Triggers.command(repository, pull_request(), :assertive, "bob")

      assert [_one] = requests(repository)
    end
  end

  describe "ReviewRequest" do
    test "requesting an existing head returns the existing request unchanged" do
      repository = repository_with(%{})
      {:ok, :created, request} = Triggers.command(repository, pull_request(), :quiet, "ada")

      again =
        ReviewRequest.request!(%{
          repository_id: repository.id,
          pull_number: 7,
          head_sha: sha("head"),
          base_sha: sha("other base"),
          base_ref: "other",
          trigger: :opened,
          profile: :assertive
        })

      assert again.id == request.id
      assert %{base_ref: "main", trigger: :command, profile: :quiet} = again
    end

    test "only a finished request runs again" do
      repository = repository_with(%{})
      {:ok, :created, request} = Triggers.command(repository, pull_request(), nil, "ada")

      assert {:error, error} =
               ReviewRequest.rerun(request, %{trigger: :command, profile: :quiet})

      assert Exception.message(error) =~ "only a finished request can run again"
    end
  end

  # The statuses after :pending are set by the review job (phase 4), which
  # has no action yet; set them directly.
  defp set_status(request, status) do
    Repo.query!("update review_requests set status = $1 where id = $2", [
      Atom.to_string(status),
      Ecto.UUID.dump!(request.id)
    ])
  end
end
