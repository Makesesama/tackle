defmodule Tackle.Web.CodexLoginLive do
  @moduledoc """
  `/codex-login`: connects one of the signed-in user's OpenAI Codex
  providers through the device-code flow (docs/TACKLE_WEB_PLAN.md §7.2,
  §7.12), which AshAdmin cannot do.

  Any signed-in user reaches it, for their own providers only: the router
  requires a user for the HTTP request, the `{Tackle.Web.Auth,
  :require_user}` hook again on both the HTTP and the connected mount, and
  starting a login re-reads the user (`Tackle.Web.Auth.current_user/1`) and
  names the provider by that user's id, so a sign-in expired since the page
  opened stops it and another user's provider cannot be chosen.
  `Tackle.Web.Models.CodexDevice` stores the credentials directly; the page
  only shows the user code and the verification URL. Device polling runs as
  a LiveView async task, which is cancelled when the page process exits.
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
     |> assign(:providers, codex_providers(socket.assigns.current_user))}
  end

  @impl true
  def handle_event("login", _params, %{assigns: %{status: status}} = socket)
      when status in [:requesting, :waiting], do: {:noreply, socket}

  def handle_event("login", %{"provider" => name}, socket) when is_binary(name) do
    case Auth.current_user(socket) do
      {:ok, user} ->
        socket =
          socket
          |> assign(:status, :requesting)
          |> assign(:device, nil)
          |> start_async(:request_code, fn -> CodexDevice.request(user.id, name) end)

        {:noreply, socket}

      :error ->
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

  # The user's own Codex providers, read as the user.
  defp codex_providers(user) do
    Provider
    |> Ash.Query.filter(adapter == :codex and owner_id == ^user.id)
    |> Ash.Query.sort(:name)
    |> Ash.read!(actor: user)
    |> Enum.map(& &1.name)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <h1>Codex login</h1>
      <p>
        Signs a ChatGPT subscription in for one of your OpenAI Codex providers (adapter
        <code>codex</code>).
      </p>
      <%= if @providers == [] do %>
        <p>You have no Codex provider yet.</p>
      <% else %>
        <form phx-submit="login">
          <label>
            Provider
            <select name="provider">
              <option :for={name <- @providers} value={name}>{name}</option>
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
