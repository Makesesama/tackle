defmodule Tackle.HubWeb.WebhookPlug do
  @moduledoc """
  `POST /webhooks/github`: receives forge webhooks.

  Mounted in the endpoint before `Plug.Parsers`, because the signature
  covers the body exactly as sent: the raw body is read here, verified with
  the forge app's webhook secret, and only then decoded. Answers:

    * 200 with the outcome once the event was handled;
    * 401 for a missing or wrong signature;
    * 400 for a malformed payload, 413 for an oversized body;
    * 503 while the forge app is not configured;
    * 500 when handling failed (the forge shows the failed delivery, and it
      can be redelivered; handling is idempotent).

  The body has to be held in memory before its signature can be checked, so
  anyone can make the app buffer it. It is capped at 5 MB, well below
  GitHub's 25 MB limit but above what the subscribed events send (an
  `installation` event lists its repositories, about 150 bytes each; a sync
  from GitHub recovers an installation whose delivery was refused). A
  declared `content-length` above the cap is refused before anything is
  read, and nothing is read while no forge app is configured. The reverse
  proxy should limit body size (to this cap or less) and request rate too
  (see the README).
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Tackle.Hub.Forge
  alias Tackle.Hub.Forges.ForgeApp
  alias Tackle.Hub.Webhooks

  @forges %{"github" => :github}
  @max_body 5_000_000

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST", path_info: ["webhooks", name]} = conn, _opts)
      when is_map_key(@forges, name) do
    conn |> receive_delivery(Map.fetch!(@forges, name)) |> halt()
  end

  def call(conn, _opts), do: conn

  defp receive_delivery(conn, forge) do
    with {:ok, forge_app} <- forge_app(forge),
         :ok <- declared_length(conn),
         {:ok, raw_body, conn} <- read_all(conn),
         {:ok, event} <- Forge.module(forge).verify_webhook(raw_body, conn.req_headers, forge_app) do
      case Webhooks.handle(forge, event) do
        {:ok, outcome} ->
          respond(conn, 200, %{status: "ok", outcome: describe(outcome)})

        {:error, reason} ->
          Logger.error(
            "#{forge} webhook #{event.delivery_id} (#{event.type}) failed: #{inspect(reason)}"
          )

          respond(conn, 500, %{status: "error"})
      end
    else
      {:error, :too_large} -> respond(conn, 413, %{status: "too large"})
      {:error, :too_large, conn} -> respond(conn, 413, %{status: "too large"})
      {:error, :unreadable, conn} -> respond(conn, 400, %{status: "unreadable body"})
      {:error, :not_configured} -> respond(conn, 503, %{status: "not configured"})
      {:error, :invalid_signature} -> respond(conn, 401, %{status: "invalid signature"})
      {:error, :invalid_payload} -> respond(conn, 400, %{status: "invalid payload"})
    end
  end

  # Refuses a body announced as too large without reading it. A missing or
  # malformed length is left to `read_all/2`, which counts what arrives.
  defp declared_length(conn) do
    with [value] <- get_req_header(conn, "content-length"),
         {length, ""} when length > @max_body <- Integer.parse(value) do
      {:error, :too_large}
    else
      _within_or_unknown -> :ok
    end
  end

  defp read_all(conn, acc \\ []) do
    case read_body(conn, length: 1_000_000, read_timeout: 15_000) do
      {:ok, chunk, conn} -> finish_read([acc | chunk], conn)
      {:more, chunk, conn} -> continue_read([acc | chunk], conn)
      {:error, _reason} -> {:error, :unreadable, conn}
    end
  end

  defp continue_read(acc, conn) do
    if IO.iodata_length(acc) > @max_body,
      do: {:error, :too_large, conn},
      else: read_all(conn, acc)
  end

  defp finish_read(acc, conn) do
    if IO.iodata_length(acc) > @max_body,
      do: {:error, :too_large, conn},
      else: {:ok, IO.iodata_to_binary(acc), conn}
  end

  defp forge_app(forge) do
    case ForgeApp.get(forge) do
      {:ok, %ForgeApp{} = forge_app} -> {:ok, forge_app}
      {:ok, nil} -> {:error, :not_configured}
      {:error, reason} -> raise Ash.Error.to_error_class(reason)
    end
  end

  defp describe(outcome) when is_atom(outcome), do: Atom.to_string(outcome)
  defp describe({kind, detail}), do: "#{kind}: #{inspect(detail)}"

  defp respond(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
