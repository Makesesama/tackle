defmodule Tackle.Web.PageController do
  @moduledoc "`GET /`: who is signed in, and where to go from here."

  use Phoenix.Controller, formats: [:html]

  alias Tackle.Web.Setup

  def home(conn, _params) do
    conn
    |> put_view(Tackle.Web.PageHTML)
    |> render(:home,
      current_user: conn.assigns.current_user,
      setup: Setup.status()
    )
  end
end
