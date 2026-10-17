defmodule Tackle.Web.Feedback.Job do
  @moduledoc """
  The forge side of `Tackle.Web.Feedback` (docs/TACKLE_WEB_PLAN.md §7.13),
  outside the webhook request:

    * `"thread"` - checks that whoever resolved or unresolved a thread of
      tackle's comments has write access, then dismisses or restores the
      findings. Without write access (a pull request's author, say) it is
      cancelled and nothing changes.
    * `"reactions"` - reads the reactions on a pull request's comments and
      stores the counts on the posted findings.

  Forge errors are retried.
  """

  use Oban.Worker, queue: :forge, max_attempts: 5

  alias Tackle.Web.{Feedback, Forge}
  alias Tackle.Web.Forges.{ForgeApp, Repository}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => kind, "repository_id" => repository_id} = args}) do
    with {:ok, repository} <- repository(repository_id),
         {:ok, forge_app} <- forge_app(repository.installation.forge) do
      run(kind, args, repository, forge_app, Forge.module(repository.installation.forge))
    end
  end

  defp run(
         "thread",
         %{"comment_ids" => ids, "action" => action, "login" => login},
         repository,
         app,
         forge
       )
       when action in ["resolved", "unresolved"] do
    case Feedback.posted_findings(repository.id, ids) do
      [] ->
        {:cancel, "the thread has no comment of tackle's"}

      findings ->
        case forge.can_trigger?(app, repository.installation, repository, login) do
          {:ok, true} ->
            Feedback.record_thread(findings, repository, thread_action(action), login)

          {:ok, false} ->
            {:cancel, "#{login} has no write access; the thread does not count"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp run("reactions", %{"pull_number" => number}, repository, app, forge) do
    with {:ok, reactions} <-
           forge.review_comment_reactions(app, repository.installation, repository, number) do
      Feedback.record_reactions(repository, reactions)
    end
  end

  defp run(kind, _args, _repository, _app, _forge), do: {:cancel, "unknown feedback #{kind}"}

  defp thread_action("resolved"), do: :resolved
  defp thread_action("unresolved"), do: :unresolved

  defp repository(id) do
    case Ash.get(Repository, id, load: [:installation], not_found_error?: false) do
      {:ok, nil} -> {:cancel, "the repository no longer exists"}
      result -> result
    end
  end

  defp forge_app(forge) do
    case ForgeApp.get(forge) do
      {:ok, %ForgeApp{} = forge_app} -> {:ok, forge_app}
      {:ok, nil} -> {:cancel, "the #{forge} app is not configured"}
      {:error, reason} -> {:error, reason}
    end
  end
end
