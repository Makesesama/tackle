defmodule Tackle.HubWeb.SettingsLive do
  @moduledoc """
  `/settings`: the signed-in user's model providers and review defaults
  (docs/TACKLE_HUB_PLAN.md §7.2, §7.12), which the reviews of the
  installations they own use. Admins see only their own here too.

  API keys are write-only: they are stored encrypted and never shown again;
  the page only says whether a provider has its credentials. Codex
  providers connect on `/codex-login`. A provider is enabled when it first
  gets credentials (`Tackle.Hub.Models.Provider`).
  """

  use Phoenix.LiveView

  require Ash.Query

  import Tackle.HubWeb.Live
  import Tackle.HubWeb.UI

  alias Tackle.Hub.Models
  alias Tackle.Hub.Models.{Provider, ReviewDefaults}
  alias Tackle.Lib.Thinking

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
          socket
          |> put_flash(:info, "Added #{provider.name}. #{connect_text(provider)}")
          |> load()

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
        socket
        |> put_flash(
          :info,
          "Stored the API key of #{provider.name}; #{provider.name} is #{state(provider)}."
        )
        |> load()
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
      |> Ash.Query.load(:connected)
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
              <div class="muted small">
                {adapter_label(provider.adapter)} · {connection_label(provider)}
              </div>
            </td>
            <td>
              <form :if={provider.adapter == :openrouter} phx-submit="set_key" class="row">
                <input type="hidden" name="provider" value={provider.id} />
                <input
                  type="password"
                  name="api_key"
                  placeholder={if provider.connected, do: "New API key", else: "API key"}
                  autocomplete="off"
                  aria-label={"API key of #{provider.name}"}
                  required
                />
                <button
                  type="submit"
                  class={if provider.connected, do: "small secondary", else: "small"}
                  phx-disable-with="Storing…"
                >
                  {if provider.connected, do: "Replace key", else: "Store key"}
                </button>
              </form>
              <.link
                :if={provider.adapter == :codex}
                class={if provider.connected, do: "button small secondary", else: "button small"}
                navigate={"/codex-login?" <> URI.encode_query(%{provider: provider.name})}
              >
                {if provider.connected, do: "Reconnect ChatGPT", else: "Connect ChatGPT"}
              </.link>
            </td>
            <td class="right">
              <span :if={provider.enabled} class="badge status-posted">Enabled</span>
              <button
                class="small secondary"
                phx-click="toggle"
                phx-value-id={provider.id}
                phx-disable-with={if provider.enabled, do: "Disabling…", else: "Enabling…"}
                data-confirm={
                  provider.enabled &&
                    "Disable #{provider.name}? Reviews that use its models fail until it is enabled again."
                }
              >
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
        <button type="submit" phx-disable-with="Adding…">Add provider</button>
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
                empty_choice(stage),
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
        <button type="submit" phx-disable-with="Saving…">Save defaults</button>
      </.form>
    </section>
    """
  end

  defp empty_choice("scorer"), do: "Verifier's model"
  defp empty_choice(_stage), do: "Choose a model"

  defp state(%Provider{enabled: true}), do: "enabled"
  defp state(%Provider{enabled: false}), do: "disabled"

  defp enabled_text([]), do: "; enable a provider first"

  defp enabled_text(enabled),
    do: "with one of your enabled providers: " <> Enum.map_join(enabled, ", ", & &1.name)

  defp connect_text(%Provider{adapter: :openrouter}), do: "Store its API key to use it."
  defp connect_text(%Provider{adapter: :codex}), do: "Connect it to ChatGPT to use it."

  defp connection_label(%Provider{adapter: :openrouter, connected: true}), do: "API key stored"
  defp connection_label(%Provider{adapter: :openrouter}), do: "No API key yet"
  defp connection_label(%Provider{adapter: :codex, connected: true}), do: "Connected"
  defp connection_label(%Provider{adapter: :codex}), do: "Not connected yet"

  defp adapter_label(:openrouter), do: "OpenRouter"
  defp adapter_label(:codex), do: "OpenAI Codex"
end
