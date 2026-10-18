defmodule Tackle.HubWeb.Auth do
  @moduledoc """
  Who is signed in, for plugs and LiveViews (docs/TACKLE_HUB_PLAN.md §7.6,
  §7.9).

  The session (a signed and encrypted cookie) holds only the user's id and
  when they signed in; the user is read from the database on every request
  and LiveView mount, so a deleted user or a revoked admin flag applies at
  once. A sign-in lasts at most `max_age/0`.

  Plugs, for the router: `fetch_current_user/2` (assigns `:current_user`,
  or nil), `require_user/2`, and `require_admin/2`. LiveView hooks, through
  `on_mount/4`:

    * `:require_user` - the page needs a signed-in user, checked on both the
      HTTP and the connected mount;
    * `:require_admin` - the page needs a signed-in admin, checked on both
      the HTTP and the connected mount;
    * `:admin_ui` - the same for AshAdmin, which additionally pins the actor
      to that admin and authorisation on (see `pin_admin_actor/2`).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias Phoenix.LiveView
  alias Tackle.Hub.Accounts.User

  @max_age 7 * 24 * 60 * 60

  # AshAdmin events that change who the actor is, whether policies are
  # checked, or the tenant. In AshAdmin these are developer conveniences;
  # here the actor is always the signed-in admin with authorisation on.
  @pinned_events ~w(
    toggle_authorizing toggle_actor_paused clear_actor set_actor
    set_tenant clear_tenant start_editing_tenant stop_editing_tenant search_tenants
  )

  @doc "How long a sign-in lasts, in seconds."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age

  @doc "Stores a freshly signed-in user in a renewed session."
  @spec put_user(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  def put_user(conn, %User{id: id}) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_id, id)
    |> put_session(:signed_in_at, System.os_time(:second))
  end

  @doc "Plug: assigns the signed-in user as `:current_user`, or nil."
  @spec fetch_current_user(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def fetch_current_user(conn, _opts) do
    session = get_session(conn)

    case user_from_session(session) do
      {:ok, user} ->
        assign(conn, :current_user, user)

      # Expired, or the user is gone: forget it, but keep the rest of the
      # session (a sign-in's `state` may be in it).
      :error when is_map_key(session, "user_id") ->
        conn
        |> delete_session(:user_id)
        |> delete_session(:signed_in_at)
        |> assign(:current_user, nil)

      :error ->
        assign(conn, :current_user, nil)
    end
  end

  @doc """
  Plug: sends anonymous visitors to the start page, which offers sign-in.
  Needs `fetch_current_user/2` first.
  """
  @spec require_user(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def require_user(conn, _opts) do
    case conn.assigns[:current_user] do
      %User{} -> conn
      nil -> conn |> redirect(to: "/") |> halt()
    end
  end

  @doc """
  Plug: halts unless the current user (see `fetch_current_user/2`) is an
  admin. Anonymous visitors are sent to the start page, which offers
  sign-in; signed-in users who are not admins get a 403.
  """
  @spec require_admin(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def require_admin(conn, _opts) do
    case conn.assigns[:current_user] do
      %User{admin: true} ->
        conn

      %User{} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "Only admins can open this page.")
        |> halt()

      nil ->
        conn |> redirect(to: "/") |> halt()
    end
  end

  @doc "LiveView `on_mount` hooks; see the module documentation."
  def on_mount(:require_user, _params, session, socket) do
    case user_from_session(session) do
      {:ok, user} -> {:cont, assign_user(socket, user, session)}
      :error -> {:halt, LiveView.redirect(socket, to: "/")}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    case admin_from_session(session) do
      {:ok, user} -> {:cont, assign_admin(socket, user, session)}
      :error -> {:halt, LiveView.redirect(socket, to: "/")}
    end
  end

  def on_mount(:admin_ui, _params, session, socket) do
    case admin_from_session(session) do
      {:ok, user} ->
        socket =
          socket
          |> assign_admin(user, session)
          |> LiveView.attach_hook(:pin_admin_params, :handle_params, fn _params, _uri, socket ->
            pin_admin_actor(:params, socket)
          end)
          |> LiveView.attach_hook(:pin_admin_events, :handle_event, fn event, _params, socket ->
            pin_admin_actor({:event, event}, socket)
          end)

        {:cont, socket}

      :error ->
        {:halt, LiveView.redirect(socket, to: "/")}
    end
  end

  @doc """
  The AshAdmin hook behind `on_mount(:admin_ui, ...)`, run before
  AshAdmin's own `handle_params` and `handle_event`.

  AshAdmin takes its actor and whether to authorise from cookies and
  connect parameters, which the browser controls, and from events that
  change them. This re-reads the signed-in user (see `current_admin/1`),
  halts with a redirect when they are no longer an admin or the sign-in
  expired, ignores the actor, authorisation, and tenant events, and
  otherwise assigns the user as the actor with authorisation on. AshAdmin
  passes those assigns to every action it runs, so the resources' policies
  always decide.
  """
  @spec pin_admin_actor(:params | {:event, String.t()}, LiveView.Socket.t()) ::
          {:cont | :halt, LiveView.Socket.t()}
  def pin_admin_actor({:event, event}, socket) when event in @pinned_events,
    do: {:halt, socket}

  def pin_admin_actor(_trigger, socket) do
    case current_admin(socket) do
      {:ok, user} ->
        {:cont,
         Phoenix.Component.assign(socket,
           current_user: user,
           actor: user,
           authorizing: true,
           actor_paused: false,
           actor_resources: [],
           tenant: nil,
           actor_tenant: nil
         )}

      :error ->
        {:halt, LiveView.redirect(socket, to: "/")}
    end
  end

  @doc """
  The admin a mounted LiveView (see `on_mount/4`) belongs to, read again:
  `:error` once the user is gone, is no longer an admin, or the sign-in is
  older than `max_age/0`. A socket can stay connected for longer than any
  of these hold, so long-lived pages check it before acting.
  """
  @spec current_admin(LiveView.Socket.t()) :: {:ok, User.t()} | :error
  def current_admin(%{assigns: %{current_user: %User{id: id}, signed_in_at: signed_in_at}}) do
    admin_from_session(%{"user_id" => id, "signed_in_at" => signed_in_at})
  end

  def current_admin(_socket), do: :error

  @doc """
  The user a mounted LiveView (see `on_mount/4`) belongs to, read again:
  `:error` once the user is gone or the sign-in is older than `max_age/0`.
  Long-lived pages check it before acting, as with `current_admin/1`.
  """
  @spec current_user(LiveView.Socket.t()) :: {:ok, User.t()} | :error
  def current_user(%{assigns: %{current_user: %User{id: id}, signed_in_at: signed_in_at}}) do
    user_from_session(%{"user_id" => id, "signed_in_at" => signed_in_at})
  end

  def current_user(_socket), do: :error

  defp assign_admin(socket, user, session), do: assign_user(socket, user, session)

  defp assign_user(socket, user, session) do
    Phoenix.Component.assign(socket,
      current_user: user,
      signed_in_at: Map.fetch!(session, "signed_in_at")
    )
  end

  defp admin_from_session(session) do
    case user_from_session(session) do
      {:ok, %User{admin: true} = user} -> {:ok, user}
      _other -> :error
    end
  end

  # Plug sessions have string keys, as do LiveView sessions.
  defp user_from_session(%{"user_id" => id, "signed_in_at" => signed_in_at})
       when is_binary(id) and is_integer(signed_in_at) do
    with true <- (System.os_time(:second) - signed_in_at) in 0..@max_age,
         {:ok, %User{} = user} <- User.get(id) do
      {:ok, user}
    else
      _expired_or_unknown -> :error
    end
  end

  defp user_from_session(_session), do: :error
end
