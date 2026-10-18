defmodule Tackle.HubWeb.RepositoryLive do
  @moduledoc """
  `/repos/:id`: a repository's reviews, newest first, and the findings
  dismissed in it. Its installation's owner also requests reviews
  (`Tackle.HubWeb.ReviewRequestComponent`), restores dismissed findings,
  changes its review settings, and decides who else may see it
  (`Tackle.HubWeb.GrantsComponent`).

  The page is live (`Tackle.HubWeb.Live`): it follows the repository, its
  reviews and dismissals, and its installation, and says what a review in
  flight is doing. An update leaves a settings form being edited as it is.
  """

  use Phoenix.LiveView

  require Ash.Query

  import Tackle.HubWeb.Live
  import Tackle.HubWeb.UI

  alias Tackle.Hub.{Forge, ReviewProgress, Updates}
  alias Tackle.Hub.Forges.{Installation, Repository}
  alias Tackle.Hub.Reviews.{Dismissal, ReviewRequest}
  alias Tackle.HubWeb.GrantsComponent

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
         |> load_requests()}
    end
  end

  @impl true
  def handle_info({Updates, _topic}, socket), do: {:noreply, changed(socket)}
  def handle_info(:reload, socket), do: with_user(reloading(socket), &reload/1)

  def handle_info({ReviewProgress, id, version, progress}, socket),
    do: with_user(socket, &put_progress(&1, id, version, progress))

  # Only the owner's page has the form.
  @impl true
  def handle_event("save", _params, %{assigns: %{form: nil}} = socket), do: {:noreply, socket}

  def handle_event("restore", %{"id" => id}, socket) do
    with_user(socket, fn socket ->
      user = socket.assigns.current_user

      with %Dismissal{repository_id: repository_id} = dismissal <- get(Dismissal, id, user),
           true <- repository_id == socket.assigns.repository.id,
           :ok <- Dismissal.restore(dismissal, actor: user) do
        socket |> put_flash(:info, "Restored: later reviews report it again.") |> load_requests()
      else
        _error -> put_flash(socket, :error, "The finding could not be restored.")
      end
    end)
  end

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

  defp reload(socket) do
    %{repository: repository, current_user: user, owner?: owner?} = socket.assigns

    case get(Repository, repository.id, user, load: [:installation]) do
      nil ->
        socket
        |> put_flash(:error, "That repository is no longer available to you.")
        |> push_navigate(to: "/repos")

      repository ->
        socket =
          if Installation.owned_by?(repository.installation, user) == owner?,
            do: assign(socket, :repository, repository),
            else: assign_repository(socket, repository)

        # Grants changed elsewhere: the component reads them again.
        if socket.assigns.owner?,
          do: send_update(GrantsComponent, id: "grants", installation: repository.installation)

        load_requests(socket)
    end
  end

  # The owner's settings form, made again only after saving or when the
  # page's user became or stopped being the owner.
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

    dismissals =
      Dismissal
      |> Ash.Query.filter(repository_id == ^socket.assigns.repository.id)
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.read!(actor: socket.assigns.current_user)

    repository = socket.assigns.repository

    in_flight =
      for %{status: status, id: id} <- requests, status in [:running, :reviewed], do: id

    topics =
      [
        Updates.repository(repository.id),
        Updates.dismissals(repository.id),
        Updates.installation(repository.installation_id)
      ] ++ Enum.map(in_flight, &Updates.review/1)

    socket
    |> assign(requests: requests, dismissals: dismissals)
    |> follow(topics)
    |> track_progress(in_flight)
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
        <.link navigate="/repos">Repositories</.link>
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

      <.live_component
        :if={@owner? and @repository.enabled and @repository.active}
        module={Tackle.HubWeb.ReviewRequestComponent}
        id="review-request"
        label="Review"
        repository={@repository}
        current_user={@current_user}
        signed_in_at={@signed_in_at}
      />

      <.empty :if={@requests == []}>
        <p :if={@repository.enabled}>
          No reviews yet. Comment <code>/tackle review</code> on a pull request to request one{if @owner? and @repository.active,
            do: ", or request one above",
            else: ""}.
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
              <.link class="strong" navigate={"/reviews/#{request.id}"}>
                #{request.pull_number} {request.title}
              </.link>
              <div class="muted small">
                <.sha sha={request.head_sha} /> · {trigger_label(request.trigger)}
                <span :if={request.requested_by}>by {request.requested_by}</span>
              </div>
            </td>
            <td>
              <.status_badge status={request.status} />
              <.verdict_badge :if={request.latest_run} verdict={request.latest_run.verdict} />
              <div :if={progress(@progress, request.id)} class="muted small status-progress">
                {ReviewProgress.describe(progress(@progress, request.id))}
              </div>
            </td>
            <td class="hide-small">
              <span :if={request.latest_run}>{request.latest_run.shown_findings}</span>
            </td>
            <td class="right muted small"><.time at={request.updated_at} /></td>
          </tr>
        </tbody>
      </table>
    </section>

    <section :if={@dismissals != []} class="card">
      <div class="card-header"><h2>Dismissed findings</h2></div>
      <p class="muted small">Reviews of this repository no longer report these.</p>
      <table class="list">
        <tbody>
          <tr :for={dismissal <- @dismissals}>
            <td>
              <span class="strong">{dismissal.title || dismissal.fingerprint}</span>
              <div class="muted small">
                by {dismissal.by}
                {if dismissal.source == :forge, do: "(resolved on GitHub)", else: "(here)"}
                <span :if={dismissal.pull_number}>· #{dismissal.pull_number}</span>
                · <.time at={dismissal.updated_at} />
              </div>
            </td>
            <td :if={@owner?} class="right">
              <button
                class="small secondary"
                phx-click="restore"
                phx-value-id={dismissal.id}
                phx-disable-with="Restoring…"
              >
                Restore
              </button>
            </td>
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
        <button type="submit" phx-disable-with="Saving…">Save</button>
      </.form>
    </section>

    <.live_component
      :if={@owner?}
      module={Tackle.HubWeb.GrantsComponent}
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
