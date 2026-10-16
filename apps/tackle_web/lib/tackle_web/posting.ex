defmodule Tackle.Web.Posting do
  @moduledoc """
  Posts stored review findings, never runs a review or starts a checkout.

  The sanitized payload is frozen in `ReviewRun.summary["posting"]` before
  sending it. Every attempt first looks for the run's hidden marker in a
  review by this app. A lost response therefore recovers the review and its
  comment IDs instead of submitting again. Fingerprints include body-only
  findings, but not entries omitted by the formatter's size cap.

  Posting is serialized per repository/pull request across connected BEAM
  nodes. Request ownership is rechecked after taking that lock and before a
  mutation. No database connection is held across forge calls. Do not run
  disconnected application nodes against the same database.

  An unresolved prepared posting from another run is reconciled first. If
  its marker is absent, later runs wait for that posting to be retried; this
  prevents a later head from stealing its fingerprints while its response
  is uncertain. `retry/1` retries an exhausted posting without paying for a
  new review. An explicit `ReviewRequest.rerun/2` still requests a new review.
  """

  alias Tackle.Web.Forge
  alias Tackle.Web.Forges.ForgeApp
  alias Tackle.Web.Posting.Format
  alias Tackle.Web.ReviewJob.Store
  alias Tackle.Web.Reviews.{ReviewRequest, ReviewRun}

  require Ash.Query

  @doc "Retries posting a stored review; rejects review failures and live posting jobs."
  @spec retry(Ecto.UUID.t()) :: {:ok, ReviewRequest.t()} | {:error, term()}
  def retry(request_id), do: Store.retry_posting(request_id)

  @doc "Posts for the executing, fenced Oban owner. Options are trusted host test seams only."
  @spec post(ReviewRequest.t(), map(), Oban.Job.t(), keyword()) :: :ok | {:error, String.t()}
  def post(request, _repository, job, opts \\ []) do
    lock = {{__MODULE__, request.repository_id, request.pull_number}, self()}

    case :global.trans(lock, fn -> post_locked(request.id, job, opts) end) do
      :ok -> :ok
      {:error, :stale} -> :ok
      _error -> {:error, Store.posting_error()}
    end
  rescue
    _error -> {:error, Store.posting_error()}
  end

  defp post_locked(id, job, opts) do
    with {:ok, snapshot} <- Store.posting_snapshot(id, job),
         {:ok, context} <- context(snapshot, job, opts),
         {:ok, payload} <- prepare(context),
         {:ok, review_id} <- find_or_post(context, payload),
         {:ok, comments} <- comments(context, review_id, payload),
         {:ok, :ok} <- Store.posted(id, job, context.run.id, review_id, comments) do
      :ok
    end
  end

  defp context(snapshot, job, opts) do
    repository = snapshot.repository
    installation = repository.installation

    # Disabling an integration must stop new side effects, but must not lose
    # the paid result. Once re-enabled it can be retried through retry/1.
    with true <- repository.enabled and repository.active and installation.status == :active,
         {:ok, %ForgeApp{} = app} <- ForgeApp.get(installation.forge) do
      {:ok,
       Map.merge(snapshot, %{
         job: job,
         app: app,
         installation: installation,
         forge: Keyword.get(opts, :forge, Forge.module(installation.forge))
       })}
    else
      _unavailable -> {:error, :forge_unavailable}
    end
  end

  defp prepare(%{run: %{summary: %{"posting" => %{"body" => _} = payload}}}),
    do: {:ok, payload}

  defp prepare(context) do
    with {:ok, known} <- known_fingerprints(context),
         {:ok, files} <- diff_files(context) do
      payload =
        Format.build(context.request, context.run, context.run.findings, files, known)

      Store.prepare_posting(context.request.id, context.job, context.run.id, payload)
    end
  end

  defp known_fingerprints(context) do
    request = context.request

    ReviewRun
    |> Ash.Query.filter(
      request.repository_id == ^request.repository_id and
        request.pull_number == ^request.pull_number and id != ^context.run.id
    )
    |> Ash.read!()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn run, {:ok, known} ->
      case posted_fingerprints(context, run) do
        {:ok, fingerprints} -> {:cont, {:ok, MapSet.union(known, MapSet.new(fingerprints))}}
        error -> {:halt, error}
      end
    end)
  end

  defp posted_fingerprints(_context, %{summary: %{"posting" => %{"review_id" => _} = posting}}),
    do: {:ok, posting["fingerprints"]}

  defp posted_fingerprints(context, %{summary: %{"posting" => posting}} = run) do
    case find(context, run.id) do
      {:ok, nil} ->
        if retryable_run?(run), do: {:error, :unresolved_posting}, else: {:ok, []}

      {:ok, _review_id} ->
        {:ok, posting["fingerprints"]}

      error ->
        error
    end
  end

  defp posted_fingerprints(_context, _run), do: {:ok, []}

  # An explicit paid rerun abandons the previous intent. The PR lock ensures
  # its old HTTP call has ended before we reconcile it; if it did succeed,
  # the marker lookup above still deduplicates its findings.
  defp retryable_run?(run) do
    request = Ash.get!(ReviewRequest, run.request_id)

    latest =
      ReviewRun
      |> Ash.Query.filter(request_id == ^run.request_id)
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!()

    latest.id == run.id and
      (request.status == :reviewed or
         (request.status == :failed and request.error == Store.posting_error()))
  end

  # GitHub's files endpoint describes the current PR, not an arbitrary head.
  # Both reads must agree with the reviewed base/head. Missing/truncated
  # patches or files beyond the forge's cap naturally fall back to the body.
  defp diff_files(context) do
    with {:ok, before} <- call(context, :pull_request, []),
         true <- same_revision?(before, context.request),
         {:ok, files} <- call(context, :pull_request_files, []),
         {:ok, after_read} <- call(context, :pull_request, []) do
      {:ok, if(same_revision?(after_read, context.request), do: files, else: [])}
    else
      false -> {:ok, []}
      error -> error
    end
  end

  defp same_revision?(pull, request),
    do: pull.head_sha == request.head_sha and pull.base_sha == request.base_sha

  defp find_or_post(context, payload) do
    case find(context, context.run.id) do
      {:ok, nil} -> submit(context, payload)
      result -> result
    end
  end

  defp submit(context, payload) do
    # A rerun or a newer executing attempt may have taken over during reads.
    with {:ok, snapshot} <- Store.posting_snapshot(context.request.id, context.job),
         {:ok, fresh} <- context(snapshot, context.job, forge: context.forge) do
      call(fresh, :post_review, [
        context.request.head_sha,
        payload["body"],
        Enum.map(payload["comments"], &comment/1)
      ])
    end
  end

  defp comment(stored) do
    result = %{
      path: stored["path"],
      side: if(stored["side"] == "old", do: :old, else: :new),
      line: stored["line"],
      body: stored["body"]
    }

    if stored["start_line"],
      do: Map.put(result, :start_line, stored["start_line"]),
      else: result
  end

  defp comments(_context, _review_id, %{"comments" => []}), do: {:ok, %{}}

  defp comments(context, review_id, payload) do
    with {:ok, comments} <- call(context, :review_comments, [review_id]) do
      ids = Map.new(comments, &{fingerprint(&1.body), &1.id})
      expected = Enum.map(payload["comments"], &fingerprint(&1["body"]))

      if Enum.all?(expected, &(is_binary(&1) and Map.has_key?(ids, &1))),
        do: {:ok, Map.take(ids, expected)},
        else: {:error, :missing_posted_comments}
    end
  end

  # Only the formatter's first-line marker counts, not quoted model text or
  # replies containing someone else's marker.
  defp fingerprint(body) do
    case Regex.run(~r/\A<!-- tackle-finding:([0-9a-f]{16,64}) -->\n/, body) do
      [_, fingerprint] -> fingerprint
      _none -> nil
    end
  end

  defp find(context, run_id),
    do: call(context, :find_review, ["<!-- tackle-review:#{run_id} -->"])

  defp call(context, function, args) do
    apply(context.forge, function, [
      context.app,
      context.installation,
      context.repository,
      context.request.pull_number | args
    ])
  end
end
