defmodule Tackle.HubWeb.GrantsComponent do
  @moduledoc """
  Who else may read an installation's repositories and reviews, for its
  owner (docs/TACKLE_HUB_PLAN.md §7.12): the grants, a form to grant a
  GitHub login access, and revoking. On a repository's page (`repository`
  set) it lists the grants that cover that repository and grants either it
  or the whole installation; on the installation's page, every grant.

  Only the owner's pages render it; the policies of
  `Tackle.Hub.Forges.Access` decide every read and write regardless, with
  the user read again before each event.
  """

  use Phoenix.LiveComponent

  require Ash.Query

  import Tackle.HubWeb.UI

  alias Tackle.Hub.Forges.{Access, Installation}
  alias Tackle.HubWeb.Auth

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:notice, fn -> nil end)
     |> load()}
  end

  @impl true
  def handle_event("grant", %{"form" => params}, socket) do
    with_user(socket, fn socket ->
      if Installation.owned_by?(socket.assigns.installation, socket.assigns.current_user),
        do: grant(socket, params),
        else: assign(socket, :notice, "Only the installation's owner gives access.")
    end)
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    with_user(socket, fn socket ->
      user = socket.assigns.current_user

      with {:ok, %Access{} = access} <- Ash.get(Access, id, actor: user),
           :ok <- Access.revoke(access, actor: user) do
        socket |> assign(:notice, "#{access.login} no longer has access.") |> load()
      else
        _error -> assign(socket, :notice, "That grant could not be revoked.")
      end
    end)
  end

  defp grant(socket, params) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, access} -> socket |> assign(:notice, "#{access.login} can now see it.") |> load()
      {:error, form} -> assign(socket, form: to_form(form), notice: nil)
    end
  end

  defp with_user(socket, fun) do
    case Auth.current_user(socket) do
      {:ok, user} -> {:noreply, fun.(assign(socket, :current_user, user))}
      :error -> {:noreply, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end

  defp load(socket) do
    %{installation: installation, current_user: user} = socket.assigns
    repository = socket.assigns[:repository]

    grants =
      Access
      |> Ash.Query.filter(installation_id == ^installation.id)
      |> then(fn query ->
        if repository,
          do: Ash.Query.filter(query, is_nil(repository_id) or repository_id == ^repository.id),
          else: query
      end)
      |> Ash.Query.sort(:login)
      |> Ash.Query.load(:repository)
      |> Ash.read!(actor: user)

    assign(socket, grants: grants, form: grant_form(installation, repository, user))
  end

  # The scope select picks the repository or the whole installation; the
  # ids always come from the page, never from the browser. AshPhoenix may
  # transform the same params more than once, so `scope` is kept.
  defp grant_form(installation, repository, user) do
    Access
    |> AshPhoenix.Form.for_create(:grant,
      actor: user,
      params: %{"scope" => if(repository, do: "repository", else: "installation")},
      transform_params: fn _form, params, _action ->
        repository_id =
          if repository && params["scope"] == "repository", do: repository.id, else: nil

        params
        |> Map.take(["login", "scope"])
        |> Map.merge(%{"installation_id" => installation.id, "repository_id" => repository_id})
      end
    )
    |> to_form()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="card">
      <div class="card-header">
        <h2>Access</h2>
      </div>
      <p class="muted">
        You own this installation. People you add can see
        {if @repository, do: "this repository", else: "its repositories"} and their reviews,
        but not change anything.
      </p>

      <table :if={@grants != []} class="list">
        <tbody>
          <tr :for={grant <- @grants}>
            <td>
              <span class="strong">{grant.login}</span>
              <div class="muted small">
                {if grant.repository,
                  do: grant.repository.name,
                  else: "All repositories of #{@installation.account}"}
              </div>
            </td>
            <td class="right">
              <button
                class="small secondary"
                phx-click="revoke"
                phx-value-id={grant.id}
                phx-target={@myself}
                data-confirm={"Remove #{grant.login}'s access?"}
                phx-disable-with="Removing…"
              >
                Remove
              </button>
            </td>
          </tr>
        </tbody>
      </table>
      <p :if={@grants == []} class="muted small">Nobody else has access.</p>

      <.form for={@form} phx-submit="grant" phx-target={@myself} class="inline-form">
        <.input field={@form[:login]} label="GitHub login" placeholder="octocat" required />
        <.input
          :if={@repository}
          field={@form[:scope]}
          type="select"
          label="To"
          options={[
            {"This repository", "repository"},
            {"All repositories of #{@installation.account}", "installation"}
          ]}
        />
        <button type="submit" phx-disable-with="Checking…">Give access</button>
      </.form>
      <p :if={@notice} class="notice">{@notice}</p>
    </section>
    """
  end
end
