defmodule Tackle.Web.ReposLive do
  @moduledoc """
  `/repos`: the signed-in user's repositories, grouped by installation,
  with each one's latest review. Only what the user owns or was granted is
  listed (`Tackle.Web.Forges.AccessCheck`), admins included: AshAdmin is
  where admins see everything.

  Until the user's own reviews can run, a checklist above them says what
  is missing: an installation of their own, a connected and enabled model
  provider, the detector and verifier models, and a first review. Users
  who only see installations shared with them do not get it.
  """

  use Phoenix.LiveView

  require Ash.Query

  import Tackle.Web.Live
  import Tackle.Web.UI

  alias Tackle.Web.Forges.{AccessCheck, Installation, Repository}
  alias Tackle.Web.Models.{Provider, ReviewDefaults}
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

    assign(socket, groups: groups, steps: steps(user, groups))
  end

  # What the user's own reviews still need, in order; none once all is done
  # or when the user only sees what was shared with them.
  defp steps(user, groups) do
    owned = Enum.filter(groups, & &1.owner?)

    if groups != [] and owned == [] do
      []
    else
      steps = setup_steps(user, owned)
      if Enum.all?(steps, & &1.done), do: [], else: steps
    end
  end

  defp setup_steps(user, owned) do
    providers =
      Provider
      |> Ash.Query.filter(owner_id == ^user.id)
      |> Ash.Query.load(:connected)
      |> Ash.read!(actor: user)

    {:ok, defaults} = ReviewDefaults.get(user.id, actor: user)
    models = (defaults && defaults.models) || %{}

    [
      %{
        id: :install,
        done: owned != [],
        link: {:href, "/setup/github/install"},
        action: "Install tackle",
        text: "on your GitHub account or organisation, for the repositories to review."
      },
      %{
        id: :provider,
        done: Enum.any?(providers, &(&1.connected and &1.enabled)),
        link: {:navigate, "/settings"},
        action: "Connect a model provider",
        text: "with an OpenRouter API key or your ChatGPT subscription."
      },
      %{
        id: :models,
        done: Map.has_key?(models, "detector") and Map.has_key?(models, "verifier"),
        link: {:navigate, "/settings"},
        action: "Choose the models",
        text: "that find and verify the findings."
      },
      %{
        id: :review,
        done:
          Enum.any?(owned, fn group -> Enum.any?(group.repositories, & &1.latest_request) end),
        link: nil,
        action: "Review a pull request",
        text:
          "from a repository's page, by commenting /tackle review on it, " <>
            "or by turning on automatic reviews."
      }
    ]
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

    <section :if={@steps != []} class="card getting-started">
      <div class="card-header"><h2>Getting started</h2></div>
      <ol class="checklist">
        <li :for={step <- @steps} class={if step.done, do: "done", else: "todo"} id={"step-#{step.id}"}>
          <span class="check" aria-hidden="true">{if step.done, do: "✓"}</span>
          <span class="visually-hidden">{if step.done, do: "Done:", else: "To do:"}</span>
          <span>
            <.step_action link={step.link} action={step.action} done={step.done} />
            {step.text}
          </span>
        </li>
      </ol>
    </section>

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
        <.link :if={group.owner?} navigate={"/installations/#{group.installation.id}"}>
          Settings
        </.link>
      </div>

      <p :if={group.repositories == []} class="muted">No repositories.</p>

      <table :if={group.repositories != []} class="list">
        <tbody>
          <tr :for={repository <- group.repositories}>
            <td>
              <.link class="strong" navigate={"/repos/#{repository.id}"}>{repository.name}</.link>
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
    <.link navigate={"/reviews/#{@request.id}"} class="row-link">
      <.status_badge status={@request.status} />
      <.verdict_badge :if={@request.latest_run} verdict={@request.latest_run.verdict} />
      <span class="pr">#{@request.pull_number} {@request.title}</span>
      <span class="muted small"><.time at={@request.updated_at} /></span>
    </.link>
    """
  end

  attr :link, :any, required: true
  attr :action, :string, required: true
  attr :done, :boolean, required: true

  defp step_action(%{link: {:href, to}, done: false} = assigns) do
    assigns = assign(assigns, :to, to)

    ~H"""
    <a class="strong" href={@to}>{@action}</a>
    """
  end

  defp step_action(%{link: {:navigate, to}, done: false} = assigns) do
    assigns = assign(assigns, :to, to)

    ~H"""
    <.link class="strong" navigate={@to}>{@action}</.link>
    """
  end

  defp step_action(assigns) do
    ~H"""
    <span class="strong">{@action}</span>
    """
  end
end
