defmodule Tackle.Web.Layouts do
  @moduledoc """
  The root layout of the app's own pages (AshAdmin brings its own). Plain
  CSS and the Phoenix and LiveView clients from their packages, served by
  the endpoint; nothing is built.
  """

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>{assigns[:page_title] || "tackle"}</title>
        <link rel="stylesheet" href="/assets/app.css" />
        <script defer src="/vendor/phoenix/phoenix.min.js">
        </script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.min.js">
        </script>
        <script defer src="/assets/app.js">
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
