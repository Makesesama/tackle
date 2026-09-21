defmodule Tackle.Web.ReviewLiveTest do
  # Clones land under a configured repos root, review state under a configured
  # reviews root and the harness configuration is global: sequential.
  use Tackle.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tackle.Web.GitFixture
  alias Tackle.Web.GitHubStub
  alias Tackle.Web.Project
  alias Tackle.Web.ProjectStore
  alias Tackle.Web.ReviewStore

  @name "widgets"
  @number 7
  @changed_file "lib/from_the_pull_request.ex"
  # The two lines of the added file, as the diff anchors them.
  @added_line "line-lib-from_the_pull_request-ex-L1-new"
  @added_line_2 "line-lib-from_the_pull_request-ex-L2-new"

  @async_timeout 10_000

  setup do
    # Review state is keyed per project and review, and the store outlives each
    # test, so every test reviews its own repository rather than sharing one.
    owner = "acme#{System.unique_integer([:positive])}"
    root = GitFixture.scratch_dir("review")
    host = Path.join(root, "host")
    {_host, source} = GitFixture.hosted(host, owner, @name, @number)

    previous = %{
      github_host: Application.get_env(:tackle_web, :github_host),
      repos_root: Application.get_env(:tackle_web, :repos_root),
      reviews_root: Application.get_env(:tackle_web, :reviews_root),
      conversations_root: Application.get_env(:tackle_web, :conversations_root),
      agent_adapters: Application.get_env(:tackle_web, :agent_adapters),
      agent_model: Application.get_env(:tackle_web, :agent_model)
    }

    Application.put_env(:tackle_web, :github_host, host)
    Application.put_env(:tackle_web, :repos_root, Path.join(root, "repos"))
    Application.put_env(:tackle_web, :reviews_root, Path.join(root, "reviews"))
    Application.put_env(:tackle_web, :conversations_root, Path.join(root, "conversations"))
    # The assistant answers deterministically: tests need no provider credentials
    # and no live model.
    Application.put_env(:tackle_web, :agent_adapters, [Tackle.Web.FakeAdapter])
    Application.put_env(:tackle_web, :agent_model, "fake/echo")

    project = github_project(owner)

    on_exit(fn ->
      ProjectStore.remove(project.slug)
      Enum.each(previous, fn {key, value} -> restore(key, value) end)
      File.rm_rf(root)
      File.rm_rf(source)
    end)

    {:ok,
     project: project,
     review_id: "pr-#{@number}",
     path: "/projects/#{project.slug}/reviews/pr-#{@number}"}
  end

  describe "a GitHub review" do
    setup do
      GitHubStub.start(GitHubStub.pull_payload())
      :ok
    end

    test "renders the diff of the pull request", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      html = render_async(view, @async_timeout)

      assert html =~ "Teach the widget to spin"
      assert html =~ @changed_file
      assert html =~ "diff-line--add"
    end

    test "shows the pull request's own change, not the base branch's", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      html = render_async(view, @async_timeout)

      # lib/added.ex only exists on the base branch, so it is not part of this
      # pull request.
      refute html =~ "lib/added.ex"
    end

    test "explains a review it cannot load", %{conn: conn, path: path} do
      Application.put_env(:tackle_web, :github_api_url, "http://127.0.0.1:1")

      {:ok, view, _html} = live(conn, path)
      html = render_async(view, @async_timeout)

      assert html =~ "Could not reach GitHub"
    end

    test "a file can be marked and unmarked as reviewed", %{conn: conn, path: path} do
      %{slug: slug, review_id: review_id} = identity(path)

      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      assert render(view) =~ "0/1"

      view |> element(viewed_checkbox()) |> render_click()

      assert render(view) =~ "1/1"
      assert ReviewStore.get(slug, review_id).viewed == MapSet.new([@changed_file])

      view |> element(viewed_checkbox()) |> render_click()

      assert render(view) =~ "0/1"
      assert ReviewStore.get(slug, review_id).viewed == MapSet.new()
    end

    test "a comment can be written on a line and then removed", %{conn: conn, path: path} do
      %{slug: slug, review_id: review_id} = identity(path)

      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(comment_button(1)) |> render_click()

      html =
        view
        |> form("form[phx-submit=add_comment]", comment_form("Spin it faster."))
        |> render_submit()

      assert html =~ "Spin it faster."
      assert html =~ "reviewer"

      assert [comment] = ReviewStore.get(slug, review_id).comments
      assert comment.path == @changed_file
      assert comment.side == :new
      assert comment.line == 1

      view
      |> element("button[phx-click=delete_comment][phx-value-id='#{comment.id}']")
      |> render_click()

      refute render(view) =~ "Spin it faster."
      assert ReviewStore.get(slug, review_id).comments == []
    end

    test "an empty comment is refused with a message", %{conn: conn, path: path} do
      %{slug: slug, review_id: review_id} = identity(path)

      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(comment_button(1)) |> render_click()

      html =
        view
        |> form("form[phx-submit=add_comment]", comment_form("   "))
        |> render_submit()

      assert html =~ "Write something"
      assert ReviewStore.get(slug, review_id).comments == []
    end

    test "answers a question asked about a line in the assistant panel", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(ask_button(1)) |> render_click()
      view |> form("#ask", question_form("Why is this here?")) |> render_submit()

      eventually(view, "Echo:")

      # The answer is beside the diff, not inside it, and the thread still says
      # which line it is about. Only the wording the reader typed is shown: the
      # location the prompt carried is already named by the anchor above it.
      assert has_element?(
               view,
               "#assistant .assistant-thread .assistant-reply",
               "Echo: About #{@changed_file} line 1"
             )

      assert view |> element("#assistant .assistant-question") |> render() ==
               ~s(<p class="assistant-question">Why is this here?</p>)

      assert has_element?(view, "#assistant .assistant-anchor", "line 1")

      # The line in the diff only carries a marker back to the thread.
      assert has_element?(view, "##{@added_line} .diff-thread-marker")
      refute has_element?(view, "##{@added_line} .assistant-reply")
    end

    test "shift-clicking a second line asks about the range under its last line", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(ask_button(1)) |> render_click()
      view |> render_click("select_lines", shift_click(2))

      # The composer names the selection, so a range is never asked about unnamed.
      assert has_element?(view, "#ask .assistant-scope", "lines 1-2")

      view
      |> form("#ask", question_form("What about both lines?"))
      |> render_submit()

      eventually(view, "Echo: About #{@changed_file} lines 1-2")

      # One thread, named as the range, not one thread per line.
      assert has_element?(view, "#assistant .assistant-anchor", "lines 1-2")
    end

    test "the lines of a range selection are marked while it is written", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(ask_button(1)) |> render_click()
      view |> render_click("select_lines", plain_click(2))

      # A plain click starts a fresh single-line selection.
      assert has_element?(view, "#ask .assistant-scope", "line 2")
      refute has_element?(view, "#ask .assistant-scope", "lines 1-2")

      view |> render_click("select_lines", shift_click(1))

      assert has_element?(view, "#ask .assistant-scope", "lines 1-2")
      assert has_element?(view, "##{@added_line} .diff-line--selected")
      assert has_element?(view, "##{@added_line_2} .diff-line--selected")
    end

    test "a selection can be cleared without asking anything", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(ask_button(1)) |> render_click()
      assert has_element?(view, "#ask .assistant-scope", "line 1")

      view |> element("#ask button[phx-click=clear_selection]") |> render_click()

      refute has_element?(view, "#ask .assistant-scope")
      refute has_element?(view, "##{@added_line} .diff-line--selected")
    end

    test "reads the review's checkout when a question asks it to", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(ask_button(1)) |> render_click()

      view
      |> form("#ask", question_form("Please read #{@changed_file}"))
      |> render_submit()

      eventually(view, "Read:")

      # The tool ran in the clone and the file it read came back through the
      # loop, so the assistant is reading the review and not guessing.
      assert has_element?(view, "#assistant .assistant-reply", "defmodule FromThePullRequest")
      # The tool call and its result produced no answer of their own, only the
      # read did, so they are counted instead of shown.
      assert has_element?(view, "#assistant .assistant-steps", "without an answer")
    end

    test "a question can also be asked about the whole review", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> form("#ask", question_form("What does this change?")) |> render_submit()

      eventually(view, "Echo: About this review as a whole")
      assert has_element?(view, "#assistant .assistant-reply", "What does this change?")
      assert has_element?(view, "#assistant .assistant-anchor", "this review")

      # Nothing was asked about a line, so no line carries a marker.
      refute has_element?(view, "##{@added_line} .diff-thread-marker")
    end

    test "an empty question is refused", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      html = view |> form("#ask", question_form("   ")) |> render_submit()

      assert html =~ "Write a question first."
      refute html =~ "Echo:"
    end

    test "the conversation survives a reload", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(ask_button(1)) |> render_click()
      view |> form("#ask", question_form("Remembered?")) |> render_submit()
      eventually(view, "Echo:")

      {:ok, reloaded, _html} = live(conn, path)
      render_async(reloaded, @async_timeout)

      # Both the question and the answer come back, and the anchor with them, so
      # the panel still says which line the thread is about.
      assert reloaded |> element("#assistant .assistant-question") |> render() ==
               ~s(<p class="assistant-question">Remembered?</p>)

      assert has_element?(reloaded, "#assistant .assistant-reply", "Echo:")
      assert has_element?(reloaded, "#assistant .assistant-anchor", "line 1")
    end

    test "a question asked in one viewer appears in another", %{conn: conn, path: path} do
      {:ok, asker, _html} = live(conn, path)
      {:ok, watcher, _html} = live(conn, path)
      render_async(asker, @async_timeout)
      render_async(watcher, @async_timeout)

      asker |> element(ask_button(1)) |> render_click()

      asker
      |> form("#ask", question_form("Seen by both?"))
      |> render_submit()

      eventually(watcher, "Echo:")

      # The watcher never saw the selection, so it learned the anchor from the
      # conversation rather than from its own request.
      assert watcher |> element("#assistant .assistant-question") |> render() ==
               ~s(<p class="assistant-question">Seen by both?</p>)

      assert has_element?(watcher, "#assistant .assistant-reply", "Echo:")
      assert has_element?(watcher, "#assistant .assistant-anchor", "line 1")
    end

    test "a comment made in one viewer appears in another", %{conn: conn, path: path} do
      %{slug: slug, review_id: review_id} = identity(path)

      {:ok, first, _html} = live(conn, path)
      {:ok, second, _html} = live(conn, path)
      render_async(first, @async_timeout)
      render_async(second, @async_timeout)

      {:ok, _comment} =
        ReviewStore.add_comment(slug, review_id, %{
          "path" => @changed_file,
          "side" => "new",
          "line" => 1,
          "body" => "Seen by both."
        })

      assert render(second) =~ "Seen by both."
    end
  end

  describe "a local review" do
    setup do
      repo = GitFixture.build()
      review_id = Project.ref_review_id("HEAD~1", "HEAD")

      project = %Project{
        slug: "local-#{Path.basename(repo)}-#{System.unique_integer([:positive])}",
        kind: :local,
        locator: repo,
        name: Path.basename(repo),
        default_branch: "main"
      }

      {:ok, project} = ProjectStore.put(project)

      on_exit(fn ->
        ProjectStore.remove(project.slug)
        File.rm_rf(repo)
      end)

      {:ok,
       project: project,
       review_id: review_id,
       path: "/projects/#{project.slug}/reviews/#{review_id}"}
    end

    test "renders the diff with the assistant attached", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      html = render_async(view, @async_timeout)

      assert html =~ "lib/keep.ex"
      assert html =~ "diff-line--add"
      # The whole point of a local project: the assistant is here too, not only
      # on a GitHub pull request.
      assert has_element?(view, ask_button(1, "lib/added.ex"))
      assert has_element?(view, "#ask")
    end

    test "the assistant reads the repository it was pointed at", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(ask_button(1, "lib/added.ex")) |> render_click()

      view
      |> form("#ask", question_form("Please read lib/added.ex"))
      |> render_submit()

      eventually(view, "Read:")
      assert has_element?(view, "#assistant .assistant-reply", "defmodule Added")
    end

    test "a range can be selected on a local review", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(ask_button(1, "lib/added.ex")) |> render_click()
      view |> render_click("select_lines", shift_click(2, "lib/added.ex"))

      assert has_element?(view, "#ask .assistant-scope", "lines 1-2")
      assert has_element?(view, "#line-lib-added-ex-L1-new .diff-line--selected")
      assert has_element?(view, "#line-lib-added-ex-L2-new .diff-line--selected")
    end

    test "an unknown ref is reported instead of crashing", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, "/projects/#{project.slug}/reviews/nope..HEAD")
      html = render_async(view, @async_timeout)

      assert html =~ "unknown revision"
    end
  end

  test "an unknown project returns to the projects list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             live(conn, "/projects/no-such-project/reviews/pr-1")
  end

  defp github_project(owner) do
    project = %Project{
      slug: Project.slug(:github, "#{owner}/#{@name}"),
      kind: :github,
      locator: "#{owner}/#{@name}",
      name: @name,
      default_branch: "main"
    }

    {:ok, project} = ProjectStore.put(project)
    project
  end

  # The project slug and review id a review path addresses, so a test can read
  # the state the page wrote.
  defp identity(path) do
    [_empty, "projects", slug, "reviews", review_id] = String.split(path, "/")

    %{slug: slug, review_id: review_id}
  end

  defp viewed_checkbox do
    "aside input[phx-click=toggle_viewed][phx-value-path='#{@changed_file}']"
  end

  defp ask_button(line, path \\ @changed_file) do
    "button[phx-click=select_lines][phx-value-from='#{line}'][phx-value-path='#{path}'][phx-value-side=new]"
  end

  defp question_form(body) do
    %{"question" => %{"body" => body}}
  end

  defp comment_button(line) do
    "button[phx-click=comment_at][phx-value-line='#{line}'][phx-value-side=new]"
  end

  defp comment_form(body) do
    %{
      "comment" => %{
        "path" => @changed_file,
        "side" => "new",
        "body" => body
      }
    }
  end

  # The payload the selection hook sends: the two ends of the range it drew. The
  # `?` button sends the same shape, collapsed to the line it sits on, and the
  # modifier as click metadata.
  defp shift_click(line, path \\ @changed_file), do: click(line, path, true)
  defp plain_click(line, path \\ @changed_file), do: click(line, path, false)

  defp click(line, path, shift?) do
    %{
      "path" => path,
      "side" => "new",
      "from" => to_string(line),
      "to" => to_string(line),
      "extend" => shift?
    }
  end

  defp restore(key, nil), do: Application.delete_env(:tackle_web, key)
  defp restore(key, value), do: Application.put_env(:tackle_web, key, value)
end
