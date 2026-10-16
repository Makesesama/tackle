defmodule Tackle.Web.ReviewJob.Store do
  @moduledoc false
  import Ecto.Query, only: [from: 2]

  alias Tackle.Lib.Usage
  alias Tackle.Review.Result
  alias Tackle.Web.Forges.Repository
  alias Tackle.Web.Repo
  alias Tackle.Web.ReviewJob.JSON, as: ReviewJSON
  alias Tackle.Web.Reviews.{Finding, ReviewRequest, ReviewRun}

  @terminal [:reviewed, :posted, :failed, :skipped]

  def claim(id, job) do
    Repo.transaction(fn ->
      with true <- advisory_lock(id),
           request <- locked_request(id),
           false <- request.status in @terminal,
           true <- executing?(job) do
        claim_owner(request, job)
      else
        _no_work -> :noop
      end
    end)
  end

  defp claim_owner(%{status: :running} = request, job) do
    owner = if request.claimed_job_id, do: Repo.get(Oban.Job, request.claimed_job_id)

    cond do
      owner == nil or owner.state in ["discarded", "cancelled", "completed"] ->
        update(request, %{
          status: :failed,
          error: "previous review job ended without a stored run"
        })

        :noop

      owner.id == job.id and job.attempt > request.claimed_attempt ->
        admit(request, job)

      true ->
        :noop
    end
  end

  defp claim_owner(request, job), do: admit(request, job)

  defp admit(request, job) do
    repo = Ash.get!(Repository, request.repository_id, load: [:installation])

    cond do
      not repo.enabled or not repo.active or repo.installation.status != :active ->
        update(request, %{status: :skipped, error: "repository or installation is disabled"})
        :noop

      budget_reached?(repo) ->
        update(request, %{status: :skipped, error: "daily token budget reached"})
        :noop

      true ->
        request =
          update(request, %{
            status: :running,
            error: nil,
            claimed_job_id: job.id,
            claimed_attempt: job.attempt
          })

        {:claimed, request, repo}
    end
  end

  defp budget_reached?(%{daily_token_budget: nil}), do: false
  defp budget_reached?(repo), do: daily_tokens(repo.id) >= repo.daily_token_budget

  # UTC calendar day, not the server's local time or a rolling 24 hours.
  def daily_tokens(repository_id) do
    {:ok, uuid} = Ecto.UUID.dump(repository_id)

    %{rows: [[total]]} =
      Repo.query!(
        """
        SELECT COALESCE(SUM(COALESCE((r.usage->>'total_tokens')::bigint, 0)), 0)
        FROM review_runs r JOIN review_requests q ON q.id = r.request_id
        WHERE q.repository_id = $1
          AND r.inserted_at >= date_trunc('day', now() AT TIME ZONE 'UTC')
          AND r.inserted_at < date_trunc('day', now() AT TIME ZONE 'UTC') + interval '1 day'
        """,
        [uuid]
      )

    Decimal.to_integer(Decimal.new(total))
  end

  def complete(id, job, result, duration_ms) do
    Repo.transaction(fn ->
      request = locked_request(id)

      if owned?(request, job) and executing?(job) do
        run =
          Ash.create!(ReviewRun, %{
            request_id: id,
            summary: ReviewJSON.summary(result.summary),
            usage: ReviewJSON.safe(Usage.normalize(result.usage) || %{}),
            duration_ms: duration_ms,
            verdict: result.summary.verdict
          })

        store_findings(run.id, result)
        update(request, %{status: :reviewed, error: nil})
        :ok
      else
        :stale
      end
    end)
  end

  def attempt_failed(id, job, message), do: record_failure(id, job, message, :running)

  def failed(id, job, message), do: record_failure(id, job, message, failure_status(job))

  defp record_failure(id, job, message, status) do
    Repo.transaction(fn ->
      request = locked_request(id)

      if owned?(request, job) and executing?(job) do
        update(request, %{status: status, error: message})
      end

      :ok
    end)
  end

  defp failure_status(%{attempt: attempt, max_attempts: max}) when attempt >= max, do: :failed
  defp failure_status(_job), do: :running

  defp store_findings(run_id, result) do
    Enum.each(Result.findings(result), &store_finding(run_id, &1, :shown, %{}))

    Enum.each(
      result.rejected,
      &store_finding(run_id, &1.finding, :rejected, %{evidence: &1.evidence})
    )

    Enum.each(
      Result.hidden(result),
      &store_finding(run_id, &1.finding, :hidden, %{
        hidden_reason: %{reason: ReviewJSON.safe(&1.reason)}
      })
    )
  end

  defp store_finding(run_id, finding, state, extra) do
    finding
    |> Map.from_struct()
    |> Map.delete(:location)
    |> Map.merge(finding.location)
    |> Map.merge(extra)
    |> Map.merge(%{run_id: run_id, state: state})
    |> then(&Ash.create!(Finding, &1))
  end

  defp update(request, attrs) do
    request |> Ash.Changeset.for_update(:record_progress, attrs) |> Ash.update!()
  end

  defp owned?(request, job),
    do:
      request.status == :running and
        request.claimed_job_id == job.id and request.claimed_attempt == job.attempt

  defp executing?(job) do
    Repo.one(
      from j in Oban.Job,
        where: j.id == ^job.id and j.attempt == ^job.attempt and j.state == "executing",
        select: j.id,
        lock: "FOR UPDATE"
    ) != nil
  end

  defp advisory_lock(id) do
    <<key::signed-64, _rest::binary>> = :crypto.hash(:sha256, "tackle-web/review/" <> id)
    %{rows: [[locked]]} = Repo.query!("SELECT pg_try_advisory_xact_lock($1)", [key])
    locked
  end

  defp locked_request(id) do
    {:ok, uuid} = Ecto.UUID.dump(id)
    Repo.query!("SELECT id FROM review_requests WHERE id = $1 FOR UPDATE", [uuid])
    Ash.get!(ReviewRequest, id)
  end
end
