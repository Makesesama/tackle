defmodule Tackle.Web.DiffLiveTest do
  use Tackle.Web.ConnCase, async: true

  import Phoenix.LiveViewTest

  # Loading a diff shells out to git and highlights every changed file, so the
  # 100ms default is not enough under a fully parallel test run.
  @async_timeout 5_000

  alias Tackle.Web.GitFixture

  setup_all do
    repo = GitFixture.build()
    on_exit(fn -> File.rm_rf(repo) end)
    {:ok, repo: repo}
  end

  test "asks for a repository before one is named", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ "Enter the path to a local git repository"

    # The form is pre-filled with the defaults the first review should use.
    assert has_element?(view, "input[name=base][value='HEAD~1']")
    assert has_element?(view, "input[name=head][value='HEAD']")
  end

  test "renders the diff of a local repository", %{conn: conn, repo: repo} do
    {:ok, view, _html} = live(conn, "/?repo=#{repo}&base=HEAD~1&head=HEAD")
    html = render_async(view, @async_timeout)

    assert html =~ "lib/added.ex"
    assert html =~ "lib/keep.ex"
    assert html =~ "diff-line--add"
    assert html =~ "diff-line--remove"
    assert html =~ "diff-line--note"
  end

  test "lists files with their change status", %{conn: conn, repo: repo} do
    {:ok, view, _html} = live(conn, "/?repo=#{repo}&base=HEAD~1&head=HEAD")
    html = render_async(view, @async_timeout)

    assert has_element?(view, "#file-lib-added-ex")
    assert html =~ "added"
    assert html =~ "deleted"
    assert html =~ "renamed"
  end

  test "shows why a diff could not be produced", %{conn: conn, repo: repo} do
    {:ok, view, _html} = live(conn, "/?repo=#{repo}&base=HEAD~1&head=no-such-ref")
    html = render_async(view, @async_timeout)

    assert html =~ "unknown revision"
  end

  test "reloads from the form and keeps the range in the URL", %{conn: conn, repo: repo} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#local-diff", %{"repo" => repo, "base" => "HEAD~1", "head" => "HEAD"})
    |> render_submit()

    # The whole review has to travel in the URL so it can be shared and reloaded.
    assert view |> assert_patch() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() ==
             %{"repo" => repo, "base" => "HEAD~1", "head" => "HEAD"}

    assert render_async(view, @async_timeout) =~ "lib/added.ex"
  end

  describe "opening a pull request" do
    test "navigates to the pull request view", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#pull-request", %{"reference" => "acme/widgets#7"})
               |> render_submit()

      assert to == "/pulls/acme/widgets/7"
    end

    test "accepts a full URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#pull-request", %{
                 "reference" => "https://github.com/acme/widgets/pull/7"
               })
               |> render_submit()

      assert to == "/pulls/acme/widgets/7"
    end

    test "explains a reference it cannot read", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> form("#pull-request", %{"reference" => "nonsense"})
        |> render_submit()

      assert html =~ "Expected a pull request"
    end
  end
end
