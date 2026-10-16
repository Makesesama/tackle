defmodule Tackle.Web.SignIn do
  @moduledoc """
  Sign-in through the forge app's OAuth client (docs/TACKLE_WEB_PLAN.md
  §7.6), as plain functions for `Tackle.Web.AuthController`:

    1. `authorize_url/3` builds the forge's sign-in URL for a random,
       one-time `state` that the caller keeps in the session;
    2. `complete/3` exchanges the code from the forge's redirect for the
       forge account, checks that it belongs to an account the app is
       installed on (an organisation member, or the user account itself),
       and records the `Tackle.Web.Accounts.User`.

  Nobody can sign in before the app is installed somewhere. The forge's
  access token for the user is only used to read the account; nothing of it
  is kept.
  """

  require Ash.Query
  require Logger

  alias Tackle.Web.Accounts.User
  alias Tackle.Web.Forge
  alias Tackle.Web.Forges.{ForgeApp, Installation}

  @typedoc "Why a sign-in failed, as shown to the person signing in."
  @type error ::
          :sign_in_not_configured | :forge_rejected | :not_a_member | :membership_unverified

  @doc "A random value for the OAuth `state` parameter."
  @spec new_state() :: String.t()
  def new_state, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc "The forge's sign-in URL, or why there is none."
  @spec authorize_url(atom(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :sign_in_not_configured}
  def authorize_url(forge, state, redirect_uri) do
    with {:ok, forge_app} <- forge_app(forge) do
      Forge.module(forge).authorize_url(forge_app, state, redirect_uri)
    end
  end

  @doc """
  Finishes a sign-in with the code from the forge's redirect. Upstream
  errors are logged without their details and reported as one of `t:error/0`.
  """
  @spec complete(atom(), String.t(), String.t()) :: {:ok, User.t()} | {:error, error()}
  def complete(forge, code, redirect_uri) do
    module = Forge.module(forge)

    with {:ok, forge_app} <- forge_app(forge),
         {:ok, forge_user} <- forge_user(module, forge_app, code, redirect_uri),
         :ok <- check_member(module, forge, forge_app, forge_user) do
      record_user(forge, forge_user)
    end
  end

  defp forge_app(forge) do
    case ForgeApp.get(forge) do
      {:ok, %ForgeApp{} = forge_app} -> {:ok, forge_app}
      {:ok, nil} -> {:error, :sign_in_not_configured}
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp forge_user(module, forge_app, code, redirect_uri) do
    case module.sign_in(forge_app, code, redirect_uri) do
      {:ok, forge_user} ->
        {:ok, forge_user}

      {:error, :sign_in_not_configured} ->
        {:error, :sign_in_not_configured}

      {:error, reason} ->
        Logger.warning("sign-in: the forge rejected the code: #{describe(reason)}")
        {:error, :forge_rejected}
    end
  end

  # Installations are tried in turn; one that confirms membership is enough.
  # A failed check only matters when no other installation confirms it.
  defp check_member(module, forge, forge_app, forge_user) do
    Installation
    |> Ash.Query.filter(forge == ^forge and status == :active)
    |> Ash.Query.sort(:inserted_at)
    |> Ash.read!()
    |> Enum.reduce_while(:not_a_member, fn installation, acc ->
      case module.member?(forge_app, installation, forge_user) do
        {:ok, true} ->
          {:halt, :ok}

        {:ok, false} ->
          {:cont, acc}

        {:error, reason} ->
          Logger.warning(
            "sign-in: could not check membership in installation " <>
              "#{installation.external_id}: #{describe(reason)}"
          )

          {:cont, :membership_unverified}
      end
    end)
    |> case do
      :ok -> :ok
      reason -> {:error, reason}
    end
  end

  defp record_user(forge, forge_user) do
    case User.sign_in(%{
           forge: forge,
           external_id: forge_user.external_id,
           login: forge_user.login,
           name: forge_user.name
         }) do
      {:ok, user} -> {:ok, user}
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  # Only the shape of an error: forge messages are not needed in the log.
  defp describe({:github, status, _detail}), do: "GitHub #{inspect(status)}"
  defp describe(reason) when is_atom(reason), do: inspect(reason)
  defp describe(_reason), do: "unexpected error"
end
