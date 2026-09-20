defmodule Tackle.Web.PullLiveTest do
  # Clones land under a configured repos root and review state under a configured
  # reviews root; both are global configuration.
  use Tackle.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tackle.Web.GitFixture
  alias Tackle.Web.GitHubStub
  alias Tackle.Web.ReviewStore

  @name "widgets"
  @number 7
  @changed_file "lib/from_the_pull_request.ex"
  # The only line of the added file, as the diff anchors it.
  @added_line "line-lib-from_the_pull_request-ex-L1-new"

  @async_timeout 10_000

  setup do
    # Review state is keyed per pull request and the store outlives each test, so
    # every test reviews its own repository rather than sharing one identity.
    owner = "acme#{System.unique_integer([:positive])}"

    root = GitFixture.scratch_dir("pull")
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

    GitHubStub.start(GitHubStub.pull_payload())

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore(key, value) end)
      File.rm_rf(root)
      File.rm_rf(source)
    end)

    {:ok, owner: owner, path: "/pulls/#{owner}/#{@name}/#{@number}"}
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

  test "explains a pull request it cannot fetch", %{conn: conn, path: path} do
    Application.put_env(:tackle_web, :github_api_url, "http://127.0.0.1:1")

    {:ok, view, _html} = live(conn, path)
    html = render_async(view, @async_timeout)

    assert html =~ "Could not reach GitHub"
  end

  describe "reviewed markers" do
    test "a file can be marked and unmarked as reviewed", %{conn: conn, path: path, owner: owner} do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      assert render(view) =~ "0/1"

      view |> element(viewed_checkbox()) |> render_click()

      assert render(view) =~ "1/1"
      assert ReviewStore.get(owner, @name, @number).viewed == MapSet.new([@changed_file])

      view |> element(viewed_checkbox()) |> render_click()

      assert render(view) =~ "0/1"
      assert ReviewStore.get(owner, @name, @number).viewed == MapSet.new()
    end

    test "the marker is read back on the next visit", %{
      conn: conn,
      path: path,
      owner: owner
    } do
      ReviewStore.set_viewed(owner, @name, @number, @changed_file, true)

      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      assert render(view) =~ "1/1"
    end
  end

  describe "comments" do
    test "a comment can be written on a line and then removed", %{
      conn: conn,
      path: path,
      owner: owner
    } do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(comment_button(1)) |> render_click()

      html =
        view
        |> form("form[phx-submit=add_comment]", comment_form("Spin it faster."))
        |> render_submit()

      assert html =~ "Spin it faster."
      assert html =~ "reviewer"

      assert [comment] = ReviewStore.get(owner, @name, @number).comments
      assert comment.path == @changed_file
      assert comment.side == :new
      assert comment.line == 1

      view
      |> element("button[phx-click=delete_comment][phx-value-id='#{comment.id}']")
      |> render_click()

      refute render(view) =~ "Spin it faster."
      assert ReviewStore.get(owner, @name, @number).comments == []
    end

    test "an empty comment is refused with a message", %{conn: conn, path: path, owner: owner} do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(comment_button(1)) |> render_click()

      html =
        view
        |> form("form[phx-submit=add_comment]", comment_form("   "))
        |> render_submit()

      assert html =~ "Write something"
      assert ReviewStore.get(owner, @name, @number).comments == []
    end

    test "the form can be dismissed without commenting", %{conn: conn, path: path, owner: owner} do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(comment_button(1)) |> render_click()
      assert has_element?(view, "form[phx-submit=add_comment]")

      view |> element("button[phx-click=cancel_comment]") |> render_click()

      refute has_element?(view, "form[phx-submit=add_comment]")
      assert ReviewStore.get(owner, @name, @number).comments == []
    end

    test "a comment on the second line lands on the second line", %{
      conn: conn,
      path: path,
      owner: owner
    } do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(comment_button(2)) |> render_click()

      view
      |> form("form[phx-submit=add_comment]", comment_form("On the end line."))
      |> render_submit()

      assert [comment] = ReviewStore.get(owner, @name, @number).comments
      assert comment.line == 2
    end

    test "an existing comment is rendered on its line", %{
      conn: conn,
      path: path,
      owner: owner
    } do
      {:ok, _comment} =
        ReviewStore.add_comment(owner, @name, @number, %{
          "path" => @changed_file,
          "side" => "new",
          "line" => 1,
          "body" => "Left by someone else.",
          "author" => "teammate"
        })

      {:ok, view, _html} = live(conn, path)
      html = render_async(view, @async_timeout)

      assert html =~ "Left by someone else."
      assert html =~ "teammate"
    end

    test "a comment on a line this pull request does not have is not rendered", %{
      conn: conn,
      path: path,
      owner: owner
    } do
      {:ok, _comment} =
        ReviewStore.add_comment(owner, @name, @number, %{
          "path" => @changed_file,
          "side" => "new",
          "line" => 9999,
          "body" => "Orphaned."
        })

      {:ok, view, _html} = live(conn, path)
      html = render_async(view, @async_timeout)

      refute html =~ "Orphaned."
      assert ReviewStore.get(owner, @name, @number).comments |> length() == 1
    end

    test "a comment on the base side is anchored to the base side", %{
      conn: conn,
      path: path,
      owner: owner
    } do
      {:ok, _comment} =
        ReviewStore.add_comment(owner, @name, @number, %{
          "path" => @changed_file,
          "side" => "old",
          "line" => 1,
          "body" => "This was removed."
        })

      {:ok, view, _html} = live(conn, path)
      html = render_async(view, @async_timeout)

      # The file is added by the pull request, so there is no old side to attach
      # the comment to and it must not be shown against the new one.
      refute html =~ "This was removed."
    end
  end

  describe "the assistant" do
    test "answers a question asked about a line, under that line", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(ask_button(1)) |> render_click()
      view |> form("form.diff-answer-form", question_form("Why is this here?")) |> render_submit()

      eventually(view, "Echo:")

      # The point of the whole feature: the answer is rendered inside the line
      # group of the line that was asked about.
      assert has_element?(
               view,
               "##{@added_line} .diff-answer .diff-reply",
               "Echo: About #{@changed_file} line 1"
             )

      assert has_element?(view, "##{@added_line} .diff-question", "Why is this here?")
    end

    test "reads the pull request's checkout when a question asks it to", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(ask_button(1)) |> render_click()

      view
      |> form("form.diff-answer-form", question_form("Please read #{@changed_file}"))
      |> render_submit()

      eventually(view, "Read:")

      # The tool ran in the clone and the file it read came back through the
      # loop, so the assistant is reading the pull request and not guessing.
      assert has_element?(view, "##{@added_line} .diff-reply", "defmodule FromThePullRequest")
      # The tool call and its result produced no answer of their own, only the
      # read did, so they are counted instead of shown.
      assert has_element?(view, "##{@added_line} .diff-steps", "without an answer")
    end

    test "a question can also be asked about the whole pull request", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> form("#ask-general", question_form("What does this change?")) |> render_submit()

      # The question reaches the model with its scope spelled out, and the answer
      # is rendered in the conversation area rather than against a line.
      eventually(view, "Echo: About this pull request as a whole")
      assert has_element?(view, "main .diff-reply", "What does this change?")

      # No line was picked, so the thread is not attached to any line.
      refute has_element?(view, "##{@added_line} .diff-answer .diff-reply", "Echo:")
    end

    test "an empty question is refused", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      html = view |> form("#ask-general", question_form("   ")) |> render_submit()

      assert html =~ "Write a question first."
      refute html =~ "Echo:"
    end

    test "the conversation survives a reload", %{conn: conn, path: path} do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(ask_button(1)) |> render_click()

      view
      |> form("form.diff-answer-form", question_form("Remembered?"))
      |> render_submit()

      eventually(view, "Echo:")

      {:ok, reloaded, _html} = live(conn, path)
      render_async(reloaded, @async_timeout)

      # Both the question and the answer come back, and the anchor with them, so
      # the answer is still under the line it belongs to.
      assert has_element?(reloaded, "##{@added_line} .diff-question", "Remembered?")
      assert has_element?(reloaded, "##{@added_line} .diff-answer .diff-reply", "Echo:")
    end

    test "a question asked in one viewer appears in another", %{conn: conn, path: path} do
      {:ok, asker, _html} = live(conn, path)
      {:ok, watcher, _html} = live(conn, path)
      render_async(asker, @async_timeout)
      render_async(watcher, @async_timeout)

      asker |> element(ask_button(1)) |> render_click()

      asker
      |> form("form.diff-answer-form", question_form("Seen by both?"))
      |> render_submit()

      eventually(watcher, "Echo:")

      # The watcher never saw the ask form, so it learned the anchor from the
      # conversation rather than from its own request.
      assert has_element?(watcher, "##{@added_line} .diff-question", "Seen by both?")
      assert has_element?(watcher, "##{@added_line} .diff-answer .diff-reply", "Echo:")
    end

    test "the streaming placeholder is cleared once the answer is stored", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, path)
      render_async(view, @async_timeout)

      view |> element(ask_button(1)) |> render_click()
      view |> form("form.diff-answer-form", question_form("Take your time.")) |> render_submit()

      eventually(view, "Take your time.")

      # The answer moved from the in-flight placeholder into the transcript, so
      # it is no longer rendered twice.
      refute render(view) =~ "diff-answer--streaming"
    end
  end

  describe "sharing" do
    test "a comment made in one viewer appears in another", %{
      conn: conn,
      path: path,
      owner: owner
    } do
      {:ok, first, _html} = live(conn, path)
      {:ok, second, _html} = live(conn, path)
      render_async(first, @async_timeout)
      render_async(second, @async_timeout)

      {:ok, _comment} =
        ReviewStore.add_comment(owner, @name, @number, %{
          "path" => @changed_file,
          "side" => "new",
          "line" => 1,
          "body" => "Seen by both."
        })

      assert render(second) =~ "Seen by both."
    end

    test "marking a file reviewed in one viewer shows in another", %{conn: conn, path: path} do
      {:ok, first, _html} = live(conn, path)
      {:ok, second, _html} = live(conn, path)
      render_async(first, @async_timeout)
      render_async(second, @async_timeout)

      first |> element(viewed_checkbox()) |> render_click()

      assert render(second) =~ "1/1"
    end
  end

  defp viewed_checkbox do
    "aside input[phx-click=toggle_viewed][phx-value-path='#{@changed_file}']"
  end

  defp ask_button(line) do
    "button[phx-click=ask_at][phx-value-line='#{line}'][phx-value-side=new]"
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

  defp restore(key, nil), do: Application.delete_env(:tackle_web, key)
  defp restore(key, value), do: Application.put_env(:tackle_web, key, value)
end
