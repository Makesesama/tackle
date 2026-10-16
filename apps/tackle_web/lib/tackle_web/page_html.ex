defmodule Tackle.Web.PageHTML do
  @moduledoc false

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  def home(assigns) do
    ~H"""
    <main>
      <h1>tackle</h1>
      <p>Reviews pull requests of the repositories the GitHub App is installed on.</p>

      <%= if @current_user do %>
        <p>
          Signed in as <strong>{@current_user.login}</strong>{if @current_user.admin,
            do: " (admin)"}.
        </p>
        <ul :if={@current_user.admin}>
          <li><a href="/admin">Administration</a>: repositories, providers, reviews</li>
          <li><a href="/codex-login">Connect an OpenAI Codex provider</a></li>
        </ul>
        <p :if={!@current_user.admin}>
          Only admins can change settings. An admin can grant it from the server's console.
        </p>
        <.sign_out />
      <% else %>
        <p><a class="button" href="/auth/github">Sign in with GitHub</a></p>
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
