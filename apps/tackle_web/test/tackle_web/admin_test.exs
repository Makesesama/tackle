defmodule Tackle.Web.AdminTest do
  use Tackle.Web.ConnCase, async: false

  import Tackle.Web.AccountsFixtures

  alias Phoenix.LiveView.Socket
  alias Tackle.Web.Accounts.User
  alias Tackle.Web.Auth
  alias Tackle.Web.Models.Provider

  describe "/admin" do
    test "sends anonymous visitors to the start page and refuses non-admins", %{conn: conn} do
      assert redirected_to(get(conn, "/admin"), 302) == "/"

      user = user!()
      assert response(conn |> sign_in(user) |> get("/admin"), 403) =~ "Only admins"
    end

    test "runs AshAdmin behind the actor-pinning hook, whatever the browser's cookies say", %{
      conn: conn
    } do
      admin = admin!()
      other = admin!()

      info = Phoenix.Router.route_info(Tackle.Web.Router, "GET", "/admin/x", "localhost")
      assert info.pipe_through == [:browser, :admin]
      {AshAdmin.PageLive, _action, _opts, %{extra: %{on_mount: hooks}}} = info.phoenix_live_view
      assert Enum.map(hooks, & &1.id) == [{Auth, :admin_ui}]

      # AshAdmin's own actor cookies, as its actor picker would set them. The
      # hook (tested below) replaces what AshAdmin derives from them.
      html =
        conn
        |> sign_in(admin)
        |> put_req_cookie("actor_resource", "User")
        |> put_req_cookie("actor_domain", "Accounts")
        |> put_req_cookie("actor_primary_key", other.id)
        |> put_req_cookie("actor_action", "read")
        |> put_req_cookie("actor_authorizing", "false")
        |> get("/admin")
        |> html_response(200)

      assert html =~ "Ash Admin"
      # No resource is an AshAdmin actor, so there is no actor picker.
      refute html =~ ~s(phx-click="toggle_authorizing")
    end

    test "an expired sign-in no longer opens it", %{conn: conn} do
      admin = admin!()

      assert redirected_to(conn |> sign_in(admin, Auth.max_age() + 1) |> get("/admin"), 302) ==
               "/"
    end
  end

  describe "/codex-login" do
    test "is for admins only and lists the Codex providers", %{conn: conn} do
      Provider.register!("openai-codex", :codex)
      Provider.register!("openrouter", :openrouter)

      assert redirected_to(get(conn, "/codex-login"), 302) == "/"
      assert response(conn |> sign_in(user!()) |> get("/codex-login"), 403)

      html = conn |> sign_in(admin!()) |> get("/codex-login") |> html_response(200)
      assert html =~ ~s(<option value="openai-codex">)
      refute html =~ ~s(<option value="openrouter">)
    end
  end

  describe "on_mount hooks" do
    test ":require_admin checks the session's user on every mount" do
      admin = admin!()
      user = user!()
      now = System.os_time(:second)

      assert {:cont, socket} =
               Auth.on_mount(:require_admin, %{}, session(admin, now), %Socket{})

      assert socket.assigns.current_user.id == admin.id
      assert socket.assigns.signed_in_at == now

      for session <- [
            %{},
            session(user, now),
            session(admin, now - Auth.max_age() - 1),
            %{"user_id" => admin.id}
          ] do
        assert {:halt, %Socket{redirected: {:redirect, %{to: "/"}}}} =
                 Auth.on_mount(:require_admin, %{}, session, %Socket{})
      end
    end

    test "the AshAdmin hook ignores actor and authorisation events" do
      admin = admin!()
      socket = admin_socket(admin)

      for event <- ~w(toggle_authorizing clear_actor set_actor toggle_actor_paused set_tenant) do
        assert {:halt, ^socket} = Auth.pin_admin_actor({:event, event}, socket)
      end
    end

    test "the AshAdmin hook pins the actor and authorisation before anything else runs" do
      admin = admin!()

      tampered =
        admin
        |> admin_socket()
        |> Phoenix.Component.assign(actor: nil, authorizing: false, actor_paused: true)

      for trigger <- [:params, {:event, "save"}] do
        assert {:cont, socket} = Auth.pin_admin_actor(trigger, tampered)
        assert socket.assigns.actor.id == admin.id
        assert socket.assigns.authorizing == true
        assert socket.assigns.actor_paused == false
        assert socket.assigns.actor_resources == []
      end
    end

    test "the AshAdmin hook stops a revoked admin or an expired sign-in at the next step" do
      admin = admin!()
      expired = admin_socket(admin, Auth.max_age() + 1)

      assert {:halt, %Socket{redirected: {:redirect, %{to: "/"}}}} =
               Auth.pin_admin_actor(:params, expired)

      socket = admin_socket(admin)
      admin!()
      User.set_admin!(admin, false)

      assert {:halt, %Socket{redirected: {:redirect, %{to: "/"}}}} =
               Auth.pin_admin_actor({:event, "save"}, socket)
    end
  end

  describe "force_ssl" do
    setup do
      on_exit(fn -> Application.delete_env(:tackle_web, :force_ssl) end)

      Application.put_env(:tackle_web, :force_ssl,
        rewrite_on: [:x_forwarded_proto],
        hsts: true,
        host: "review.example.test",
        exclude: [hosts: ["localhost", "127.0.0.1"], paths: ["/health"]]
      )
    end

    test "redirects plain HTTP and sends HSTS over HTTPS, except for health checks" do
      plain = %{build_conn() | host: "review.example.test"} |> get("/")
      assert redirected_to(plain, 301) == "https://review.example.test/"

      proxied =
        %{build_conn() | host: "review.example.test"}
        |> put_req_header("x-forwarded-proto", "https")
        |> get("/")

      assert html_response(proxied, 200)
      assert get_resp_header(proxied, "strict-transport-security") != []

      health = %{build_conn() | host: "review.example.test"} |> get("/health")
      assert json_response(health, 200)
    end
  end

  test "session cookies are secure when configured" do
    on_exit(fn -> Application.delete_env(:tackle_web, :secure_cookies) end)
    Application.put_env(:tackle_web, :secure_cookies, true)

    conn = get(build_conn(), "/auth/github")
    assert conn.resp_cookies["_tackle_web"].secure
  end

  defp session(user, signed_in_at), do: %{"user_id" => user.id, "signed_in_at" => signed_in_at}

  defp admin_socket(admin, age \\ 0) do
    Phoenix.Component.assign(%Socket{},
      current_user: admin,
      signed_in_at: System.os_time(:second) - age
    )
  end
end
