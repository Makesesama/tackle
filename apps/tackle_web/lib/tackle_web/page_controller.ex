defmodule Tackle.Web.PageController do
  @moduledoc "`GET /`: what tackle is and how to sign in; signed-in users go to their repositories."

  use Phoenix.Controller, formats: [:html]

  alias Tackle.Web.Setup

  def home(conn, _params) do
    case conn.assigns.current_user do
      nil ->
        conn
        |> put_view(Tackle.Web.PageHTML)
        |> render(:home, setup: Setup.status())

      _user ->
        redirect(conn, to: "/repos")
    end
  end
end
