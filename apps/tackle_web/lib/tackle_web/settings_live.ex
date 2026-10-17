defmodule Tackle.Web.SettingsLive do
  @moduledoc """
  `/settings`: the signed-in user's model providers and review defaults
  (docs/TACKLE_WEB_PLAN.md §7.2, §7.12), which the reviews of the
  installations they own use. Admins see only their own here too.

  API keys are write-only: they are stored encrypted and never shown again.
  Codex providers connect on `/codex-login`.
  """

  use Phoenix.LiveView

  require Ash.Query

  import Tackle.Web.Live
  import Tackle.Web.UI

  alias Tackle.Lib.Thinking
  alias Tackle.Web.Models
  alias Tackle.Web.Models.{Provider, ReviewDefaults}

  @stages ~w(detector verifier scorer)

  # Form fields per stage: AshPhoenix names fields that are not inputs of
  # the action by atom.
  @fields %{
    "detector" => {:detector_model, :detector_thinking},
    "verifier" => {:verifier_model, :verifier_thinking},
    "scorer" => {:scorer_model, :scorer_thinking}
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Models") |> load()}
  end

  @impl true
  def handle_event("register", %{"form" => params}, socket) do
    with_user(socket, fn socket ->
      case AshPhoenix.Form.submit(socket.assigns.register_form, params: params) do
        {:ok, provider} ->
          socket |> put_flash(:info, "Added #{provider.name}. Enable it to use it.") |> load()

        {:error, form} ->
          assign(socket, :register_form, to_form(form))
      end
    end)
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    with_user(socket, fn socket ->
      user = socket.assigns.current_user

      with %Provider{} = provider <- own_provider(id, user),
           {:ok, provider} <-
             Provider.configure(provider, %{enabled: !provider.enabled}, actor: user) do
        socket |> put_flash(:info, "#{provider.name} is #{state(provider)}.") |> load()
      else
        _error -> put_flash(socket, :error, "That provider could not be changed.")
      end
    end)
  end

  def handle_event("set_key", %{"provider" => id, "api_key" => key}, socket) do
    with_user(socket, fn socket ->
      user = socket.assigns.current_user

      with %Provider{} = provider <- own_provider(id, user),
           {:ok, provider} <- Provider.set_credentials(provider, key, actor: user) do
        put_flash(socket, :info, "Stored the API key of #{provider.name}.")
      else
        _error -> put_flash(socket, :error, "The API key could not be stored.")
      end
    end)
  end

  def handle_event("save_defaults", %{"form" => params}, socket) do
    with_user(socket, fn socket ->
      case AshPhoenix.Form.submit(socket.assigns.defaults_form, params: params) do
        {:ok, _defaults} -> socket |> put_flash(:info, "Review defaults saved.") |> load()
        {:error, form} -> assign(socket, :defaults_form, to_form(form))
      end
    end)
  end

  defp own_provider(id, user) do
    case get(Provider, id, user) do
      %Provider{owner_id: owner_id} = provider when owner_id == user.id -> provider
      _other -> nil
    end
  end

  defp load(socket) do
    user = socket.assigns.current_user

    providers =
      Provider
      |> Ash.Query.filter(owner_id == ^user.id)
      |> Ash.Query.sort(:name)
      |> Ash.read!(actor: user)

    {:ok, defaults} = ReviewDefaults.get(user.id, actor: user)
    {:ok, model_options} = Models.model_options(user.id)

    register_form =
      Provider
      |> AshPhoenix.Form.for_create(:register, actor: user, params: %{"adapter" => "openrouter"})
      |> to_form()

    assign(socket,
      providers: providers,
      model_options: model_options,
      register_form: register_form,
      defaults_form: defaults_form(defaults, user)
    )
  end

  # One model and thinking input per stage, sent as the `models` and
  # `thinking` maps; empty inputs are left out.
  defp defaults_form(defaults, user) do
    initial =
      for stage <- @stages, into: %{} do
        {stage <> "_model", get_in(defaults || %{}, [Access.key(:models, %{}), stage]) || ""}
      end
      |> Map.merge(
        for stage <- @stages, into: %{} do
          {stage <> "_thinking",
           get_in(defaults || %{}, [Access.key(:thinking, %{}), stage]) || ""}
        end
      )

    ReviewDefaults
    |> AshPhoenix.Form.for_create(:configure,
      actor: user,
      params: initial,
      # The stage inputs stay, as AshPhoenix may transform params again.
      transform_params: fn _form, params, _action ->
        Map.merge(params, %{
          "models" => stage_map(params, "_model"),
          "thinking" => stage_map(params, "_thinking")
        })
      end
    )
    |> to_form()
  end

  defp stage_map(params, suffix) do
    for stage <- @stages,
        value = String.trim(params[stage <> suffix] || ""),
        value != "",
        into: %{},
        do: {stage, value}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        stages: @stages,
        fields: @fields,
        thinking_options: [{"Model default", ""} | Enum.map(Thinking.levels(), &{&1, &1})],
        enabled: Enum.filter(assigns.providers, & &1.enabled)
      )

    ~H"""
    <.page_header title="Models">
      <:subtitle>
        The model providers and defaults that the reviews of the installations you own use.
      </:subtitle>
    </.page_header>

    <section class="card">
      <div class="card-header"><h2>Providers</h2></div>

      <p :if={@providers == []} class="muted">
        You have no providers yet. Add an OpenRouter provider and its API key, or an OpenAI Codex
        provider that you connect with your ChatGPT subscription.
      </p>

      <table :if={@providers != []} class="list">
        <tbody>
          <tr :for={provider <- @providers}>
            <td>
              <span class="strong">{provider.name}</span>
              <div class="muted small">{adapter_label(provider.adapter)}</div>
            </td>
            <td>
              <form :if={provider.adapter == :openrouter} phx-submit="set_key" class="row">
                <input type="hidden" name="provider" value={provider.id} />
                <input
                  type="password"
                  name="api_key"
                  placeholder="New API key"
                  autocomplete="off"
                  aria-label={"API key of #{provider.name}"}
                  required
                />
                <button type="submit" class="small secondary">Store key</button>
              </form>
              <a :if={provider.adapter == :codex} class="button small secondary" href="/codex-login">
                Connect ChatGPT
              </a>
            </td>
            <td class="right">
              <span :if={provider.enabled} class="badge status-posted">Enabled</span>
              <button class="small secondary" phx-click="toggle" phx-value-id={provider.id}>
                {if provider.enabled, do: "Disable", else: "Enable"}
              </button>
            </td>
          </tr>
        </tbody>
      </table>

      <.form for={@register_form} phx-submit="register" class="inline-form">
        <.input
          field={@register_form[:name]}
          label="Name"
          placeholder="openrouter"
          help="Model references start with it, as in openrouter/vendor/model."
          required
        />
        <.input
          field={@register_form[:adapter]}
          type="select"
          label="Kind"
          options={[{"OpenRouter (API key)", "openrouter"}, {"OpenAI Codex (ChatGPT)", "codex"}]}
        />
        <button type="submit">Add provider</button>
      </.form>
    </section>

    <section class="card">
      <div class="card-header"><h2>Review defaults</h2></div>
      <p class="muted">
        Reviews need a detector and a verifier model {enabled_text(@enabled)}. A
        repository's settings can choose others. The scorer uses the verifier's model
        when it is empty.
      </p>
      <.form for={@defaults_form} phx-submit="save_defaults">
        <p :for={error <- @defaults_form[:models].errors ++ @defaults_form[:thinking].errors} class="error">
          {error_message(error)}
        </p>
        <div :for={stage <- @stages} class="row stage">
          <.input
            field={@defaults_form[elem(@fields[stage], 0)]}
            type="select"
            label={String.capitalize(stage) <> " model"}
            options={
              model_select_options(
                @model_options,
                stage,
                @defaults_form[elem(@fields[stage], 0)].value
              )
            }
          />
          <.input
            field={@defaults_form[elem(@fields[stage], 1)]}
            type="select"
            label="Thinking"
            options={@thinking_options}
          />
        </div>
        <button type="submit">Save defaults</button>
      </.form>
    </section>
    """
  end

  # The enabled providers' models, grouped by provider, after an empty
  # choice. A chosen reference that is no longer offered (its provider was
  # disabled, or the model removed) stays selectable, marked, so the form
  # shows and keeps it instead of switching to another model unnoticed.
  defp model_select_options(groups, stage, value) do
    value = if is_binary(value), do: String.trim(value), else: ""

    offered? =
      value == "" or Enum.any?(groups, fn {_id, models} -> List.keymember?(models, value, 1) end)

    unavailable = if offered?, do: [], else: [{value <> " (unavailable)", value}]

    [{empty_choice(stage), ""} | unavailable] ++ groups
  end

  defp empty_choice("scorer"), do: "Verifier's model"
  defp empty_choice(_stage), do: "Choose a model"

  defp state(%Provider{enabled: true}), do: "enabled"
  defp state(%Provider{enabled: false}), do: "disabled"

  defp enabled_text([]), do: "; enable a provider first"

  defp enabled_text(enabled),
    do: "with one of your enabled providers: " <> Enum.map_join(enabled, ", ", & &1.name)

  defp adapter_label(:openrouter), do: "OpenRouter"
  defp adapter_label(:codex), do: "OpenAI Codex"
end
