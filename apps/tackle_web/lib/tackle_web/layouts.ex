defmodule Tackle.Web.Layouts do
  @moduledoc """
  The layouts of the app's own pages (AshAdmin brings its own). Plain CSS
  and the Phoenix and LiveView clients from their packages, served by the
  endpoint; nothing is built.

    * `root/1` - the document, with the top bar (`Tackle.Web.UI.top_bar/1`);
    * `app/1` - the LiveView pages' layout: flash messages and the page.
  """

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  alias Tackle.Web.UI

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>{if assigns[:page_title], do: "#{assigns[:page_title]} · tackle", else: "tackle"}</title>
        <link rel="icon" type="image/svg+xml" href="/assets/logo.svg" />
        <link rel="stylesheet" href="/assets/app.css" />
        <script defer src="/vendor/phoenix/phoenix.min.js">
        </script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.min.js">
        </script>
        <script defer src="/assets/app.js">
        </script>
      </head>
      <body>
        <UI.top_bar current_user={assigns[:current_user]} />
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <div class="page">
      <UI.flash flash={@flash} />
      {@inner_content}
    </div>
    """
  end
end
