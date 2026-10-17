defmodule Tackle.Web.ReposLive do
  @moduledoc """
  `/repos`: the signed-in user's repositories, grouped by installation,
  with each one's latest review. Only what the user owns or was granted is
  listed (`Tackle.Web.Forges.AccessCheck`), admins included: AshAdmin is
  where admins see everything.
  """

  use Phoenix.LiveView

  require Ash.Query

  import Tackle.Web.Live
  import Tackle.Web.UI

  alias Tackle.Web.Forges.{AccessCheck, Installation, Repository}
  alias Tackle.Web.SetupHTML

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Repositories") |> load() |> schedule_refresh()}
  end

  @impl true
  def handle_info(:refresh, socket),
    do: with_user(socket, &(&1 |> load() |> schedule_refresh()))

  defp load(socket) do
    user = socket.assigns.current_user

    installations =
      Installation
      |> Ash.Query.do_filter(AccessCheck.visible(user, at: :installation))
      |> Ash.Query.filter(status != :removed)
      |> Ash.Query.sort(:account)
      |> Ash.read!(actor: user)

    repositories =
      Repository
      |> Ash.Query.do_filter(AccessCheck.visible(user, at: :repository))
      |> Ash.Query.filter(active == true)
      |> Ash.Query.sort([:owner, :name])
      |> Ash.Query.load(latest_request: [latest_run: [:shown_findings]])
      |> Ash.read!(actor: user)
      |> Enum.group_by(& &1.installation_id)

    groups =
      Enum.map(installations, fn installation ->
        %{
          installation: installation,
          owner?: Installation.owned_by?(installation, user),
          repositories: Map.get(repositories, installation.id, [])
        }
      end)

    assign(socket, :groups, groups)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Repositories">
      <:subtitle>Pull request reviews of the repositories you installed tackle on or were given access to.</:subtitle>
      <:actions>
        <SetupHTML.sync_button :if={@current_user.admin} />
        <a class="button" href="/setup/github/install">Install on GitHub</a>
      </:actions>
    </.page_header>

    <.empty :if={@groups == []}>
      <p><strong>No repositories yet.</strong></p>
      <p class="muted">
        Install the GitHub App on your account or organisation to review its pull requests,
        or ask the owner of an installation to give you access.
      </p>
      <p><a class="button" href="/setup/github/install">Install on GitHub</a></p>
    </.empty>

    <section :for={group <- @groups} class="card">
      <div class="card-header">
        <h2>
          {group.installation.account}
          <span :if={group.owner?} class="badge">Yours</span>
          <span :if={!group.owner?} class="badge">Shared with you</span>
          <span :if={group.installation.status == :suspended} class="badge status-failed">
            Suspended
          </span>
        </h2>
        <a :if={group.owner?} href={"/installations/#{group.installation.id}"}>Settings</a>
      </div>

      <p :if={group.repositories == []} class="muted">No repositories.</p>

      <table :if={group.repositories != []} class="list">
        <tbody>
          <tr :for={repository <- group.repositories}>
            <td>
              <a class="strong" href={"/repos/#{repository.id}"}>{repository.name}</a>
              <div class="muted small">
                {if repository.enabled,
                  do: auto_review_label(repository.auto_review),
                  else: "Reviews off"}
              </div>
            </td>
            <td class="latest">
              <.latest repository={repository} />
            </td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  attr :repository, Repository, required: true

  defp latest(%{repository: %{latest_request: nil}} = assigns) do
    ~H"""
    <span class="muted small">No reviews yet</span>
    """
  end

  defp latest(assigns) do
    assigns = assign(assigns, :request, assigns.repository.latest_request)

    ~H"""
    <a href={"/reviews/#{@request.id}"} class="row-link">
      <.status_badge status={@request.status} />
      <.verdict_badge :if={@request.latest_run} verdict={@request.latest_run.verdict} />
      <span class="pr">#{@request.pull_number} {@request.title}</span>
      <span class="muted small"><.time at={@request.updated_at} /></span>
    </a>
    """
  end
end
