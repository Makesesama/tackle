defmodule Tackle.Hub.Forges.Access.Resolve do
  @moduledoc """
  For `Access.grant`: checks that a granted repository belongs to the
  installation, and resolves the `login` argument to the forge's user id
  and canonical login. The forge is asked before the transaction starts.
  """

  use Ash.Resource.Change

  alias Tackle.Hub.Forge
  alias Tackle.Hub.Forges.{ForgeApp, Installation, Repository}

  @impl Ash.Resource.Change
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      with {:ok, installation} <- installation(changeset),
           :ok <- check_repository(changeset, installation),
           {:ok, user} <- forge_user(installation, Ash.Changeset.get_argument(changeset, :login)) do
        Ash.Changeset.force_change_attributes(changeset,
          forge_user_id: user.external_id,
          login: user.login
        )
      else
        {:error, field, message} ->
          Ash.Changeset.add_error(changeset, field: field, message: message)
      end
    end)
  end

  defp installation(changeset) do
    with id when is_binary(id) <- Ash.Changeset.get_attribute(changeset, :installation_id),
         {:ok, %Installation{} = installation} <-
           Ash.get(Installation, id, not_found_error?: false) do
      {:ok, installation}
    else
      _other -> {:error, :installation_id, "is not an installation"}
    end
  end

  defp check_repository(changeset, installation) do
    case Ash.Changeset.get_attribute(changeset, :repository_id) do
      nil ->
        :ok

      id ->
        case Ash.get(Repository, id, not_found_error?: false) do
          {:ok, %Repository{installation_id: installation_id}}
          when installation_id == installation.id ->
            :ok

          _other ->
            {:error, :repository_id, "is not a repository of the installation"}
        end
    end
  end

  defp forge_user(installation, login) do
    with {:ok, %ForgeApp{} = forge_app} <- ForgeApp.get(installation.forge),
         {:ok, user} <- Forge.module(installation.forge).user(forge_app, installation, login) do
      {:ok, user}
    else
      {:error, :not_found} -> {:error, :login, "is not a user on the forge"}
      _other -> {:error, :login, "could not be checked with the forge; try again"}
    end
  end
end
