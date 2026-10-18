defmodule Tackle.HubWeb.CodexLoginLive do
  @moduledoc """
  `/codex-login`: connects one of the signed-in user's OpenAI Codex
  providers through the device-code flow (docs/TACKLE_HUB_PLAN.md §7.2,
  §7.12), which AshAdmin cannot do.

  Any signed-in user reaches it, for their own providers only: the router
  requires a user for the HTTP request, the `{Tackle.HubWeb.Auth,
  :require_user}` hook again on both the HTTP and the connected mount, and
  starting a login re-reads the user (`Tackle.HubWeb.Auth.current_user/1`) and
  names the provider by that user's id, so a sign-in expired since the page
  opened stops it and another user's provider cannot be chosen.
  `Tackle.Hub.Models.CodexDevice` stores the credentials directly; the page
  only shows the user code and the verification URL. Device polling runs as
  a LiveView async task, which is cancelled when the page process exits.
  `?provider=<name>` preselects one of the user's providers (the Models
  page links that way), and a provider is enabled when it is first
  connected (`Tackle.Hub.Models.Provider`).
  """

  use Phoenix.LiveView

  require Ash.Query

  import Tackle.HubWeb.UI, only: [page_header: 1]

  alias Tackle.Hub.Models.{CodexDevice, Provider}
  alias Tackle.HubWeb.Auth

  @impl true
  def mount(params, _session, socket) do
    providers = codex_providers(socket.assigns.current_user)

    {:ok,
     socket
     |> assign(:page_title, "Codex login")
     |> assign(:status, :ready)
     |> assign(:device, nil)
     |> assign(:providers, providers)
     |> assign(:selected, if(params["provider"] in providers, do: params["provider"]))}
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
          |> assign(:selected, name)
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
    <.page_header title="Connect OpenAI Codex">
      <:subtitle>
        <.link navigate="/settings">Models</.link>
        · signs a ChatGPT subscription in for one of your OpenAI Codex providers
      </:subtitle>
    </.page_header>

    <section class="card">
      <%= if @providers == [] do %>
        <p>
          You have no OpenAI Codex provider yet. <.link navigate="/settings">Add one</.link>
          (kind <em>OpenAI Codex</em>) first.
        </p>
      <% else %>
        <form phx-submit="login" class="inline-form">
          <div class="field">
            <label for="provider">Provider</label>
            <select id="provider" name="provider">
              <option :for={name <- @providers} value={name} selected={name == @selected}>
                {name}
              </option>
            </select>
          </div>
          <button disabled={@status in [:requesting, :waiting]} phx-disable-with="Connecting…">
            Connect
          </button>
        </form>
      <% end %>

      <div :if={@device} class="device">
        <p>
          Open
          <a href={@device.verification_uri} target="_blank" rel="noopener noreferrer">
            {@device.verification_uri}
          </a>
          and enter this code:
        </p>
        <p class="row">
          <span class="code" id="codex-user-code">{@device.user_code}</span>
          <button
            type="button"
            class="small secondary"
            data-copy="#codex-user-code"
            data-copied="Copied"
          >
            Copy
          </button>
        </p>
      </div>
      <p :if={@status not in [:ready, :complete]} class={"notice notice-#{@status}"}>
        {status_text(@status)}
      </p>
      <p :if={@status == :complete} class="notice notice-complete">
        Connected {@selected}. Choose its models on the <.link navigate="/settings">Models</.link>
        page.
      </p>
    </section>
    """
  end

  defp status_text(:requesting), do: "Asking OpenAI for a code…"
  defp status_text(:waiting), do: "Waiting for you to enter the code…"
  defp status_text(:failed), do: "The login did not complete. Please try again."
end
