defmodule Tackle.Web.Feedback do
  @moduledoc """
  What people do with posted findings (docs/TACKLE_WEB_PLAN.md §7.13), as
  plain functions for `Tackle.Web.Webhooks` and `Tackle.Web.Feedback.Job`:

    * a review thread resolved on the forge by someone with write access
      dismisses its finding in the repository (`Tackle.Web.Reviews.Dismissal`);
      unresolved by such a person, it is restored;
    * the reactions on posted comments are read for a pull request when it
      gets a new head or is closed, and stored on the findings.

  A thread counts only through the forge's id of a comment tackle posted in
  that repository (`Finding.forge_comment_id`): the comments' text is never
  trusted. The webhook side is database work only; forge calls (the
  write-access check, reading reactions) happen in the job.
  """

  require Ash.Query

  alias Tackle.Web.Feedback.Job
  alias Tackle.Web.Forges.Repository
  alias Tackle.Web.Reviews.{Dismissal, Finding}

  @doc "Queues the handling of a resolved or unresolved review thread."
  @spec queue_thread(Repository.t(), :resolved | :unresolved, map(), String.t()) ::
          {:ok, :feedback_queued | :not_ours} | {:error, term()}
  def queue_thread(%Repository{} = repository, action, thread, login) do
    if posted_findings(repository.id, thread.comment_ids) == [] do
      {:ok, :not_ours}
    else
      %{
        kind: "thread",
        repository_id: repository.id,
        pull_number: thread.pull_number,
        comment_ids: thread.comment_ids,
        action: Atom.to_string(action),
        login: login
      }
      |> Job.new()
      |> Oban.insert()
      |> queued()
    end
  end

  @doc """
  Queues reading the reactions of a pull request's posted comments, when
  it has any. Repeated requests within a minute are one job.
  """
  @spec queue_reactions(Repository.t(), pos_integer()) ::
          {:ok, :reactions_queued | :nothing_posted} | {:error, term()}
  def queue_reactions(%Repository{} = repository, number) do
    if posted?(repository.id, number) do
      %{kind: "reactions", repository_id: repository.id, pull_number: number}
      |> Job.new(unique: [period: 60, fields: [:worker, :args]])
      |> Oban.insert()
      |> case do
        {:ok, _job} -> {:ok, :reactions_queued}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, :nothing_posted}
    end
  end

  defp queued({:ok, _job}), do: {:ok, :feedback_queued}
  defp queued({:error, reason}), do: {:error, reason}

  @doc """
  The findings tackle posted in the repository as the comments with these
  forge ids. Trusted read.
  """
  @spec posted_findings(Ecto.UUID.t(), [String.t()]) :: [Finding.t()]
  def posted_findings(_repository_id, []), do: []

  def posted_findings(repository_id, comment_ids) do
    Finding
    |> Ash.Query.filter(
      forge_comment_id in ^comment_ids and run.request.repository_id == ^repository_id
    )
    |> Ash.Query.load(run: :request)
    |> Ash.read!()
  end

  defp posted?(repository_id, number) do
    Finding
    |> Ash.Query.filter(
      not is_nil(forge_comment_id) and run.request.repository_id == ^repository_id and
        run.request.pull_number == ^number
    )
    |> Ash.exists?()
  end

  @doc """
  Records a thread resolved (dismiss) or unresolved (restore) by `login`,
  who was checked to have write access, for the posted `findings`.
  """
  @spec record_thread([Finding.t()], Repository.t(), :resolved | :unresolved, String.t()) ::
          :ok | {:error, term()}
  def record_thread(findings, repository, action, login) do
    findings
    |> Enum.uniq_by(& &1.fingerprint)
    |> Enum.reduce_while(:ok, fn finding, :ok ->
      case thread_change(finding, repository, action, login) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp thread_change(finding, repository, :resolved, login) do
    attributes = %{
      title: finding.title,
      pull_number: finding.run.request.pull_number,
      source: :forge,
      by: login
    }

    case Dismissal.dismiss(repository.id, finding.fingerprint, attributes) do
      {:ok, _dismissal} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp thread_change(finding, repository, :unresolved, _login) do
    case Dismissal.get(repository.id, finding.fingerprint) do
      {:ok, nil} -> :ok
      {:ok, dismissal} -> Dismissal.restore(dismissal)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stores the forge's reaction counts on the repository's posted findings
  with those comment ids; findings whose counts did not change are left as
  they are.
  """
  @spec record_reactions(Repository.t(), [Tackle.Web.Forge.comment_reactions()]) :: :ok
  def record_reactions(repository, reactions) do
    by_id = Map.new(reactions, &{&1.id, &1})

    repository.id
    |> posted_findings(Map.keys(by_id))
    |> Enum.each(fn finding ->
      %{up: up, down: down} = Map.fetch!(by_id, finding.forge_comment_id)

      if {finding.reactions_up, finding.reactions_down} != {up, down} do
        finding
        |> Ash.Changeset.for_update(:record_reactions, %{reactions_up: up, reactions_down: down})
        |> Ash.update!()
      end
    end)
  end

  @doc "The fingerprints dismissed in a repository, for the next review. Trusted read."
  @spec dismissed_fingerprints(Ecto.UUID.t()) :: [String.t()]
  def dismissed_fingerprints(repository_id) do
    Dismissal
    |> Ash.Query.filter(repository_id == ^repository_id)
    |> Ash.Query.select([:fingerprint])
    |> Ash.read!()
    |> Enum.map(& &1.fingerprint)
  end
end
