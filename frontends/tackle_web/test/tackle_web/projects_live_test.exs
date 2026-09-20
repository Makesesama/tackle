defmodule Tackle.Web.ProjectsLiveTest do
  # The project list is a global store and the repositories root is global
  # configuration: sequential.
  use Tackle.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tackle.Web.GitFixture
  alias Tackle.Web.Project
  alias Tackle.Web.ProjectStore

  setup do
    repo = GitFixture.build()
    before = MapSet.new(ProjectStore.list(), & &1.slug)

    on_exit(fn ->
      File.rm_rf(repo)
      forget_projects_added_since(before)
    end)

    {:ok, repo: repo, slug: Project.slug(:local, repo)}
  end

  # The store outlives each test, so a project a test added is removed again
  # rather than showing up in the next test's list.
  defp forget_projects_added_since(before) do
    for project <- ProjectStore.list(), not MapSet.member?(before, project.slug) do
      ProjectStore.remove(project.slug)
    end
  end

  test "starts with the form and an empty list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects")

    assert has_element?(view, "#add-project")
    assert has_element?(view, "select[name='project[kind]']")
    assert has_element?(view, "input[name='project[locator]']")
    assert render(view) =~ "No projects yet"
  end

  test "the root path is the project list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#add-project")
  end

  test "adding a local repository opens it", %{conn: conn, repo: repo, slug: slug} do
    {:ok, view, _html} = live(conn, ~p"/projects")

    view
    |> form("#add-project", project_form("local", repo))
    |> render_submit()

    assert_redirect(view, ~p"/projects/#{slug}")
    assert ProjectStore.get(slug).locator == repo
  end

  test "a path that is not a repository is reported on the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects")

    html =
      view
      |> form("#add-project", project_form("local", "/nope/not/here"))
      |> render_submit()

    assert html =~ "not a directory"
    assert ProjectStore.list() == []
  end

  test "adding the same repository twice is refused", %{conn: conn, repo: repo, slug: slug} do
    on_exit(fn -> ProjectStore.remove(slug) end)
    _project = project(repo)

    {:ok, view, _html} = live(conn, ~p"/projects")

    html =
      view
      |> form("#add-project", project_form("local", repo))
      |> render_submit()

    assert html =~ "already added"
  end

  test "a project can be removed", %{conn: conn, repo: repo, slug: slug} do
    on_exit(fn -> ProjectStore.remove(slug) end)
    project(repo)

    {:ok, view, _html} = live(conn, ~p"/projects")

    assert has_element?(view, "#project-#{slug}")

    view
    |> element("button[phx-click=remove][phx-value-slug='#{slug}']")
    |> render_click()

    refute has_element?(view, "#project-#{slug}")
    assert ProjectStore.get(slug) == nil
  end

  test "a project added in another viewer appears", %{conn: conn, repo: repo, slug: slug} do
    on_exit(fn -> ProjectStore.remove(slug) end)

    {:ok, view, _html} = live(conn, ~p"/projects")
    project(repo)

    assert render(view) =~ repo
  end

  defp project(repo) do
    {:ok, project} =
      ProjectStore.put(%Project{
        slug: Project.slug(:local, repo),
        kind: :local,
        locator: repo,
        name: Path.basename(repo),
        default_branch: "main"
      })

    project
  end

  defp project_form(kind, locator), do: %{"project" => %{"kind" => kind, "locator" => locator}}
end
