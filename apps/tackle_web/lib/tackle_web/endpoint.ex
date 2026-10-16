defmodule Tackle.Web.Endpoint do
  @moduledoc """
  The HTTP endpoint. Sessions, the LiveView socket, and static assets are
  added with the first pages (see docs/TACKLE_WEB_PLAN.md §8).
  """

  use Phoenix.Endpoint, otp_app: :tackle_web

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
  plug Tackle.Web.Router
end
