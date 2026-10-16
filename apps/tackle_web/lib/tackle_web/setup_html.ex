defmodule Tackle.Web.SetupHTML do
  @moduledoc false

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  @doc "The HTTP status and the message shown for a failed setup step."
  @spec failure(atom()) :: {pos_integer(), String.t()}
  def failure(:forbidden),
    do: {403, "Setup is locked. Enter the setup token from the server log on the setup page."}

  def failure(:app_exists),
    do: {409, "A GitHub App is stored already. Continue on the setup page."}

  def failure(:invalid_state),
    do: {400, "This step expired or did not start here. Start again on the setup page."}

  def failure(:registration_failed),
    do:
      {502,
       "GitHub did not hand over the new App. The code is valid for an hour and works once; " <>
         "start again on the setup page (delete the half-created App on GitHub first)."}

  def failure(:store_failed),
    do:
      {500,
       "GitHub created the App, but it could not be stored here (see the server log). " <>
         "Delete the App on GitHub and start again on the setup page."}

  def failure(:invalid_owner), do: {400, "That is not a valid GitHub organisation name."}

  def failure(:not_configured), do: {409, "No GitHub App is stored yet."}

  def failure(:not_found),
    do: {404, "GitHub does not know that installation of this App."}

  def failure(:forge_unavailable),
    do: {502, "GitHub could not be reached or refused the request. Please try again."}

  def show(assigns) do
    ~H"""
    <main>
      <h1>Set up tackle</h1>
      <p :if={@error} class="error">{@error}</p>

      <%= if !@unlocked? do %>
        <p>
          The server wrote a one-time setup token to its log when it started, for example
          <code>journalctl -u tackle-web | grep 'setup token'</code>. Restarting the
          server makes a new one.
        </p>
        <form action="/setup/unlock" method="post">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <label>Setup token <input name="token" autocomplete="off" required /></label>
          <button type="submit">Unlock setup</button>
        </form>
      <% else %>
        <ol class="steps">
          <li class={if @status.forge_app, do: "done"}>
            <strong>Create the GitHub App.</strong>
            <%= if @status.forge_app do %>
              Done: App {@status.forge_app.app_id}.
            <% else %>
              <form action="/setup/github" method="post">
                <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
                <label>
                  Name <input name="name" value={@default_name} maxlength="34" required />
                </label>
                <label>
                  Organisation <input name="owner" placeholder="your personal account if empty" />
                </label>
                <button type="submit">Continue</button>
              </form>
            <% end %>
          </li>

          <li class={if @status.installed?, do: "done"}>
            <strong>Install it</strong>
            on the organisation (or account) whose pull requests it reviews.
            <%= if @status.installed? do %>
              Done.
            <% else %>
              <span :if={@status.forge_app}>
                <a class="button" href="/setup/github/install">Install the App</a>
                <.sync_button label="Installed already? Sync from GitHub" />
              </span>
            <% end %>
          </li>

          <li>
            <strong>Sign in</strong>
            with GitHub from this browser to become the first admin.
            <a :if={@status.installed?} class="button" href="/auth/github">Sign in with GitHub</a>
          </li>
        </ol>
      <% end %>
    </main>
    """
  end

  def register(assigns) do
    ~H"""
    <main>
      <h1>Create the GitHub App</h1>
      <p>
        GitHub shows the App with its permissions and lets you change its name. After you
        create it, GitHub sends you back here and on to install it.
      </p>
      <p :if={!@webhook?}>
        This server's URL is a local address GitHub cannot reach, so the App is created without
        a webhook: installations come from the install step and "Sync from GitHub", and reviews
        do not start by themselves.
      </p>
      <form action={@form.action} method="post">
        <input :for={{name, value} <- @form.fields} type="hidden" name={name} value={value} />
        <button type="submit">Create the App on GitHub</button>
      </form>
      <p><a href="/setup">Back</a></p>
    </main>
    """
  end

  def installed(assigns) do
    ~H"""
    <main>
      <h1>Installed</h1>
      <p>
        GitHub reports the installation to tackle by itself. An admin can also sync it from the
        start page.
      </p>
      <p><a href="/">Start page</a></p>
    </main>
    """
  end

  def synced(assigns) do
    ~H"""
    <main>
      <h1>Synced from GitHub</h1>
      <p>
        {@summary.installations} installation(s) with {@summary.repositories} repositories.
        New repositories take their installation's defaults; enable them in the administration.
      </p>
      <p><a href={@next}>Continue</a></p>
    </main>
    """
  end

  def failed(assigns) do
    ~H"""
    <main>
      <h1>Setup</h1>
      <p>{@message}</p>
      <p><a href="/setup">Setup page</a> · <a href="/">Start page</a></p>
    </main>
    """
  end

  @doc "A CSRF-protected button that syncs installations and repositories."
  attr :label, :string, default: "Sync from GitHub"

  def sync_button(assigns) do
    ~H"""
    <form action="/setup/sync" method="post" class="inline">
      <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
      <button type="submit">{@label}</button>
    </form>
    """
  end
end
