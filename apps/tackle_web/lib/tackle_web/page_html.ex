defmodule Tackle.Web.PageHTML do
  @moduledoc false

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  alias Tackle.Web.{Setup, SetupHTML}

  def home(assigns) do
    ~H"""
    <main>
      <h1>tackle</h1>
      <p>Reviews pull requests of the repositories the GitHub App is installed on.</p>

      <p :if={!Setup.complete?(@setup)}>
        Not set up yet: <a href="/setup">set up tackle</a> with the setup token from the server log.
      </p>

      <%= if @current_user do %>
        <p>
          Signed in as <strong>{@current_user.login}</strong>{if @current_user.admin,
            do: " (admin)"}.
        </p>
        <ul>
          <li>
            <a href="/setup/github/install">Install the GitHub App</a>
            on your account or organisation; you own what you install
          </li>
          <li><a href="/codex-login">Connect one of your OpenAI Codex providers</a></li>
        </ul>
        <ul :if={@current_user.admin}>
          <li><a href="/admin">Administration</a>: repositories, providers, reviews</li>
          <li>
            <SetupHTML.sync_button />
            to record installations and repositories that webhooks missed
          </li>
        </ul>
        <.sign_out />
      <% else %>
        <p :if={@setup.forge_app}><a class="button" href="/auth/github">Sign in with GitHub</a></p>
      <% end %>
    </main>
    """
  end

  @doc "The sign-out button: a CSRF-protected POST."
  def sign_out(assigns) do
    ~H"""
    <form action="/sign-out" method="post">
      <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
      <button type="submit">Sign out</button>
    </form>
    """
  end
end
