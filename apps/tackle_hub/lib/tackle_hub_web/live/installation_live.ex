defmodule Tackle.HubWeb.InstallationLive do
  @moduledoc """
  `/installations/:id`: an installation's repositories and, for its owner,
  the defaults new repositories get and who else may see them
  (`Tackle.HubWeb.GrantsComponent`).

  The page is live (`Tackle.HubWeb.Live`): it follows the installation, its
  repositories, and its grants. An update leaves the defaults form being
  edited as it is.
  """

  use Phoenix.LiveView

  require Ash.Query

  import Tackle.HubWeb.Live
  import Tackle.HubWeb.UI

  alias Tackle.Hub.Forges.{AccessCheck, Installation, Repository}
  alias Tackle.Hub.Updates
  alias Tackle.HubWeb.GrantsComponent

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case get(Installation, id, socket.assigns.current_user) do
      nil ->
        not_found(socket)

      installation ->
        {:ok,
         socket |> assign(:page_title, installation.account) |> assign_installation(installation)}
    end
  end

  @impl true
  def handle_info({Updates, _topic}, socket), do: {:noreply, changed(socket)}
  def handle_info(:reload, socket), do: with_user(reloading(socket), &reload/1)

  # Only the owner's page has the form.
  @impl true
  def handle_event("save", _params, %{assigns: %{form: nil}} = socket), do: {:noreply, socket}

  def handle_event("save", %{"form" => params}, socket) do
    with_user(socket, fn socket ->
      case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
        {:ok, installation} ->
          socket |> put_flash(:info, "Defaults saved.") |> assign_installation(installation)

        {:error, form} ->
          assign(socket, :form, to_form(form))
      end
    end)
  end

  defp reload(socket) do
    %{installation: installation, current_user: user, owner?: owner?} = socket.assigns

    case get(Installation, installation.id, user) do
      nil ->
        socket
        |> put_flash(:error, "That installation is no longer available to you.")
        |> push_navigate(to: "/repos")

      installation ->
        socket =
          if Installation.owned_by?(installation, user) == owner?,
            do: assign_repositories(socket, installation),
            else: assign_installation(socket, installation)

        # Grants changed elsewhere: the component reads them again.
        if socket.assigns.owner?,
          do: send_update(GrantsComponent, id: "grants", installation: installation)

        socket
    end
  end

  # The owner's defaults form, made again only after saving or when the
  # page's user became or stopped being the owner.
  defp assign_installation(socket, installation) do
    user = socket.assigns.current_user
    owner? = Installation.owned_by?(installation, user)

    form =
      if owner? do
        installation
        |> AshPhoenix.Form.for_update(:set_defaults, actor: user)
        |> to_form()
      end

    socket
    |> assign(owner?: owner?, form: form)
    |> assign_repositories(installation)
  end

  defp assign_repositories(socket, installation) do
    user = socket.assigns.current_user

    repositories =
      Repository
      |> Ash.Query.filter(installation_id == ^installation.id and active == true)
      |> Ash.Query.do_filter(AccessCheck.visible(user, at: :repository))
      |> Ash.Query.sort(:name)
      |> Ash.read!(actor: user)

    socket
    |> assign(installation: installation, repositories: repositories)
    |> follow([Updates.installation(installation.id)])
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title={@installation.account}>
      <:subtitle>
        <.link navigate="/repos">Repositories</.link>
        · installed by {@installation.owner_login || "an unknown user"}
        <span :if={@installation.status != :active}>· {@installation.status}</span>
      </:subtitle>
    </.page_header>

    <section class="card">
      <div class="card-header"><h2>Repositories</h2></div>
      <p :if={@repositories == []} class="muted">No repositories.</p>
      <table :if={@repositories != []} class="list">
        <tbody>
          <tr :for={repository <- @repositories}>
            <td>
              <.link class="strong" navigate={"/repos/#{repository.id}"}>{repository.name}</.link>
            </td>
            <td class="right muted small">
              {if repository.enabled,
                do: auto_review_label(repository.auto_review),
                else: "Reviews off"}
            </td>
          </tr>
        </tbody>
      </table>
    </section>

    <section :if={@owner?} class="card">
      <div class="card-header"><h2>Defaults for new repositories</h2></div>
      <.form for={@form} phx-submit="save">
        <.input
          field={@form[:review_new_repositories]}
          type="checkbox"
          label="Review pull requests of new repositories"
        />
        <.input
          field={@form[:default_auto_review]}
          type="select"
          label="Review automatically"
          options={[
            {"No, only on /tackle review", "off"},
            {"New pull requests", "on_open"},
            {"New pull requests and every push", "on_open_and_push"}
          ]}
        />
        <.input
          field={@form[:apply_to_repositories]}
          type="checkbox"
          label="Also apply to every existing repository"
          help="Overwrites each repository's review and automatic review setting."
        />
        <button
          type="submit"
          phx-disable-with="Saving…"
          data-confirm="This overwrites whether and when every existing repository is reviewed. Save?"
          data-confirm-if={"#" <> @form[:apply_to_repositories].id}
        >
          Save
        </button>
      </.form>
    </section>

    <.live_component
      :if={@owner?}
      module={Tackle.HubWeb.GrantsComponent}
      id="grants"
      installation={@installation}
      repository={nil}
      current_user={@current_user}
      signed_in_at={@signed_in_at}
    />
    """
  end
end
