defmodule Tackle.HubWeb.RepositoryLive do
  @moduledoc """
  `/repos/:id`: a repository's reviews, newest first, and the findings
  dismissed in it. Its installation's owner also requests reviews
  (`Tackle.HubWeb.ReviewRequestComponent`), restores dismissed findings,
  changes its review settings, and decides who else may see it
  (`Tackle.HubWeb.GrantsComponent`).

  The owner's settings choose each review stage's model and thinking
  level from their enabled providers, as on the Models page, with their
  review defaults for the stages left empty; the other review settings
  (step limits and default rules) are edited as JSON, under "Advanced".

  The page is live (`Tackle.HubWeb.Live`): it follows the repository, its
  reviews and dismissals, its installation, and the owner's providers and
  review defaults, and says what a review in flight is doing. An update
  leaves a settings form being edited as it is.
  """

  use Phoenix.LiveView

  require Ash.Query

  import Tackle.HubWeb.Live
  import Tackle.HubWeb.UI

  alias Phoenix.LiveView.JS
  alias Tackle.Hub.{Forge, Models, ReviewProgress, Updates}
  alias Tackle.Hub.Forges.{Installation, Repository}
  alias Tackle.Hub.Models.ReviewDefaults
  alias Tackle.Hub.Reviews.{Dismissal, ReviewRequest}
  alias Tackle.HubWeb.GrantsComponent
  alias Tackle.Lib.Thinking

  @requests 50

  @stages ~w(detector verifier scorer)

  # Form fields per stage: AshPhoenix names fields that are not inputs of
  # the action by atom.
  @fields %{
    "detector" => {:detector_model, :detector_thinking},
    "verifier" => {:verifier_model, :verifier_thinking},
    "scorer" => {:scorer_model, :scorer_thinking}
  }

  # The settings the stage inputs edit; the advanced JSON has the others.
  @stage_settings ~w(models thinking)

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
         |> load_models()
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
      case check_advanced(params) do
        :ok ->
          save(socket, params)

        # Not submitted: the form keeps what was entered, and says why.
        {:error, message} ->
          assign(socket,
            form: AshPhoenix.Form.validate(socket.assigns.form, params),
            settings_error: message
          )
      end
    end)
  end

  defp save(socket, params) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, repository} ->
        socket
        |> put_flash(:info, "Settings saved.")
        |> assign_repository(%{repository | installation: socket.assigns.repository.installation})

      {:error, form} ->
        assign(socket, form: to_form(form), settings_error: nil)
    end
  end

  defp check_advanced(%{"advanced" => text}) when is_binary(text) do
    case advanced_settings(text) do
      {:ok, _settings} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp check_advanced(_params), do: :ok

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

        socket |> load_models() |> load_requests()
    end
  end

  # The owner's settings form, made again only after saving or when the
  # page's user became or stopped being the owner.
  defp assign_repository(socket, repository) do
    user = socket.assigns.current_user
    owner? = Installation.owned_by?(repository.installation, user)

    socket
    |> assign(repository: repository, owner?: owner?)
    |> assign(form: if(owner?, do: settings_form(repository, user)), settings_error: nil)
  end

  # What the owner's stage inputs offer: the models of their enabled
  # providers, and their review defaults, which empty inputs use.
  defp load_models(%{assigns: %{owner?: true, current_user: user}} = socket) do
    {:ok, model_options} = Models.model_options(user.id)
    {:ok, defaults} = ReviewDefaults.get(user.id, actor: user)
    assign(socket, model_options: model_options, defaults: defaults)
  end

  defp load_models(socket), do: assign(socket, model_options: [], defaults: nil)

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

    # The owner's providers and defaults, for the settings' stage inputs.
    owner_topics =
      if socket.assigns.owner?, do: [Updates.user(socket.assigns.current_user.id)], else: []

    topics =
      [
        Updates.repository(repository.id),
        Updates.dismissals(repository.id),
        Updates.installation(repository.installation_id)
      ] ++ owner_topics ++ Enum.map(in_flight, &Updates.review/1)

    socket
    |> assign(requests: requests, dismissals: dismissals)
    |> follow(topics)
    |> track_progress(in_flight)
  end

  # `settings` is edited as one model and thinking input per stage and
  # the rest as JSON text (`advanced`), which are put together again on
  # submit; the inputs stay, as AshPhoenix may transform params again. A
  # budget left empty is no limit.
  defp settings_form(repository, user) do
    settings = repository.settings

    params =
      for stage <- @stages,
          {key, suffix} <- [{"models", "_model"}, {"thinking", "_thinking"}],
          into: %{"advanced" => advanced_text(settings)} do
        {stage <> suffix, settings |> Map.get(key, %{}) |> Map.get(stage, "")}
      end

    repository
    |> AshPhoenix.Form.for_update(:configure,
      actor: user,
      params: params,
      transform_params: fn _form, params, _action ->
        params
        |> put_settings()
        |> update_present("daily_token_budget", &blank_to_nil/1)
      end
    )
    |> to_form()
  end

  defp put_settings(%{"advanced" => text} = params) when is_binary(text) do
    case advanced_settings(text) do
      {:ok, advanced} ->
        settings =
          advanced
          |> put_stages("models", stage_map(params, "_model"))
          |> put_stages("thinking", stage_map(params, "_thinking"))

        Map.put(params, "settings", settings)

      # Saving checks it first; left as text, the map type refuses it.
      {:error, _message} ->
        Map.put(params, "settings", text)
    end
  end

  defp put_settings(params), do: params

  defp put_stages(settings, _key, stages) when stages == %{}, do: settings
  defp put_stages(settings, key, stages), do: Map.put(settings, key, stages)

  defp stage_map(params, suffix) do
    for stage <- @stages,
        value = params[stage <> suffix],
        is_binary(value),
        value = String.trim(value),
        value != "",
        into: %{},
        do: {stage, value}
  end

  # The settings other than models and thinking, as a JSON object.
  defp advanced_settings(text) do
    case String.trim(text) do
      "" -> {:ok, %{}}
      trimmed -> trimmed |> JSON.decode() |> advanced_object()
    end
  end

  defp advanced_object({:ok, %{} = settings}) do
    if Enum.any?(@stage_settings, &Map.has_key?(settings, &1)),
      do: {:error, "Choose models and thinking levels above, not in the advanced settings."},
      else: {:ok, settings}
  end

  defp advanced_object({:ok, _other}),
    do: {:error, "The advanced settings must be a JSON object."}

  defp advanced_object({:error, _reason}),
    do: {:error, "The advanced settings are not valid JSON."}

  # Indented, to be edited; empty when there are none.
  defp advanced_text(settings) do
    case Map.drop(settings, @stage_settings) do
      empty when empty == %{} -> ""
      advanced -> advanced |> :json.format(&json_value/3) |> IO.iodata_to_binary()
    end
  end

  # `:json` writes Elixir's nil as the string "nil".
  defp json_value(nil, _encode, _state), do: "null"
  defp json_value(value, encode, state), do: :json.format_value(value, encode, state)

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
    assigns =
      assign(assigns,
        stages: @stages,
        fields: @fields,
        thinking_options: Enum.map(Thinking.levels(), &{&1, &1})
      )

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

        <h3>Models</h3>
        <p class="help">
          The models of your enabled providers. Stages left on your default use your
          <.link navigate="/settings">review defaults</.link>.
        </p>
        <p :if={@settings_error} class="error">{@settings_error}</p>
        <p :for={error <- @form[:settings].errors} class="error">{error_message(error)}</p>
        <div :for={stage <- @stages} class="row stage">
          <.input
            field={@form[elem(@fields[stage], 0)]}
            type="select"
            label={String.capitalize(stage) <> " model"}
            options={
              model_select_options(
                @model_options,
                default_model(@defaults, stage),
                @form[elem(@fields[stage], 0)].value
              )
            }
          />
          <.input
            field={@form[elem(@fields[stage], 1)]}
            type="select"
            label="Thinking"
            options={[{default_thinking(@defaults, stage), ""} | @thinking_options]}
          />
        </div>

        <details
          class="advanced"
          id="advanced-settings"
          open={advanced_open?(@form[:advanced].value)}
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary>Advanced settings (JSON)</summary>
          <.input
            field={@form[:advanced]}
            type="textarea"
            rows="6"
            label="Step limits and default rules"
            placeholder={~s({"max_steps": {"verifier": 6}, "default_rules": ["injection"]})}
            help={"A JSON object with max_steps per stage (detector, verifier) and " <>
              "default_rules, a list of rule ids. Empty for none."}
          />
        </details>

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

  # The empty choices say what the owner's review defaults use instead.
  defp default_model(defaults, stage) do
    case defaults && Map.get(defaults.models, stage) do
      nil when stage == "scorer" -> "Your default (the verifier's model)"
      nil -> "Your default (none chosen)"
      model -> "Your default (#{model})"
    end
  end

  defp default_thinking(defaults, stage) do
    case defaults && Map.get(defaults.thinking, stage) do
      nil -> "Your default (the model's)"
      level -> "Your default (#{level})"
    end
  end

  defp advanced_open?(text), do: is_binary(text) and String.trim(text) != ""

  defp trigger_label(:command), do: "requested"
  defp trigger_label(:opened), do: "opened"
  defp trigger_label(:pushed), do: "pushed"
end
