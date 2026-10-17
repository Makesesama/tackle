defmodule Tackle.Web.Router do
  @moduledoc """
  Routes. Forge webhooks are answered by `Tackle.Web.WebhookPlug` in the
  endpoint, before these.

  Browser routes have a session, CSRF protection, and `:current_user`
  (`Tackle.Web.Auth`). Sign-in is our own OAuth flow through the forge app
  (`Tackle.Web.AuthController`); `/setup` registers and installs that app
  (`Tackle.Web.SetupController`). The Codex login page requires a signed-in
  user, and AshAdmin (`/admin`) an admin, on the HTTP request and again on
  every LiveView mount; both run their actions as that user, so the
  resources' policies decide what they may do.
  """

  use Phoenix.Router

  import AshAdmin.Router
  import Phoenix.LiveView.Router
  import Tackle.Web.Auth, only: [fetch_current_user: 2, require_admin: 2, require_user: 2]

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Tackle.Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :user do
    plug :require_user
  end

  pipeline :admin do
    plug :require_admin
  end

  scope "/", Tackle.Web do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/", Tackle.Web do
    pipe_through :browser

    get "/", PageController, :home
    get "/auth/:forge", AuthController, :request
    get "/auth/:forge/callback", AuthController, :callback
    post "/sign-out", AuthController, :sign_out

    # First-run setup and GitHub App installation (Tackle.Web.Setup); each
    # action checks the setup session or an admin itself.
    get "/setup", SetupController, :show
    post "/setup/unlock", SetupController, :unlock
    post "/setup/github", SetupController, :register
    get "/setup/github/callback", SetupController, :registered
    get "/setup/github/install", SetupController, :install
    get "/setup/github/installed", SetupController, :installed
    post "/setup/sync", SetupController, :sync
  end

  scope "/", Tackle.Web do
    pipe_through [:browser, :user]

    live_session :user, on_mount: [{Tackle.Web.Auth, :require_user}] do
      live "/codex-login", CodexLoginLive
    end
  end

  scope "/" do
    pipe_through [:browser, :admin]

    ash_admin("/admin", on_mount: [{Tackle.Web.Auth, :admin_ui}])
  end
end
