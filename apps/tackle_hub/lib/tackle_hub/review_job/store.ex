defmodule Tackle.Hub.ReviewJob.Store do
  @moduledoc false
  import Ecto.Query, only: [from: 2]

  alias Tackle.Hub.Forges.Repository
  alias Tackle.Hub.Repo
  alias Tackle.Hub.ReviewJob.JSON, as: ReviewJSON
  alias Tackle.Hub.Reviews.{Finding, ReviewRequest, ReviewRun}
  alias Tackle.Lib.Usage
  alias Tackle.Review.Result

  require Ash.Query

  @terminal [:posted, :failed, :skipped]
  @active_jobs ["available", "scheduled", "executing", "retryable"]
  @posting_error "forge posting failed; retry posting to use the stored review"

  # Final posting failures store this exact, fixed text (never forge data), so
  # retry_posting/1 can tell them from review failures, which cost tokens again.
  @doc false
  def posting_error, do: @posting_error

  # Returns {:ok, {:claimed, request, repo}} for a paid review,
  # {:ok, {:post, request, repo}} for posting an already stored review, or
  # {:ok, :noop}.
  def claim(id, job) do
    transaction(fn ->
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

  # Posting reuses the stored run: no models, no budget. A live or retryable
  # other job (or a duplicate of this attempt) owns it; an owner that ended
  # without posting (missing, or completed in a crash gap) hands over, while an
  # exhausted/cancelled one fails instead of starting retries over.
  defp claim_owner(%{status: :reviewed} = request, job) do
    owner = if request.claimed_job_id, do: Repo.get(Oban.Job, request.claimed_job_id)

    cond do
      owner == nil or owner.state == "completed" ->
        admit_post(request, job)

      owner.id == job.id and job.attempt > request.claimed_attempt ->
        admit_post(request, job)

      owner.state in ["discarded", "cancelled"] ->
        update(request, %{status: :failed, error: @posting_error})
        :noop

      true ->
        :noop
    end
  end

  defp claim_owner(request, job), do: admit(request, job)

  defp admit_post(request, job) do
    request =
      update(request, %{error: nil, claimed_job_id: job.id, claimed_attempt: job.attempt})

    {:post, request, Ash.get!(Repository, request.repository_id, load: [:installation])}
  end

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
    transaction(fn ->
      request = locked_request(id)

      if request.status == :running and owned?(request, job) and executing?(job) do
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

  # A failed posting attempt keeps the stored review (:reviewed) so the next
  # attempt only posts; the final one fails with the fixed posting error.
  def attempt_failed(id, job, message), do: record_failure(id, job, message, false)

  def failed(id, job, message), do: record_failure(id, job, message, final?(job))

  defp record_failure(id, job, message, final?) do
    transaction(fn ->
      request = locked_request(id)

      if owned?(request, job) and executing?(job) do
        update(request, failure(request.status, message, final?))
      end

      :ok
    end)
  end

  defp failure(:reviewed, _message, true), do: %{status: :failed, error: @posting_error}
  defp failure(:reviewed, message, false), do: %{error: message}
  defp failure(:running, message, true), do: %{status: :failed, error: message}
  defp failure(:running, message, false), do: %{error: message}

  defp final?(%{attempt: attempt, max_attempts: max}), do: attempt >= max

  @doc """
  The request, its latest run (with findings), and its repository (with
  installation), when `job` is the executing owner of the reviewed request.
  Only reads; no forge calls happen while the lock is held.
  """
  def posting_snapshot(id, job) do
    transaction(fn ->
      with {:ok, request} <- posting_owner(id, job),
           %ReviewRun{} = run <- latest_run(id) do
        %{
          request: request,
          run: Ash.load!(run, findings: Ash.Query.sort(Finding, inserted_at: :asc, id: :asc)),
          repository: Ash.get!(Repository, request.repository_id, load: [:installation])
        }
      else
        _stale -> {:abort, :stale}
      end
    end)
  end

  @doc """
  Freezes the review to post for `run_id` in its summary's `"posting"` entry
  (string keys, as JSON) and returns it. A run already prepared is returned
  as stored, unchanged, so every attempt posts the same review.
  """
  def prepare_posting(id, job, run_id, %{body: body, comments: comments, fingerprints: prints})
      when is_binary(body) and is_list(comments) and is_list(prints) do
    transaction(fn ->
      with {:ok, _request} <- posting_owner(id, job),
           %ReviewRun{id: ^run_id} = run <- latest_run(id) do
        freeze_posting(run, %{body: body, comments: comments, fingerprints: prints})
      else
        _stale -> {:abort, :stale}
      end
    end)
  end

  def prepare_posting(_id, _job, _run_id, _payload), do: {:error, :invalid_payload}

  defp freeze_posting(%{summary: %{"posting" => %{"body" => _} = posting}}, _payload),
    do: Map.take(posting, ["body", "comments", "fingerprints"])

  defp freeze_posting(run, payload) do
    posting = ReviewJSON.safe(payload)
    record_posting(run, Map.put(run.summary, "posting", posting))
    posting
  end

  @doc """
  Records a posted review in one transaction: the run's prepared `"posting"`
  entry gains `"review_id"` and `"comment_ids"` (fingerprint => comment id),
  shown findings of the run get their `forge_comment_id`, and the request
  becomes `:posted` with `forge_review_id`.
  """
  def posted(id, job, run_id, review_id, comment_ids)
      when is_binary(review_id) and is_map(comment_ids) do
    if Enum.all?(comment_ids, fn {print, comment} -> is_binary(print) and is_binary(comment) end),
      do: record_posted(id, job, run_id, review_id, comment_ids),
      else: {:error, :invalid_payload}
  end

  def posted(_id, _job, _run_id, _review_id, _comment_ids), do: {:error, :invalid_payload}

  defp record_posted(id, job, run_id, review_id, comment_ids) do
    transaction(fn ->
      with {:ok, request} <- posting_owner(id, job),
           %ReviewRun{id: ^run_id, summary: %{"posting" => %{"body" => _} = posting} = summary} =
             run <- latest_run(id) do
        comment_ids = ReviewJSON.safe(comment_ids)
        posting = Map.merge(posting, %{"review_id" => review_id, "comment_ids" => comment_ids})
        record_posting(run, Map.put(summary, "posting", posting))
        record_comments(run.id, comment_ids)
        update(request, %{status: :posted, error: nil, forge_review_id: review_id})
        :ok
      else
        _stale -> {:abort, :stale}
      end
    end)
  end

  @doc """
  Posts a request's stored review again without reviewing it again: a
  `:reviewed` request no job is working on, or one that failed with exactly
  `posting_error/0`. The request returns to `:reviewed` without its claim and
  a job is enqueued in the same transaction. Other requests are not touched.
  """
  def retry_posting(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> reset_posting(id)
      :error -> {:error, :not_retryable}
    end
  end

  defp reset_posting(id) do
    transaction(fn ->
      blocking_advisory_lock(id)

      with %ReviewRequest{} = request <- locked_request(id, false),
           true <- posting_retryable?(request) do
        request =
          update(request, %{
            status: :reviewed,
            error: nil,
            claimed_job_id: nil,
            claimed_attempt: nil
          })

        AshOban.run_trigger(request, :run)
        request
      else
        _not_retryable -> {:abort, :not_retryable}
      end
    end)
  end

  defp posting_retryable?(%{status: :failed, error: @posting_error}), do: true

  defp posting_retryable?(%{status: :reviewed, claimed_job_id: nil}), do: true

  defp posting_retryable?(%{status: :reviewed, claimed_job_id: job_id}) do
    case Repo.get(Oban.Job, job_id) do
      %Oban.Job{state: state} when state in @active_jobs -> false
      _ended -> true
    end
  end

  defp posting_retryable?(_request), do: false

  # A deleted request is as stale as one another job or a rerun took over.
  defp posting_owner(id, job) do
    case locked_request(id, false) do
      %ReviewRequest{status: :reviewed} = request ->
        if owned?(request, job) and executing?(job), do: {:ok, request}, else: :stale

      _gone_or_changed ->
        :stale
    end
  end

  # Deterministic even when runs share a timestamp.
  defp latest_run(id) do
    ReviewRun
    |> Ash.Query.filter(request_id == ^id)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!()
  end

  defp record_posting(run, summary) do
    run |> Ash.Changeset.for_update(:record_posting, %{summary: summary}) |> Ash.update!()
  end

  defp record_comments(_run_id, comment_ids) when map_size(comment_ids) == 0, do: :ok

  defp record_comments(run_id, comment_ids) do
    fingerprints = Map.keys(comment_ids)

    Finding
    |> Ash.Query.filter(run_id == ^run_id and state == :shown and fingerprint in ^fingerprints)
    |> Ash.read!()
    |> Enum.each(fn finding ->
      finding
      |> Ash.Changeset.for_update(:record_comment, %{
        forge_comment_id: Map.fetch!(comment_ids, finding.fingerprint)
      })
      |> Ash.update!()
    end)
  end

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

  # Like Repo.transaction/1, with `{:abort, reason}` for Repo.rollback/1:
  # every abort comes before any write, so committing it changes nothing.
  # Ash queues the notifications of the writes inside (Tackle.Hub.Updates)
  # and sends them once the outermost transaction commits, so live pages
  # never read uncommitted state.
  defp transaction(fun) do
    case Ash.transact(ReviewRequest, fun) do
      {:ok, {:abort, reason}} -> {:error, reason}
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  end

  defp update(request, attrs) do
    request |> Ash.Changeset.for_update(:record_progress, attrs) |> Ash.update!()
  end

  # Callers that may only act on one status (complete: :running, posting:
  # :reviewed) check it as well.
  defp owned?(request, job),
    do:
      request.status in [:running, :reviewed] and
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
    %{rows: [[locked]]} = Repo.query!("SELECT pg_try_advisory_xact_lock($1)", [lock_key(id)])
    locked
  end

  defp blocking_advisory_lock(id),
    do: Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key(id)])

  defp lock_key(id) do
    <<key::signed-64, _rest::binary>> = :crypto.hash(:sha256, "tackle-hub/review/" <> id)
    key
  end

  defp locked_request(id, must_exist? \\ true) do
    {:ok, uuid} = Ecto.UUID.dump(id)
    Repo.query!("SELECT id FROM review_requests WHERE id = $1 FOR UPDATE", [uuid])

    if must_exist?,
      do: Ash.get!(ReviewRequest, id),
      else: Ash.get!(ReviewRequest, id, not_found_error?: false)
  end
end
