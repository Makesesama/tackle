defmodule Tackle.Web.ForgeSync do
  @moduledoc """
  Records installations and repositories from the forge's API instead of
  its webhooks (docs/TACKLE_WEB_PLAN.md §7.11): after an installation's
  setup redirect, and from the admins' "Sync from GitHub" button, which also
  repairs anything missed webhooks left behind.

  The forge is read first; the database is written afterwards in one
  transaction, with the same rules as `Tackle.Web.Webhooks`: new
  repositories take their installation's defaults, existing ones keep their
  settings, an installation without an owner gets the one the forge names
  (only for user accounts, §7.12), and repositories the app can no longer access are deactivated,
  never deleted. Only records not updated since the forge was read are
  deactivated or removed, so a webhook that arrives meanwhile is not undone
  by the older snapshot.
  """

  require Ash.Query

  alias Tackle.Web.Forge
  alias Tackle.Web.Forges.{ForgeApp, Installation, Repository}

  @resources [Installation, Repository]

  @typedoc "What a sync recorded."
  @type summary :: %{installations: non_neg_integer(), repositories: non_neg_integer()}

  @doc """
  Reconciles every installation of the forge app: installations the forge
  no longer lists are marked `:removed` and their repositories deactivated.
  """
  @spec sync_all(atom()) :: {:ok, summary()} | {:error, term()}
  def sync_all(forge) do
    read_at = DateTime.utc_now()

    with {:ok, forge_app} <- forge_app(forge),
         {:ok, snapshots} <- Forge.module(forge).installations(forge_app) do
      Ash.transact(@resources, fn -> write(forge, snapshots, read_at, true) end)
    end
  end

  @doc """
  Records one installation, confirmed with the forge by its id: an id
  that is not the app's installation is `{:error, :not_found}`.
  """
  @spec sync_installation(atom(), String.t()) :: {:ok, summary()} | {:error, term()}
  def sync_installation(forge, external_id) when is_binary(external_id) do
    read_at = DateTime.utc_now()

    with {:ok, forge_app} <- forge_app(forge),
         {:ok, snapshot} <- Forge.module(forge).installation(forge_app, external_id) do
      Ash.transact(@resources, fn -> write(forge, [snapshot], read_at, false) end)
    end
  end

  defp forge_app(forge) do
    case ForgeApp.get(forge) do
      {:ok, %ForgeApp{} = forge_app} -> {:ok, forge_app}
      {:ok, nil} -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  # Ash.transact/3 rolls back when this returns `{:error, reason}`.
  defp write(forge, snapshots, read_at, complete?) do
    with :ok <- apply_all(forge, snapshots, read_at),
         :ok <- if(complete?, do: remove_unlisted(forge, snapshots, read_at), else: :ok) do
      summary(snapshots)
    end
  end

  defp apply_all(forge, snapshots, read_at) do
    Enum.reduce_while(snapshots, :ok, fn snapshot, :ok ->
      case apply_snapshot(forge, snapshot, read_at) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_snapshot(forge, %{installation: installation, status: status} = snapshot, read_at) do
    with {:ok, record} <-
           Installation.sync(forge, installation.external_id, installation.account, status),
         {:ok, record} <- Installation.put_owner(record, Map.get(installation, :owner)) do
      sync_repositories(record, snapshot.repositories, read_at)
    end
  end

  # Unknown repositories (a suspended installation) are left as they are.
  defp sync_repositories(_installation, nil, _read_at), do: :ok

  defp sync_repositories(installation, repositories, read_at) do
    synced =
      Enum.reduce_while(repositories, :ok, fn repository, :ok ->
        case Repository.sync(
               installation.id,
               repository.external_id,
               repository.owner,
               repository.name
             ) do
          {:ok, _repository} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with :ok <- synced do
      listed = Enum.map(repositories, & &1.external_id)

      Repository
      |> Ash.Query.filter(
        installation_id == ^installation.id and active == true and external_id not in ^listed and
          updated_at < ^read_at
      )
      |> deactivate()
    end
  end

  defp remove_unlisted(forge, snapshots, read_at) do
    listed = Enum.map(snapshots, & &1.installation.external_id)

    removed =
      Installation
      |> Ash.Query.filter(
        forge == ^forge and status != :removed and external_id not in ^listed and
          updated_at < ^read_at
      )
      |> Ash.read!()

    Enum.reduce_while(removed, :ok, fn installation, :ok ->
      with {:ok, _installation} <-
             Installation.sync(forge, installation.external_id, installation.account, :removed),
           :ok <-
             Repository
             |> Ash.Query.filter(installation_id == ^installation.id and active == true)
             |> deactivate() do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp deactivate(query) do
    case Ash.bulk_update(query, :deactivate, %{},
           return_errors?: true,
           strategy: [:atomic, :stream]
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  defp summary(snapshots) do
    %{
      installations: length(snapshots),
      repositories: snapshots |> Enum.map(&length(&1.repositories || [])) |> Enum.sum()
    }
  end
end
