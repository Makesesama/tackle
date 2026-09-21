defmodule Tackle.Web.Project.Source.GitHubTest do
  # The source reads global configuration — the API URL, the clone host and the
  # repositories root — so these tests are sequential.
  use ExUnit.Case, async: false

  alias Tackle.Web.GitFixture
  alias Tackle.Web.GitHubStub
  alias Tackle.Web.Project
  alias Tackle.Web.Project.Source.GitHub, as: Source

  @owner "acme"
  @name "widgets"
  @number 7

  setup do
    root = GitFixture.scratch_dir("github_source")
    repos = Path.join(root, "repos")
    host = Path.join(root, "host")
    GitFixture.hosted(host, @owner, @name, @number)

    previous = %{
      repos_root: Application.get_env(:tackle_web, :repos_root),
      github_host: Application.get_env(:tackle_web, :github_host)
    }

    Application.put_env(:tackle_web, :repos_root, repos)
    Application.put_env(:tackle_web, :github_host, "file://#{host}")

    on_exit(fn ->
      restore(:repos_root, previous.repos_root)
      restore(:github_host, previous.github_host)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  describe "build/1" do
    test "describes a repository by its default branch" do
      GitHubStub.start(repository_payload())

      assert {:ok, fields} = Source.build(%{"locator" => "#{@owner}/#{@name}"})
      assert fields.kind == :github
      assert fields.locator == "#{@owner}/#{@name}"
      assert fields.name == @name
      assert fields.default_branch == "main"
    end

    test "accepts a repository URL" do
      GitHubStub.start(repository_payload())

      assert {:ok, fields} =
               Source.build(%{"locator" => "https://github.com/#{@owner}/#{@name}.git"})

      assert fields.locator == "#{@owner}/#{@name}"
    end

    test "rejects input that is not an owner/name" do
      assert {:error, message} = Source.build(%{"locator" => "not a repo"})
      assert message =~ "Expected a repository"
    end

    test "reports a repository GitHub does not have" do
      GitHubStub.start({404, ~s({"message": "Not Found"})})

      assert {:error, message} = Source.build(%{"locator" => "#{@owner}/#{@name}"})
      assert message =~ "no such repository"
    end
  end

  describe "list_reviews/1" do
    test "offers the open pull requests" do
      GitHubStub.start(JSON.encode!([pull_map()]))

      assert {:ok, [summary]} = Source.list_reviews(project())
      assert summary.review_id == "pr-#{@number}"
      assert summary.title == "Teach the widget to spin"
      assert summary.author == "contributor"
      assert summary.base_ref == "main"
      assert summary.head_ref == "feature"
    end
  end

  describe "checkout/1" do
    test "clones the repository at its default branch" do
      assert {:ok, path} = Source.checkout(project())

      assert path ==
               Path.join(Application.fetch_env!(:tackle_web, :repos_root), "#{@owner}/#{@name}")

      assert File.dir?(Path.join(path, ".git"))
      assert File.exists?(Path.join(path, "lib/keep.ex"))
    end
  end

  describe "load_review/2" do
    test "loads the pull request's diff from its own clone" do
      GitHubStub.start(JSON.encode!(pull_map()))

      assert {:ok, review} = Source.load_review(project(), "pr-#{@number}")

      assert review.review_id == "pr-#{@number}"
      assert review.title == "Teach the widget to spin"
      assert review.base_ref == "main"
      assert review.head_ref == "feature"
      assert review.pull.number == @number
      assert review.project.kind == :github
      assert Enum.any?(review.diff.files, &(&1.path == "lib/from_the_pull_request.ex"))
    end

    test "rejects a review id that is not a pull request" do
      assert {:error, message} = Source.load_review(project(), "main..feature")
      assert message =~ "reviews pull requests"
    end
  end

  test "branches/1 offers nothing: a GitHub project's reviews are pull requests" do
    assert Source.branches(project()) == {:ok, []}
  end

  defp project do
    %Project{
      slug: "github-#{@owner}-#{@name}-a1b2c3",
      kind: :github,
      locator: "#{@owner}/#{@name}",
      name: @name,
      default_branch: "main"
    }
  end

  defp repository_payload do
    JSON.encode!(%{
      "default_branch" => "main",
      "private" => false,
      "description" => "Widgets",
      "html_url" => "https://example.test/#{@owner}/#{@name}"
    })
  end

  defp pull_map do
    %{
      "number" => @number,
      "title" => "Teach the widget to spin",
      "state" => "open",
      "draft" => false,
      "additions" => 2,
      "deletions" => 0,
      "changed_files" => 1,
      "user" => %{"login" => "contributor"},
      "base" => %{"ref" => "main", "sha" => "basesha"},
      "head" => %{"ref" => "feature", "sha" => "headsha"}
    }
  end

  defp restore(key, nil), do: Application.delete_env(:tackle_web, key)
  defp restore(key, value), do: Application.put_env(:tackle_web, key, value)
end
