defmodule Tackle.Web.AuthController do
  @moduledoc """
  Sign-in through the forge app's OAuth client, and sign-out
  (docs/TACKLE_WEB_PLAN.md §7.6):

    * `GET /auth/github` stores a random `state` in the session and sends
      the browser to GitHub;
    * `GET /auth/github/callback` checks `state` (once: it is dropped
      whatever happens), finishes the sign-in with `Tackle.Web.SignIn`, and
      stores the user in a renewed session (`Tackle.Web.Auth.put_user/2`);
    * `POST /sign-out` drops the session.

  Failures are shown as a fixed message per kind; upstream details are not.
  """

  use Phoenix.Controller, formats: [:html]

  alias Tackle.Web.{Auth, AuthHTML, Endpoint, SignIn}

  @forges %{"github" => :github}

  def request(conn, %{"forge" => name}) do
    with {:ok, forge} <- forge(name),
         state = SignIn.new_state(),
         {:ok, url} <- SignIn.authorize_url(forge, state, redirect_uri(name)) do
      conn
      |> put_session(:oauth_state, %{"forge" => name, "state" => state})
      |> redirect(external: url)
    else
      {:error, reason} -> failed(conn, reason)
    end
  end

  def callback(conn, %{"forge" => name} = params) do
    expected = get_session(conn, :oauth_state)
    conn = delete_session(conn, :oauth_state)

    with {:ok, forge} <- forge(name),
         :ok <- check_state(expected, name, params["state"]),
         {:ok, code} <- code(params),
         {:ok, user} <- SignIn.complete(forge, code, redirect_uri(name)) do
      conn
      |> Auth.put_user(user)
      |> redirect(to: "/")
    else
      {:error, reason} -> failed(conn, reason)
    end
  end

  def sign_out(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/")
  end

  defp forge(name) do
    case Map.fetch(@forges, name) do
      {:ok, forge} -> {:ok, forge}
      :error -> {:error, :unknown_forge}
    end
  end

  defp check_state(%{"forge" => name, "state" => expected}, name, state)
       when is_binary(expected) and is_binary(state) do
    if Plug.Crypto.secure_compare(expected, state), do: :ok, else: {:error, :invalid_state}
  end

  defp check_state(_expected, _name, _state), do: {:error, :invalid_state}

  defp code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}
  defp code(%{"error" => _error}), do: {:error, :cancelled}
  defp code(_params), do: {:error, :invalid_state}

  # The forge must have exactly this URL among the app's callback URLs.
  defp redirect_uri(name), do: Endpoint.url() <> "/auth/#{name}/callback"

  defp failed(conn, reason) do
    {status, message} = AuthHTML.failure(reason)

    conn
    |> put_status(status)
    |> put_view(AuthHTML)
    |> render(:failed, message: message)
  end
end
