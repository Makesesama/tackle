defmodule Tackle.Web.HealthController do
  @moduledoc """
  `GET /health`: 200 when the app can serve requests, 503 otherwise. The
  response names the failing check, not its error, which is logged.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Tackle.Web.Health

  def show(conn, _params) do
    case Health.check() do
      :ok ->
        json(conn, %{status: "ok"})

      {:error, {check, reason}} ->
        Logger.warning("health check #{check} failed: #{Exception.message(reason)}")

        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "unavailable", failed: check})
    end
  end
end
