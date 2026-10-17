defmodule Tackle.Web.Endpoint do
  @moduledoc """
  The HTTP endpoint: forge webhooks, the health check, and the signed-in
  pages (sign-in, the user pages, AshAdmin) with their session and LiveView
  socket.

  Two settings are read at runtime rather than compiled in, so a release
  can follow `TACKLE_WEB_URL` (config/runtime.exs):

    * `config :tackle_web, :force_ssl` - `Plug.SSL` options; when set,
      plain HTTP is redirected to HTTPS and HSTS is sent. Phoenix's own
      `:force_ssl` endpoint option is compile-time only.
    * `config :tackle_web, :secure_cookies` - whether the session cookie is
      only sent over HTTPS.
  """

  use Phoenix.Endpoint, otp_app: :tackle_web

  # Signed and encrypted with keys derived from SECRET_KEY_BASE. The salts
  # are not secret. `max_age` bounds the cookie; Tackle.Web.Auth also checks
  # the sign-in time stored in it.
  @session_options [
    store: :cookie,
    key: "_tackle_web",
    signing_salt: "pvKt1YQs",
    encryption_salt: "f9Dx0RcW",
    same_site: "Lax",
    http_only: true,
    max_age: 7 * 24 * 60 * 60
  ]

  @doc "The session cookie's options, with `:secure` from the runtime configuration."
  @spec session_options() :: keyword()
  def session_options,
    do:
      Keyword.put(
        @session_options,
        :secure,
        Application.get_env(:tackle_web, :secure_cookies, false)
      )

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {__MODULE__, :session_options, []}]],
    longpoll: false

  plug :force_ssl

  # The pages' own script and style, and the Phoenix and LiveView clients
  # from their packages: no asset build step. AshAdmin inlines its own.
  plug Plug.Static,
    at: "/assets",
    from: {:tackle_web, "priv/static/assets"},
    only: ~w(app.css app.js logo.svg)

  plug Plug.Static,
    at: "/vendor/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/vendor/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Forge webhooks need the raw body for their signature: before the parsers.
  plug Tackle.Web.WebhookPlug

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: JSON,
    length: 1_000_000

  plug Plug.Head
  plug :session
  plug Tackle.Web.Router

  defp force_ssl(conn, _opts) do
    case Application.get_env(:tackle_web, :force_ssl) do
      nil -> conn
      opts -> Plug.SSL.call(conn, Plug.SSL.init(opts))
    end
  end

  defp session(conn, _opts), do: Plug.Session.call(conn, Plug.Session.init(session_options()))
end
