defmodule Tackle.Web.SetupController do
  @moduledoc """
  `/setup`: everything from a fresh deployment to a working app, in the
  browser (docs/TACKLE_WEB_PLAN.md §7.11; `Tackle.Web.Setup` has the rules).

    1. `POST /setup/unlock` - the setup token from the server log unlocks
       setup for this browser session;
    2. `POST /setup/github` - shows the form that registers the GitHub App
       from a manifest, with a one-time `state` in the session;
    3. `GET /setup/github/callback` - GitHub's redirect: exchanges the code,
       stores the App and its secrets, and sends the browser to install it;
    4. `GET /setup/github/installed` - GitHub's redirect after installing:
       confirms the installation with GitHub and records it;
    5. signing in from this session makes the user the first admin.

  After setup, any signed-in user uses `GET /setup/github/install` to install
  the App on their own account (docs/TACKLE_WEB_PLAN.md §7.12), and GitHub's
  redirect back records the installation for them, as for setup. The owner
  comes from GitHub (the `installation` webhook, or the user account the App
  is on), never from this redirect. Admins use `POST /setup/sync` (sync
  installations and repositories from GitHub). Each needs an unlocked setup
  session, or a signed-in user (admin for the sync).
  """

  use Phoenix.Controller, formats: [:html]

  require Logger

  alias Tackle.Web.Accounts.User
  alias Tackle.Web.{Endpoint, Forge, ForgeSync, Setup, SetupHTML, SignIn}
  alias Tackle.Web.Forges.ForgeApp

  @forge :github

  def show(conn, _params) do
    status = Setup.status()

    if Setup.complete?(status) do
      redirect(conn, to: "/")
    else
      render_page(conn, :show, status: status, unlocked?: unlocked?(conn), error: nil)
    end
  end

  def unlock(conn, params) do
    if Setup.valid_token?(params["token"]) do
      conn
      |> put_session(:setup_unlocked_at, System.os_time(:second))
      |> redirect(to: "/setup")
    else
      conn
      |> put_status(403)
      |> render_page(:show,
        status: Setup.status(),
        unlocked?: false,
        error: "That is not the current setup token, or setup is already complete."
      )
    end
  end

  def register(conn, params) do
    base_url = Endpoint.url()
    state = SignIn.new_state()

    opts = [
      owner: blank_to_nil(params["owner"]),
      name: blank_to_nil(params["name"]) || default_name(),
      webhook?: webhook?(base_url)
    ]

    with :ok <- require_unlocked(conn),
         :ok <- require_no_app(),
         {:ok, form} <- Forge.module(@forge).registration_form(base_url, state, opts) do
      conn
      |> put_session(:setup_state, state)
      |> render_page(:register, form: form, webhook?: opts[:webhook?])
    else
      {:error, reason} -> failed(conn, reason)
    end
  end

  def registered(conn, params) do
    expected = get_session(conn, :setup_state)
    conn = delete_session(conn, :setup_state)

    with :ok <- require_unlocked(conn),
         :ok <- check_state(expected, params["state"]),
         {:ok, code} <- code(params),
         :ok <- require_no_app(),
         {:ok, registration} <- complete_registration(code),
         :ok <- store(registration) do
      redirect(conn, external: registration.install_url)
    else
      {:error, reason} -> failed(conn, reason)
    end
  end

  def install(conn, _params) do
    with :ok <- require_setup_or_user(conn),
         {:ok, forge_app} <- forge_app(),
         {:ok, url} <- install_url(forge_app) do
      redirect(conn, external: url)
    else
      {:error, reason} -> failed(conn, reason)
    end
  end

  # `installation_id` comes from the browser, so it is only a hint: the
  # sync asks GitHub whether it is this App's installation.
  def installed(conn, params) do
    with :ok <- require_setup_or_user(conn),
         {:ok, id} <- installation_id(params),
         {:ok, _summary} <- sync(fn -> ForgeSync.sync_installation(@forge, id) end) do
      redirect(conn, to: next_page())
    else
      {:error, :forbidden} -> render_page(conn, :installed, [])
      {:error, reason} -> failed(conn, reason)
    end
  end

  def sync(conn, _params) do
    with :ok <- require_setup_or_admin(conn),
         {:ok, summary} <- sync(fn -> ForgeSync.sync_all(@forge) end) do
      render_page(conn, :synced, summary: summary, next: next_page())
    else
      {:error, reason} -> failed(conn, reason)
    end
  end

  defp unlocked?(conn), do: Setup.unlocked?(get_session(conn, :setup_unlocked_at))

  defp require_unlocked(conn),
    do: if(unlocked?(conn), do: :ok, else: {:error, :forbidden})

  defp require_setup_or_user(conn) do
    case conn.assigns[:current_user] do
      %User{} -> :ok
      _other -> require_unlocked(conn)
    end
  end

  defp require_setup_or_admin(conn) do
    case conn.assigns[:current_user] do
      %User{admin: true} -> :ok
      _other -> require_unlocked(conn)
    end
  end

  defp require_no_app do
    case ForgeApp.get(@forge) do
      {:ok, nil} -> :ok
      {:ok, %ForgeApp{}} -> {:error, :app_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp forge_app do
    case ForgeApp.get(@forge) do
      {:ok, %ForgeApp{} = forge_app} -> {:ok, forge_app}
      {:ok, nil} -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_state(expected, state) when is_binary(expected) and is_binary(state) do
    if Plug.Crypto.secure_compare(expected, state), do: :ok, else: {:error, :invalid_state}
  end

  defp check_state(_expected, _state), do: {:error, :invalid_state}

  defp code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}
  defp code(_params), do: {:error, :invalid_state}

  defp installation_id(%{"installation_id" => id}) when is_binary(id) do
    if Regex.match?(~r/\A[1-9][0-9]{0,19}\z/, id), do: {:ok, id}, else: {:error, :not_found}
  end

  defp installation_id(_params), do: {:error, :not_found}

  defp complete_registration(code) do
    case Forge.module(@forge).complete_registration(code) do
      {:ok, registration} ->
        {:ok, registration}

      {:error, reason} ->
        Logger.warning("setup: GitHub did not complete the registration: #{describe(reason)}")
        {:error, :registration_failed}
    end
  end

  # An App registered without a webhook gets no secret from GitHub; a random
  # one keeps the webhook endpoint closed until a webhook is configured.
  defp store(registration) do
    params = %{
      app_id: registration.app_id,
      client_id: registration.client_id,
      client_secret: registration.client_secret,
      private_key: registration.private_key,
      webhook_secret: registration.webhook_secret || SignIn.new_state()
    }

    case ForgeApp.register(@forge, params) do
      {:ok, _forge_app} ->
        :ok

      {:error, error} ->
        # Another setup may have stored an App between the check and now.
        # Otherwise only the error's kind is logged: its fields hold secrets.
        with :ok <- require_no_app() do
          Logger.error("setup: could not store the new GitHub App: #{inspect(error.__struct__)}")
          {:error, :store_failed}
        end
    end
  end

  defp install_url(forge_app) do
    case Forge.module(@forge).install_url(forge_app) do
      {:ok, url} ->
        {:ok, url}

      {:error, reason} ->
        Logger.warning("setup: could not read the App's install URL: #{describe(reason)}")
        {:error, :forge_unavailable}
    end
  end

  defp sync(fun) do
    case fun.() do
      {:ok, summary} ->
        {:ok, summary}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :not_configured} ->
        {:error, :not_configured}

      {:error, reason} ->
        Logger.warning("setup: sync from GitHub failed: #{describe(reason)}")
        {:error, :forge_unavailable}
    end
  end

  defp next_page, do: if(Setup.complete?(Setup.status()), do: "/", else: "/setup")

  # GitHub cannot deliver webhooks to a loopback address (development).
  @doc false
  @spec webhook?(String.t()) :: boolean()
  def webhook?(base_url) do
    host = URI.parse(base_url).host || ""

    host not in ["localhost", "127.0.0.1", "::1", "[::1]"] and
      not String.ends_with?(host, ".localhost")
  end

  # GitHub App names are at most 34 characters and unique on GitHub; the
  # form and GitHub's page both let the operator change it.
  defp default_name, do: String.slice("tackle-" <> (URI.parse(Endpoint.url()).host || ""), 0, 34)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp describe({:github, status, _detail}), do: "GitHub #{inspect(status)}"
  defp describe(reason) when is_atom(reason), do: inspect(reason)
  defp describe(_reason), do: "unexpected error"

  defp failed(conn, reason) do
    {status, message} = SetupHTML.failure(reason)

    conn
    |> put_status(status)
    |> render_page(:failed, message: message)
  end

  defp render_page(conn, template, assigns) do
    conn
    |> put_view(SetupHTML)
    |> render(template, Keyword.put(assigns, :default_name, default_name()))
  end
end
