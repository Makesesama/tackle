defmodule Tackle.Hub.Webhooks do
  @moduledoc """
  Acts on verified forge events (`Tackle.Hub.Forge.Event`): keeps
  installations (with the owner the forge names, docs/TACKLE_HUB_PLAN.md
  §7.12) and repositories in step with the forge, hands pull request and
  comment events to `Tackle.Hub.Triggers`, and review threads and new pull
  request heads to `Tackle.Hub.Feedback` (§7.13).

  Everything here is database work: forge API calls happen in jobs, so a
  webhook is answered well within the forge's timeout
  (docs/TACKLE_HUB_PLAN.md §7.7). Events about a repository record its
  installation and the repository itself when they are new, so a missed
  installation event does not lose reviews.
  """

  require Ash.Query
  require Logger

  alias Tackle.Hub.{Feedback, Triggers}
  alias Tackle.Hub.Forge.Event
  alias Tackle.Hub.Forges.{Installation, Repository}

  @resources [Installation, Repository]

  @doc "Handles one event from `forge`; returns what it led to."
  @spec handle(atom(), Event.t()) :: {:ok, atom() | tuple()} | {:error, term()}
  def handle(_forge, %Event{type: :ping}), do: {:ok, :pong}
  def handle(_forge, %Event{type: :ignored}), do: {:ok, :ignored}

  def handle(forge, %Event{type: :installation, action: action} = event) do
    status =
      case action do
        :deleted -> :removed
        :suspended -> :suspended
        active when active in [:created, :unsuspended] -> :active
      end

    Ash.transact(@resources, fn ->
      with {:ok, installation} <- sync_installation(forge, event.installation, status),
           :ok <- sync_repositories(installation, event.repositories),
           :ok <- deactivate_if_removed(installation, status) do
        {:installation, status}
      end
    end)
  end

  def handle(forge, %Event{type: :repositories_added} = event) do
    Ash.transact(@resources, fn ->
      with {:ok, installation} <- existing_or_new_installation(forge, event.installation),
           :ok <- sync_repositories(installation, event.repositories) do
        :repositories_added
      end
    end)
  end

  def handle(forge, %Event{type: :repositories_removed} = event) do
    Ash.transact(@resources, fn ->
      with {:ok, installation} <- existing_or_new_installation(forge, event.installation),
           :ok <- deactivate(installation, event.repositories) do
        :repositories_removed
      end
    end)
  end

  def handle(forge, %Event{type: :pull_request} = event) do
    with {:ok, repository} <- sync_repository(forge, event),
         {:ok, outcome, _request} <-
           Triggers.pull_request(repository, event.action, event.pull_request, event.sender) do
      reactions(repository, event)
      {:ok, outcome}
    end
  end

  def handle(forge, %Event{type: :review_thread} = event) do
    with {:ok, repository} <- sync_repository(forge, event) do
      Feedback.queue_thread(repository, event.action, event.thread, event.sender)
    end
  end

  def handle(forge, %Event{type: :comment} = event) do
    with {:ok, repository} <- sync_repository(forge, event),
         {:ok, outcome, _request} <- Triggers.comment(repository, event.comment) do
      {:ok, outcome}
    end
  end

  # A new head or a closed pull request is when people have reacted to the
  # last review's comments (§7.13). Best effort: the trigger above already
  # did its work, so a failure here only loses one reading of reactions.
  defp reactions(repository, %Event{action: action, pull_request: pull_request})
       when action in [:synchronize, :closed] do
    with {:error, reason} <- Feedback.queue_reactions(repository, pull_request.number) do
      Logger.warning("could not queue reading reactions: #{inspect(reason)}")
    end
  end

  defp reactions(_repository, _event), do: :ok

  # Only installation events change an installation's status. Other events
  # record an installation they name for the first time as active.
  #
  # Ash.transact/3 returns `{:ok, result}` for whatever the function returns,
  # and rolls back and returns the error when it returns `{:error, reason}`.
  defp sync_repository(forge, %Event{installation: installation, repository: repository}) do
    Ash.transact(@resources, fn ->
      with {:ok, record} <- existing_or_new_installation(forge, installation),
           {:ok, synced} <-
             Repository.sync(record.id, repository.external_id, repository.owner, repository.name) do
        %{synced | installation: record}
      end
    end)
  end

  defp existing_or_new_installation(forge, installation) do
    case Installation.get_external(forge, installation.external_id) do
      {:ok, nil} -> sync_installation(forge, installation, :active)
      {:ok, existing} -> {:ok, existing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_installation(forge, installation, status) do
    with {:ok, record} <-
           Installation.sync(forge, installation.external_id, installation.account, status) do
      Installation.put_owner(record, Map.get(installation, :owner))
    end
  end

  defp sync_repositories(installation, repositories) do
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
  end

  defp deactivate(installation, repositories) do
    external_ids = Enum.map(repositories, & &1.external_id)

    Repository
    |> Ash.Query.filter(installation_id == ^installation.id and external_id in ^external_ids)
    |> bulk_deactivate()
  end

  defp deactivate_if_removed(installation, :removed), do: deactivate_all(installation)
  defp deactivate_if_removed(_installation, _status), do: :ok

  defp deactivate_all(installation) do
    Repository
    |> Ash.Query.filter(installation_id == ^installation.id)
    |> bulk_deactivate()
  end

  defp bulk_deactivate(query) do
    case Ash.bulk_update(query, :deactivate, %{},
           return_errors?: true,
           notify?: true,
           strategy: [:atomic, :stream]
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end
end
