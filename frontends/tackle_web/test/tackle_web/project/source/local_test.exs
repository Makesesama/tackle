defmodule Tackle.Web.Project.Source.LocalTest do
  use ExUnit.Case, async: true

  alias Tackle.Web.GitFixture
  alias Tackle.Web.Project
  alias Tackle.Web.Project.Source.Local

  setup do
    repo = GitFixture.build()

    on_exit(fn -> File.rm_rf(repo) end)

    {:ok, repo: repo}
  end

  describe "build/1" do
    test "describes a git repository by its path", %{repo: repo} do
      assert {:ok, fields} = Local.build(%{"locator" => repo})

      assert fields.kind == :local
      assert fields.locator == repo
      assert fields.name == Path.basename(repo)
      assert fields.default_branch == "main"
    end

    test "expands a relative path", %{repo: repo} do
      relative = Path.relative_to(repo, File.cwd!())

      assert {:ok, fields} = Local.build(%{"locator" => relative})
      assert fields.locator == repo
    end

    test "asks for a path when the form is empty" do
      assert {:error, message} = Local.build(%{"locator" => "  "})
      assert message =~ "Enter the path"
    end

    test "refuses a path that is not a directory" do
      assert {:error, message} = Local.build(%{"locator" => "/nope/nothing/here"})
      assert message =~ "not a directory"
    end

    test "refuses a directory that is not a git repository" do
      plain = GitFixture.scratch_dir("plain")
      File.mkdir_p!(plain)
      on_exit(fn -> File.rm_rf(plain) end)

      assert {:error, message} = Local.build(%{"locator" => plain})
      assert message =~ "not a git repository"
    end
  end

  describe "checkout/1" do
    test "is the repository itself", %{repo: repo} do
      assert {:ok, path} = Local.checkout(project(repo))
      assert path == repo
    end

    test "fails once the repository is gone", %{repo: repo} do
      project = project(repo)
      File.rm_rf!(repo)

      assert {:error, message} = Local.checkout(project)
      assert message =~ "no longer a git repository"
    end
  end

  test "branches/1 lists the local branches", %{repo: repo} do
    assert {:ok, branches} = Local.branches(project(repo))

    assert %{name: "main", current?: true} = Enum.find(branches, &(&1.name == "main"))
  end

  test "list_reviews/1 offers nothing: a local review is chosen by the reviewer", %{repo: repo} do
    assert Local.list_reviews(project(repo)) == {:ok, []}
  end

  describe "load_review/2" do
    test "loads any diff the repository can describe", %{repo: repo} do
      review_id = Project.ref_review_id("HEAD~1", "HEAD")

      assert {:ok, review} = Local.load_review(project(repo), review_id)

      assert review.review_id == review_id
      assert review.title == "HEAD~1..HEAD"
      assert review.base_ref == "HEAD~1"
      assert review.head_ref == "HEAD"
      # The checkout is the repository itself; a local review never moves it.
      assert review.cwd == repo
      assert review.project.kind == :local
      assert Enum.any?(review.diff.files, &(&1.path == "lib/added.ex"))
    end

    test "loads a review between two branches", %{repo: repo} do
      {_output, 0} = System.cmd("git", ["branch", "feature"], cd: repo)
      review_id = Project.ref_review_id("main", "feature")

      assert {:ok, review} = Local.load_review(project(repo), review_id)
      assert review.diff.files == []
    end

    test "refuses a review id that is not a pair of refs", %{repo: repo} do
      assert {:error, message} = Local.load_review(project(repo), "pr-7")
      assert message =~ "not a diff"
    end

    test "reports an unknown ref", %{repo: repo} do
      assert {:error, message} = Local.load_review(project(repo), "nope..HEAD")
      assert message =~ "unknown revision"
    end
  end

  defp project(path) do
    %Project{slug: "local-#{Path.basename(path)}", kind: :local, locator: path}
  end
end
