defmodule Tackle.Web.CodexLoginLive do
  @moduledoc """
  Unmounted device-code page. Do not add a route until signed-in admin access,
  CSRF-protected browser sessions and an on_mount authorisation guard exist
  (phase 6). The guard must check the admin on both HTTP and connected mounts.

  Deliberately fails closed today: `mount/3` always rejects access. Phase 6
  must replace this check with its authenticated actor check, not trust route
  params or client-supplied session flags. Device polling runs as a LiveView
  async task, which is cancelled when the page process exits.
  """

  use Phoenix.LiveView

  alias Tackle.Web.Models.CodexDevice

  @impl true
  def mount(_params, _session, _socket), do: {:error, :admin_authentication_not_implemented}

  @impl true
  def handle_event("login", _params, %{assigns: %{status: status}} = socket)
      when status in [:requesting, :waiting], do: {:noreply, socket}

  def handle_event("login", %{"provider_id" => id}, socket) do
    socket =
      socket
      |> assign(:status, :requesting)
      |> assign(:device, nil)
      |> start_async(:request_code, fn -> CodexDevice.request(id) end)

    {:noreply, socket}
  end

  @impl true
  def handle_async(:request_code, {:ok, {:ok, flow}}, socket) do
    {:noreply,
     socket
     |> assign(:device, flow.device)
     |> assign(:status, :waiting)
     |> start_async(:complete_login, fn -> CodexDevice.complete(flow) end)}
  end

  def handle_async(:complete_login, {:ok, :ok}, socket) do
    {:noreply, socket |> assign(:device, nil) |> assign(:status, :complete)}
  end

  # Do not render OAuth errors: upstream bodies may contain secrets.
  def handle_async(_name, _failure, socket) do
    {:noreply, socket |> assign(:device, nil) |> assign(:status, :failed)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <h1>Codex login</h1>
      <form phx-submit="login">
        <label>Provider id <input name="provider_id" required /></label>
        <button disabled={@status in [:requesting, :waiting]}>Connect Codex</button>
      </form>
      <p :if={@device}>
        Open <a href={@device.verification_uri}>{@device.verification_uri}</a>
        and enter <strong>{@device.user_code}</strong>.
      </p>
      <p>Status: {@status}</p>
    </main>
    """
  end
end
