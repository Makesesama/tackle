defmodule Tackle.Web.ProjectLiveTest do
  # The project store, the repositories root and the harness configuration are
  # all global: sequential.
  use Tackle.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tackle.Web.ChatFixture
  alias Tackle.Web.ChatStore
  alias Tackle.Web.GitFixture
  alias Tackle.Web.GitHubStub
  alias Tackle.Web.Project
  alias Tackle.Web.ProjectStore

  @name "widgets"
  @number 7
  @async_timeout 10_000

  setup do
    ChatFixture.setup()
  end

  describe "a local project" do
    setup do
      repo = GitFixture.build()

      project =
        put(%Project{
          slug: "local-#{Path.basename(repo)}-#{System.unique_integer([:positive])}",
          kind: :local,
          locator: repo,
          name: Path.basename(repo),
          default_branch: "main"
        })

      on_exit(fn -> File.rm_rf(repo) end)

      {:ok, project: project, repo: repo}
    end

    test "offers a branch picker and no ready-made reviews", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
      html = render_async(view, @async_timeout)

      assert html =~ "main"
      assert has_element?(view, "#open-review")
      assert has_element?(view, "select[name='review[base]']")
      assert has_element?(view, "select[name='review[head]']")
    end

    test "opening a review addresses it by its refs", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
      render_async(view, @async_timeout)

      view
      |> form("#open-review", review_form("main", "main"))
      |> render_submit()

      review_id = Project.ref_review_id("main", "main")

      assert_redirect(view, ~p"/projects/#{project.slug}/reviews/#{review_id}")
    end

    test "a review needs both ends", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
      render_async(view, @async_timeout)

      # Sent as the event rather than through the form: the picker only ever
      # offers branches, so an empty end can only arrive from a stale page.
      html = render_submit(view, "review", review_form("", "main"))

      assert html =~ "Pick both ends"
    end
  end

  describe "a GitHub project" do
    setup do
      owner = "acme#{System.unique_integer([:positive])}"
      GitHubStub.start(JSON.encode!([pull_map()]))

      project =
        put(%Project{
          slug: Project.slug(:github, "#{owner}/#{@name}"),
          kind: :github,
          locator: "#{owner}/#{@name}",
          name: @name,
          default_branch: "main"
        })

      {:ok, project: project}
    end

    test "lists the open pull requests", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
      render_async(view, @async_timeout)

      assert has_element?(view, "a[href='/projects/#{project.slug}/reviews/pr-#{@number}']")
      assert render(view) =~ "Teach the widget to spin"
      # The source offers no branches, so the picker is not rendered.
      refute has_element?(view, "#open-review")
    end

    test "opening a pull request addresses it by its review id", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
      render_async(view, @async_timeout)

      view
      |> element("a[href='/projects/#{project.slug}/reviews/pr-#{@number}']")
      |> render_click()

      assert_redirect(view, ~p"/projects/#{project.slug}/reviews/pr-#{@number}")
    end

    test "an unreachable API is reported instead of crashing", %{conn: conn, project: project} do
      Application.put_env(:tackle_web, :github_api_url, "http://127.0.0.1:1")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
      html = render_async(view, @async_timeout)

      assert html =~ "Could not list reviews"
    end
  end

  describe "chats" do
    setup do
      repo = GitFixture.build()

      project =
        put(%Project{
          slug: "local-chats-#{System.unique_integer([:positive])}",
          kind: :local,
          locator: repo,
          name: Path.basename(repo),
          default_branch: "main"
        })

      on_exit(fn -> File.rm_rf(repo) end)

      {:ok, project: project, repo: repo}
    end

    test "a new chat is scoped to the project and opens", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
      render_async(view, @async_timeout)

      view
      |> form("#new-chat", chat_form("fake/echo"))
      |> render_submit()

      # Cloning for a first chat is asynchronous, so the conversation lands in
      # the store a moment after the submit.
      conversation = await_conversation(project.slug)

      assert_redirect(view, ~p"/projects/#{project.slug}/chats/#{conversation.id}")
    end

    test "the project's conversations are listed", %{conn: conn, project: project, repo: repo} do
      {:ok, _conversation} =
        ChatStore.create(project_slug: project.slug, cwd: repo, model: "fake/echo")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
      render_async(view, @async_timeout)

      assert has_element?(view, "#new-chat")
      assert render(view) =~ "New chat"
    end

    test "another project's conversations are not listed", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      {:ok, _conversation} =
        ChatStore.create(project_slug: "someone-else", cwd: repo, model: "fake/echo")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")
      render_async(view, @async_timeout)

      assert render(view) =~ "No conversations yet."
    end
  end

  test "an unknown project returns to the list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(conn, "/projects/no-such-project")
  end

  defp put(%Project{} = project) do
    {:ok, stored} = ProjectStore.put(project)
    on_exit(fn -> ProjectStore.remove(stored.slug) end)
    stored
  end

  defp await_conversation(slug, attempts \\ 200) do
    Enum.reduce_while(1..attempts, nil, fn _attempt, _acc ->
      case ChatStore.list(slug) do
        [conversation] ->
          {:halt, conversation}

        _none ->
          Process.sleep(20)
          {:cont, nil}
      end
    end) || raise "The project never got a conversation."
  end

  defp review_form(base, head), do: %{"review" => %{"base" => base, "head" => head}}
  defp chat_form(model), do: %{"chat" => %{"model" => model}}

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
end
