defmodule Tackle.Web.RepositoryLive do
  @moduledoc """
  `/repos/:id`: a repository's reviews, newest first. Its installation's
  owner also changes its review settings here and decides who else may see
  it (`Tackle.Web.GrantsComponent`).
  """

  use Phoenix.LiveView

  require Ash.Query

  import Tackle.Web.Live
  import Tackle.Web.UI

  alias Tackle.Web.Forge
  alias Tackle.Web.Forges.{Installation, Repository}
  alias Tackle.Web.Reviews.ReviewRequest

  @requests 50

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case get(Repository, id, socket.assigns.current_user, load: [:installation]) do
      nil ->
        not_found(socket)

      repository ->
        {:ok,
         socket
         |> assign(:page_title, "#{repository.owner}/#{repository.name}")
         |> assign_repository(repository)
         |> load_requests()
         |> schedule_refresh()}
    end
  end

  @impl true
  def handle_info(:refresh, socket),
    do: with_user(socket, &(&1 |> load_requests() |> schedule_refresh()))

  # Only the owner's page has the form.
  @impl true
  def handle_event("save", _params, %{assigns: %{form: nil}} = socket), do: {:noreply, socket}

  def handle_event("save", %{"form" => params}, socket) do
    with_user(socket, fn socket ->
      case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
        {:ok, repository} ->
          socket
          |> put_flash(:info, "Settings saved.")
          |> assign_repository(%{
            repository
            | installation: socket.assigns.repository.installation
          })

        {:error, form} ->
          assign(socket, :form, to_form(form))
      end
    end)
  end

  defp assign_repository(socket, repository) do
    user = socket.assigns.current_user
    owner? = Installation.owned_by?(repository.installation, user)

    socket
    |> assign(repository: repository, owner?: owner?)
    |> assign(:form, if(owner?, do: settings_form(repository, user)))
  end

  defp load_requests(socket) do
    requests =
      ReviewRequest
      |> Ash.Query.filter(repository_id == ^socket.assigns.repository.id)
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(@requests)
      |> Ash.Query.load(latest_run: [:shown_findings])
      |> Ash.read!(actor: socket.assigns.current_user)

    assign(socket, :requests, requests)
  end

  # `settings` is edited as JSON text; a budget left empty is no limit.
  defp settings_form(repository, user) do
    repository
    |> AshPhoenix.Form.for_update(:configure,
      actor: user,
      params: %{"settings" => JSON.encode!(repository.settings)},
      transform_params: fn _form, params, _action ->
        params
        |> update_present("settings", &decode_settings/1)
        |> update_present("daily_token_budget", &blank_to_nil/1)
      end
    )
    |> to_form()
  end

  defp decode_settings(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        %{}

      trimmed ->
        case JSON.decode(trimmed) do
          {:ok, settings} -> settings
          # Left as text, the map type refuses it with a field error.
          {:error, _reason} -> text
        end
    end
  end

  defp decode_settings(other), do: other

  defp update_present(params, key, fun) do
    case params do
      %{^key => value} -> Map.put(params, key, fun.(value))
      _absent -> params
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title={"#{@repository.owner}/#{@repository.name}"}>
      <:subtitle>
        <a href="/repos">Repositories</a>
        · {if @repository.enabled,
          do: auto_review_label(@repository.auto_review),
          else: "Reviews off"}
        <span :if={!@repository.active}>· tackle no longer has access</span>
      </:subtitle>
      <:actions>
        <a
          class="button secondary"
          href={Forge.module(@repository.installation.forge).repository_url(@repository)}
          rel="noreferrer"
        >
          On GitHub
        </a>
      </:actions>
    </.page_header>

    <section class="card">
      <div class="card-header"><h2>Reviews</h2></div>

      <.empty :if={@requests == []}>
        <p :if={@repository.enabled}>
          No reviews yet. Comment <code>/tackle review</code> on a pull request to request one.
        </p>
        <p :if={!@repository.enabled}>
          Reviews are off for this repository.
          <span :if={@owner?}>Turn them on in the settings below.</span>
        </p>
      </.empty>

      <table :if={@requests != []} class="list">
        <thead>
          <tr>
            <th>Pull request</th>
            <th>Status</th>
            <th class="hide-small">Findings</th>
            <th class="right">Updated</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={request <- @requests}>
            <td>
              <a class="strong" href={"/reviews/#{request.id}"}>
                #{request.pull_number} {request.title}
              </a>
              <div class="muted small">
                <.sha sha={request.head_sha} /> · {trigger_label(request.trigger)}
                <span :if={request.requested_by}>by {request.requested_by}</span>
              </div>
            </td>
            <td>
              <.status_badge status={request.status} />
              <.verdict_badge :if={request.latest_run} verdict={request.latest_run.verdict} />
            </td>
            <td class="hide-small">
              <span :if={request.latest_run}>{request.latest_run.shown_findings}</span>
            </td>
            <td class="right muted small"><.time at={request.updated_at} /></td>
          </tr>
        </tbody>
      </table>
    </section>

    <section :if={@owner?} class="card">
      <div class="card-header"><h2>Settings</h2></div>
      <.form for={@form} phx-submit="save">
        <.input field={@form[:enabled]} type="checkbox" label="Review pull requests" />
        <.input
          field={@form[:auto_review]}
          type="select"
          label="Review automatically"
          options={[
            {"No, only on /tackle review", "off"},
            {"New pull requests", "on_open"},
            {"New pull requests and every push", "on_open_and_push"}
          ]}
        />
        <.input field={@form[:auto_review_drafts]} type="checkbox" label="Also drafts" />
        <.input field={@form[:auto_review_forks]} type="checkbox" label="Also pull requests from forks" />
        <.input
          field={@form[:profile]}
          type="select"
          label="Profile"
          options={[{"Quiet", "quiet"}, {"Default", "default"}, {"Assertive", "assertive"}]}
          help="How many findings a review reports. A /tackle review command can pick another."
        />
        <.input
          field={@form[:daily_token_budget]}
          type="number"
          label="Daily token budget"
          min="0"
          help="Model tokens this repository's reviews may use per day (UTC). Empty for no limit."
        />
        <.input
          field={@form[:settings]}
          value={settings_text(@form[:settings].value)}
          type="textarea"
          rows="4"
          label="Review settings (JSON)"
          help={"Models, thinking levels, step limits per stage, and default rules; " <>
            "for example {\"models\": {\"detector\": \"openrouter/...\"}}. " <>
            "Unset stages use your model defaults."}
        />
        <button type="submit">Save</button>
      </.form>
    </section>

    <.live_component
      :if={@owner?}
      module={Tackle.Web.GrantsComponent}
      id="grants"
      installation={@repository.installation}
      repository={@repository}
      current_user={@current_user}
      signed_in_at={@signed_in_at}
    />
    """
  end

  defp settings_text(settings) when is_map(settings), do: JSON.encode!(settings)
  defp settings_text(text), do: text

  defp trigger_label(:command), do: "requested"
  defp trigger_label(:opened), do: "opened"
  defp trigger_label(:pushed), do: "pushed"
end
