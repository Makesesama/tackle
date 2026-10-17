defmodule Tackle.Web.PageHTML do
  @moduledoc false

  use Phoenix.Component

  import Tackle.Web.UI, only: [logo: 1]

  alias Tackle.Web.Setup

  def home(assigns) do
    ~H"""
    <main class="landing">
      <.logo class="hero-logo" />
      <h1>tackle</h1>
      <p class="lead">Reviews your pull requests, and posts what it finds on GitHub.</p>

      <p :if={!Setup.complete?(@setup)} class="notice">
        Not set up yet: <a href="/setup">set up tackle</a> with the setup token from the server log.
      </p>

      <p :if={@setup.forge_app}>
        <a class="button large" href="/auth/github">Sign in with GitHub</a>
      </p>
      <p :if={@setup.forge_app} class="muted small">
        Sign in to install it on your repositories, or to see the ones shared with you.
      </p>
    </main>
    """
  end
end
