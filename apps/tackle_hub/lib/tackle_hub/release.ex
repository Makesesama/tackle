defmodule Tackle.Hub.Release do
  @moduledoc """
  Tasks for a release, run with `bin/tackle_hub eval`, which has no Mix:

      bin/tackle_hub eval "Tackle.Hub.Release.migrate()"
      bin/tackle_hub eval "Tackle.Hub.Release.configure_github_app()"
      bin/tackle_hub eval 'Tackle.Hub.Release.set_admin("octocat")'

  They run in their own VM, beside a running service, and start only what
  they need (the repository and the vault), not the web server.
  """

  require Ash.Query

  alias Tackle.Hub.Accounts.User
  alias Tackle.Hub.Forges.ForgeApp
  alias Tackle.Hub.{Repo, Vault}

  @app :tackle_hub

  @doc "Runs all pending migrations of every repository."
  @spec migrate() :: :ok
  def migrate do
    :ok = Application.ensure_loaded(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _result, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Stores the GitHub App's settings and secrets, replacing earlier ones.
  For recovery or scripted deployments: `/setup` registers the App from the
  browser (`Tackle.HubWeb.SetupController`), which is the normal way. Reads:

    * `TACKLE_HUB_GITHUB_APP_ID` - the App ID;
    * `TACKLE_HUB_GITHUB_CLIENT_ID` - the App's client id (optional, but
      needed for sign-in);
    * `TACKLE_HUB_GITHUB_PRIVATE_KEY_FILE` - a file with the App's private
      key (PEM);
    * `TACKLE_HUB_GITHUB_WEBHOOK_SECRET_FILE` - a file with the webhook
      secret;
    * `TACKLE_HUB_GITHUB_CLIENT_SECRET_FILE` - a file with the client secret
      (optional, but needed for sign-in).

  Secrets are read from files so they stay out of process listings and
  shell history; they are stored encrypted with the vault's current key.
  """
  @spec configure_github_app() :: :ok
  def configure_github_app do
    :ok = Application.ensure_loaded(@app)
    params = github_app_params(System.get_env()) |> raise_on_error()

    {:ok, :ok, _apps} =
      Ecto.Migrator.with_repo(Repo, fn _repo ->
        {:ok, _apps} = Application.ensure_all_started(:ash)
        {:ok, _vault} = Vault.start_link()
        {:ok, _forge_app} = ForgeApp.configure(:github, params)
        :ok
      end)

    IO.puts("Stored the GitHub App #{params.app_id}.")
  end

  @doc """
  Grants (or, with `false`, revokes) admin rights to the GitHub user with
  `login` (case-insensitive), who must have signed in once. For recovery:
  admins normally do this in the admin interface, and the first admin comes
  from setup (`Tackle.Hub.Setup`). The last admin cannot be revoked. Takes
  effect on the user's next request.
  """
  @spec set_admin(String.t(), boolean()) :: :ok
  def set_admin(login, admin? \\ true) when is_binary(login) and is_boolean(admin?) do
    :ok = Application.ensure_loaded(@app)

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(Repo, fn _repo ->
        {:ok, _apps} = Application.ensure_all_started(:ash)
        update_admin(:github, login, admin?)
      end)

    message = raise_on_error(result)
    IO.puts(message)
  end

  @doc false
  # Finds the user by login and sets the flag; separate for tests.
  @spec update_admin(atom(), String.t(), boolean()) :: {:ok, String.t()} | {:error, String.t()}
  def update_admin(forge, login, admin?) do
    lower = String.downcase(login)

    User
    |> Ash.Query.filter(forge == ^forge and string_downcase(login) == ^lower)
    |> Ash.read!()
    |> case do
      [user] ->
        update_user_admin(user, admin?)

      [] ->
        {:error, "no user #{inspect(login)} has signed in yet"}

      users ->
        {:error,
         "#{inspect(login)} matches several users (#{Enum.map_join(users, ", ", & &1.external_id)}); " <>
           "set the admin flag by id in a console"}
    end
  end

  defp update_user_admin(user, admin?) do
    case User.set_admin(user, admin?) do
      {:ok, user} ->
        verb = if admin?, do: "is now", else: "is no longer"
        {:ok, "#{user.login} #{verb} an admin."}

      {:error, error} ->
        {:error, Exception.message(error)}
    end
  end

  @doc false
  # Builds `ForgeApp.configure/2` parameters from an environment map.
  @spec github_app_params(%{String.t() => String.t()}) :: {:ok, map()} | {:error, String.t()}
  def github_app_params(env) do
    with {:ok, app_id} <- required(env, "TACKLE_HUB_GITHUB_APP_ID"),
         {:ok, private_key} <- secret_file(env, "TACKLE_HUB_GITHUB_PRIVATE_KEY_FILE", true),
         {:ok, webhook_secret} <- secret_file(env, "TACKLE_HUB_GITHUB_WEBHOOK_SECRET_FILE", true),
         {:ok, client_secret} <- secret_file(env, "TACKLE_HUB_GITHUB_CLIENT_SECRET_FILE", false) do
      {:ok,
       %{
         app_id: app_id,
         client_id: blank_to_nil(env["TACKLE_HUB_GITHUB_CLIENT_ID"]),
         private_key: private_key,
         webhook_secret: webhook_secret,
         client_secret: client_secret
       }}
    end
  end

  defp required(env, name) do
    case blank_to_nil(env[name]) do
      nil -> {:error, "#{name} is not set"}
      value -> {:ok, value}
    end
  end

  # Secrets are trimmed: files written by editors or `echo` end in newlines.
  defp secret_file(env, name, required?) do
    case {blank_to_nil(env[name]), required?} do
      {nil, true} ->
        {:error, "#{name} is not set"}

      {nil, false} ->
        {:ok, nil}

      {path, _required?} ->
        case File.read(path) do
          {:ok, contents} ->
            nonempty(String.trim(contents), name)

          {:error, reason} ->
            {:error, "#{name}: cannot read #{path}: #{:file.format_error(reason)}"}
        end
    end
  end

  defp nonempty("", name), do: {:error, "#{name} names an empty file"}
  defp nonempty(value, _name), do: {:ok, value}

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp raise_on_error({:ok, value}), do: value
  defp raise_on_error({:error, message}), do: raise(ArgumentError, message)
end
