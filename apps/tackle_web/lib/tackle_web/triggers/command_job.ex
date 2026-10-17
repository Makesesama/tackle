defmodule Tackle.Web.Triggers.CommandJob do
  @moduledoc """
  Finishes a `/tackle review` command outside the webhook request
  (docs/TACKLE_WEB_PLAN.md §7.7) with `Tackle.Web.Triggers.run_command/4`:
  checks that the comment's author has write access, reads the pull
  request's current head from the forge, and requests its review.

  Forge errors are retried. A command that may not run (no write access, a
  disabled repository, a closed pull request) is cancelled with the reason.
  """

  use Oban.Worker, queue: :forge, max_attempts: 5

  require Logger

  alias Tackle.Web.Forges.Repository
  alias Tackle.Web.Reviews.Profile
  alias Tackle.Web.Triggers

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{"repository_id" => repository_id, "pull_number" => number, "login" => login} = args
      }) do
    with {:ok, profile} <- profile(args["profile"]),
         {:ok, repository} <- repository(repository_id) do
      case Triggers.run_command(repository, number, login, profile) do
        {:ok, outcome, _request} ->
          finish(outcome, login, repository, number)

        {:error, :no_write_access} ->
          {:cancel, "#{login} has no write access to #{full_name(repository)}"}

        {:error, :no_forge_app} ->
          {:cancel, "the #{repository.installation.forge} app is not configured"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp repository(id) do
    case Ash.get(Repository, id, load: [:installation], not_found_error?: false) do
      {:ok, nil} -> {:cancel, "the repository no longer exists"}
      result -> result
    end
  end

  defp profile(nil), do: {:ok, nil}

  defp profile(value) do
    case Profile.match(value) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:cancel, "unknown profile #{inspect(value)}"}
    end
  end

  defp finish(outcome, _login, _repository, _number) when outcome in [:created, :rerun, :exists],
    do: :ok

  defp finish(outcome, login, repository, number) do
    Logger.info("review command by #{login} on #{full_name(repository)}##{number}: #{outcome}")
    {:cancel, "not reviewed: #{outcome}"}
  end

  defp full_name(repository), do: "#{repository.owner}/#{repository.name}"
end
