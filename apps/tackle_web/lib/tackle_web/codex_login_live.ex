defmodule Tackle.Web.CodexLoginLive do
  @moduledoc """
  `/codex-login`: connects an OpenAI Codex provider through the device-code
  flow (docs/TACKLE_WEB_PLAN.md §7.2), which AshAdmin cannot do.

  Only admins reach it: the router requires one for the HTTP request, the
  `{Tackle.Web.Auth, :require_admin}` hook again on both the HTTP and the
  connected mount, and starting a login re-reads the user
  (`Tackle.Web.Auth.current_admin/1`), so an admin flag revoked, or a sign-in
  expired, since the page opened stops it. `Tackle.Web.Models.CodexDevice`
  stores the credentials directly; the page only shows the user code and the
  verification URL. Device polling runs as a LiveView async task, which is
  cancelled when the page process exits.
  """

  use Phoenix.LiveView

  require Ash.Query

  alias Tackle.Web.Auth
  alias Tackle.Web.Models.{CodexDevice, Provider}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Codex login")
     |> assign(:status, :ready)
     |> assign(:device, nil)
     |> assign(:providers, codex_providers())}
  end

  @impl true
  def handle_event("login", _params, %{assigns: %{status: status}} = socket)
      when status in [:requesting, :waiting], do: {:noreply, socket}

  def handle_event("login", %{"provider_id" => id}, socket) when is_binary(id) do
    if still_admin?(socket) do
      socket =
        socket
        |> assign(:status, :requesting)
        |> assign(:device, nil)
        |> start_async(:request_code, fn -> CodexDevice.request(id) end)

      {:noreply, socket}
    else
      {:noreply, redirect(socket, to: "/")}
    end
  end

  def handle_event("login", _params, socket), do: {:noreply, socket}

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

  defp still_admin?(socket), do: match?({:ok, _admin}, Auth.current_admin(socket))

  # Trusted read: the page is admin-only, and the ids are not secret.
  defp codex_providers do
    Provider
    |> Ash.Query.filter(adapter == :codex)
    |> Ash.Query.sort(:id)
    |> Ash.read!()
    |> Enum.map(& &1.id)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <h1>Codex login</h1>
      <p>
        Signs a ChatGPT subscription in for an OpenAI Codex provider. Register the provider
        (adapter <code>codex</code>) in the <a href="/admin">administration</a> first.
      </p>
      <%= if @providers == [] do %>
        <p>There is no Codex provider yet.</p>
      <% else %>
        <form phx-submit="login">
          <label>
            Provider
            <select name="provider_id">
              <option :for={id <- @providers} value={id}>{id}</option>
            </select>
          </label>
          <button disabled={@status in [:requesting, :waiting]}>Connect Codex</button>
        </form>
      <% end %>
      <p :if={@device}>
        Open <a href={@device.verification_uri} rel="noreferrer">{@device.verification_uri}</a>
        and enter <strong>{@device.user_code}</strong>.
      </p>
      <p>Status: {@status}</p>
      <p><a href="/">Back to the start page</a></p>
    </main>
    """
  end
end
