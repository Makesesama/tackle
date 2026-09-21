defmodule Tackle.Web.ConversationLiveTest do
  # Conversations live in a global store and the harness configuration is
  # global too.
  use Tackle.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tackle.Web.ChatFixture
  alias Tackle.Web.ChatStore
  alias Tackle.Web.Project
  alias Tackle.Web.ProjectStore

  # The conversation routes are project-scoped. A chat only needs its project's
  # slug to be addressed; the project itself decides the checkout it runs in,
  # and these tests create the conversation directly with one.
  @slug "local-widgets-1a2b3c"

  setup do
    context = ChatFixture.setup()

    # The route names a project, so one has to exist for the page to mount.
    {:ok, _project} =
      ProjectStore.put(%Project{
        slug: @slug,
        kind: :local,
        locator: context.cwd,
        name: "widgets",
        default_branch: "main"
      })

    on_exit(fn -> ProjectStore.remove(@slug) end)

    context
  end

  test "answers a message and keeps the transcript", %{conn: conn, cwd: cwd} do
    {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")

    {:ok, view, _html} = live(conn, ~p"/projects/#{@slug}/chats/#{conversation.id}")
    assert has_element?(view, "form[phx-submit=send]")

    view |> form("form[phx-submit=send]", message("Hello")) |> render_submit()
    eventually(view, "Echo: Hello")

    assert has_element?(view, ".chat-message--user .chat-text", "Hello")
    assert has_element?(view, ".chat-message--assistant .chat-text", "Echo: Hello")
    assert Enum.map(ChatStore.get(conversation.id).messages, & &1.role) == [:user, :assistant]
  end

  test "the composer is cleared once the message is sent", %{conn: conn, cwd: cwd} do
    {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")

    {:ok, view, _html} = live(conn, ~p"/projects/#{@slug}/chats/#{conversation.id}")

    # The composer is a controlled input, so what the reader types is what the
    # server renders, and sending it is what empties it again.
    view |> form("form[phx-submit=send]", message("Half typed")) |> render_change()
    assert has_element?(view, "input[name='message[body]'][value='Half typed']")

    view |> form("form[phx-submit=send]", message("Hello")) |> render_submit()
    eventually(view, "Echo: Hello")

    assert has_element?(view, "input[name='message[body]'][value='']")
  end

  test "the conversation is read back on the next visit", %{conn: conn, cwd: cwd} do
    {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")

    {:ok, view, _html} = live(conn, ~p"/projects/#{@slug}/chats/#{conversation.id}")
    view |> form("form[phx-submit=send]", message("Remembered?")) |> render_submit()
    eventually(view, "Echo: Remembered?")

    {:ok, reloaded, _html} = live(conn, ~p"/projects/#{@slug}/chats/#{conversation.id}")

    assert has_element?(reloaded, ".chat-message--user .chat-text", "Remembered?")
    assert has_element?(reloaded, ".chat-message--assistant .chat-text", "Echo: Remembered?")
  end

  test "the tools of the harness run in the conversation's directory", %{
    conn: conn,
    cwd: cwd
  } do
    File.write!(Path.join(cwd, "notes.txt"), "hello from the file\n")
    {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")

    {:ok, view, _html} = live(conn, ~p"/projects/#{@slug}/chats/#{conversation.id}")
    view |> form("form[phx-submit=send]", message("Please read notes.txt")) |> render_submit()

    eventually(view, "hello from the file")

    # The call and its result are one collapsed block, not two answers.
    assert has_element?(view, "details.chat-work")
    assert has_element?(view, "details.chat-work summary", "steps")
    assert has_element?(view, "details.chat-work .chat-work-call", "read notes.txt")
  end

  test "a second viewer sees the answer it did not ask for", %{conn: conn, cwd: cwd} do
    {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")
    path = ~p"/projects/#{@slug}/chats/#{conversation.id}"

    {:ok, asker, _html} = live(conn, path)
    {:ok, watcher, _html} = live(conn, path)

    asker |> form("form[phx-submit=send]", message("Seen by both?")) |> render_submit()

    eventually(watcher, "Echo: Seen by both?")
    assert has_element?(watcher, ".chat-message--user .chat-text", "Seen by both?")
  end

  test "switching the model keeps the conversation", %{conn: conn, cwd: cwd} do
    {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")

    {:ok, view, _html} = live(conn, ~p"/projects/#{@slug}/chats/#{conversation.id}")
    view |> form("form[phx-submit=send]", message("Hello")) |> render_submit()
    eventually(view, "Echo: Hello")

    other = ChatFixture.other_model()
    view |> element("select[name=model]") |> render_change(%{"model" => other})

    assert ChatStore.get(conversation.id).model == other
    assert has_element?(view, "select[name=model] option[value='#{other}'][selected]")
    # The transcript is part of the conversation, not of the model.
    assert has_element?(view, ".chat-message--user .chat-text", "Hello")
  end

  test "a model that cannot run is reported instead of answering", %{conn: conn, cwd: cwd} do
    # A conversation stored without a model falls back to the configured one, so
    # a misconfigured default is the way a page meets an agent that cannot
    # start.
    Application.put_env(:tackle_web, :agent_model, "fake/nope")
    {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: nil)

    {:ok, _view, html} = live(conn, ~p"/projects/#{@slug}/chats/#{conversation.id}")

    assert html =~ "is not offered by the configured providers"
  end

  test "a conversation that is gone returns to the list", %{conn: conn} do
    # The LiveView is not mounted at all: mount finds no conversation to attach
    # to and redirects before rendering the chat.
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/projects/#{@slug}/chats/no-such-conversation")

    assert to == "/projects/#{@slug}"
  end

  test "deleting the conversation returns to the list", %{conn: conn, cwd: cwd} do
    {:ok, conversation} = ChatStore.create(project_slug: @slug, cwd: cwd, model: "fake/echo")

    {:ok, view, _html} = live(conn, ~p"/projects/#{@slug}/chats/#{conversation.id}")

    view
    |> element("header button[phx-click=delete][phx-value-id='#{conversation.id}']")
    |> render_click()

    assert_redirect(view, ~p"/projects/#{@slug}")
    assert ChatStore.get(conversation.id) == nil
  end

  defp message(body) do
    %{"message" => %{"body" => body}}
  end
end
