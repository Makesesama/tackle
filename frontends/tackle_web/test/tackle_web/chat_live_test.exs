defmodule Tackle.Web.ChatLiveTest do
  # The conversation store is global, and every test installs the same global
  # configuration.
  use Tackle.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tackle.Web.ChatFixture
  alias Tackle.Web.ChatStore

  setup do
    ChatFixture.setup()
  end

  test "lists the conversations that are in memory", %{conn: conn, cwd: cwd} do
    {:ok, conversation} = ChatStore.create(cwd: cwd, model: "fake/echo")

    {:ok, _view, html} = live(conn, ~p"/chat")

    assert html =~ "Start a chat"
    assert html =~ conversation.id
    assert html =~ "New chat"
  end

  test "starts a conversation in the directory and with the model the form names", %{
    conn: conn,
    cwd: cwd
  } do
    {:ok, view, _html} = live(conn, ~p"/chat")

    view
    |> form("form[phx-submit=create]", chat_form(cwd, ChatFixture.other_model()))
    |> render_submit()

    conversation = conversation_in(cwd)
    assert conversation.cwd == cwd
    assert conversation.model == ChatFixture.other_model()
    assert_redirect(view, ~p"/chat/#{conversation.id}")
  end

  test "explains a directory that is not there", %{conn: conn, root: root} do
    missing = Path.join(root, "not-created")

    {:ok, view, _html} = live(conn, ~p"/chat")

    html =
      view
      |> form("form[phx-submit=create]", chat_form(missing, "fake/echo"))
      |> render_submit()

    assert html =~ "is not a directory that exists"
    assert conversation_in(root) == nil
  end

  test "refuses a model no adapter offers", %{conn: conn, cwd: cwd} do
    {:ok, view, _html} = live(conn, ~p"/chat")

    # The select only offers models the adapter list exposes, so a value from
    # outside it has to be posted directly, as a page built against another
    # configuration would.
    html =
      render_submit(view, "create", chat_form(cwd, "fake/nope"))

    assert html =~ "is not offered by the configured providers"
    assert conversation_in(cwd) == nil
  end

  test "a conversation can be deleted from the list", %{conn: conn, cwd: cwd} do
    {:ok, conversation} = ChatStore.create(cwd: cwd, model: "fake/echo")

    {:ok, view, _html} = live(conn, ~p"/chat")
    assert has_element?(view, "button[phx-click=delete][phx-value-id='#{conversation.id}']")

    view
    |> element("button[phx-click=delete][phx-value-id='#{conversation.id}']")
    |> render_click()

    refute render(view) =~ conversation.id
    assert ChatStore.get(conversation.id) == nil
  end

  defp conversation_in(cwd) do
    Enum.find(ChatStore.list(), &(&1.cwd == cwd))
  end

  defp chat_form(workspace, model) do
    %{"chat" => %{"workspace" => workspace, "model" => model}}
  end
end
