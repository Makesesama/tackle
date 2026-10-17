defmodule Tackle.Web.ReviewLive do
  @moduledoc """
  `/reviews/:id`: one review request of a pull request head, with its
  latest run: the verdict, what it cost, and its findings, those posted on
  the pull request first, with the reactions on their comments. Finding
  text comes from the models and is shown as plain text, never as HTML.

  The installation's owner dismisses a finding here, so that later reviews
  of the repository do not report it again, or restores it
  (`Tackle.Web.Reviews.Dismissal`, docs/TACKLE_WEB_PLAN.md §7.13). The owner
  also retries posting a review whose posting failed, from the stored run
  and without model calls (`Tackle.Web.Posting.retry/1`), and reviews the
  pull request again (`Tackle.Web.ReviewRequestComponent`).

  The page is live (`Tackle.Web.Live`): it follows the request, its latest
  run's findings, the repository's dismissals, and the installation, and
  shows what a review in flight is doing (`Tackle.Web.ReviewProgress`).
  """

  use Phoenix.LiveView

  require Ash.Query

  import Tackle.Web.Live
  import Tackle.Web.UI

  alias Tackle.Web.Forge
  alias Tackle.Web.Forges.Installation
  alias Tackle.Web.{Posting, ReviewProgress, Updates}
  alias Tackle.Web.ReviewJob.Store
  alias Tackle.Web.Reviews.{Dismissal, Finding, ReviewRequest, ReviewRun}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case get(ReviewRequest, id, socket.assigns.current_user) do
      nil ->
        not_found(socket)

      request ->
        {:ok, socket |> assign(:request_id, request.id) |> load()}
    end
  end

  @impl true
  def handle_info({Updates, _topic}, socket), do: {:noreply, changed(socket)}
  def handle_info(:reload, socket), do: with_user(reloading(socket), &load/1)

  def handle_info({ReviewProgress, id, version, progress}, socket),
    do: with_user(socket, &put_progress(&1, id, version, progress))

  @impl true
  def handle_event("dismiss", %{"id" => id}, socket) do
    with_user(socket, fn socket ->
      %{request: request, current_user: user} = socket.assigns

      with %{} = finding <- finding(socket, id),
           {:ok, _dismissal} <-
             Dismissal.dismiss(
               request.repository_id,
               finding.fingerprint,
               %{title: finding.title, pull_number: request.pull_number},
               actor: user
             ) do
        socket |> put_flash(:info, "Dismissed: later reviews will not report it.") |> load()
      else
        _error -> put_flash(socket, :error, "The finding could not be dismissed.")
      end
    end)
  end

  def handle_event("restore", %{"id" => id}, socket) do
    with_user(socket, fn socket ->
      %{request: request, current_user: user} = socket.assigns

      with %{} = finding <- finding(socket, id),
           {:ok, %Dismissal{} = dismissal} <-
             Dismissal.get(request.repository_id, finding.fingerprint, actor: user),
           :ok <- Dismissal.restore(dismissal, actor: user) do
        socket |> put_flash(:info, "Restored: later reviews report it again.") |> load()
      else
        _error -> put_flash(socket, :error, "The finding could not be restored.")
      end
    end)
  end

  def handle_event("retry_posting", _params, socket) do
    with_user(socket, fn socket ->
      %{request: request, current_user: user} = socket.assigns

      with true <- Installation.owned_by?(request.repository.installation, user),
           {:ok, _request} <- Posting.retry(request.id) do
        socket
        |> put_flash(:info, "Posting again, from the stored review; this page updates by itself.")
        |> load()
      else
        _error -> put_flash(socket, :error, "Posting could not be retried.")
      end
    end)
  end

  # Only findings of the run on the page.
  defp finding(socket, id) do
    case socket.assigns.run do
      nil -> nil
      run -> Enum.find(run.findings, &(&1.id == id))
    end
  end

  defp load(socket) do
    user = socket.assigns.current_user

    findings =
      Finding
      |> Ash.Query.sort([:path, :start_line, :end_line])

    runs = ReviewRun |> Ash.Query.sort(inserted_at: :desc) |> Ash.Query.load(findings: findings)

    request =
      ReviewRequest
      |> Ash.Query.filter(id == ^socket.assigns.request_id)
      |> Ash.Query.load(repository: [:installation, :dismissals], runs: runs)
      |> Ash.read_one!(actor: user)

    case request do
      nil ->
        socket
        |> put_flash(:error, "That review is no longer available.")
        |> push_navigate(to: "/repos")

      request ->
        run = List.first(request.runs)

        socket
        |> assign(:page_title, "##{request.pull_number} #{request.repository.name}")
        |> assign(request: request, run: run, earlier_runs: length(request.runs) - 1)
        |> assign(:owner?, Installation.owned_by?(request.repository.installation, user))
        |> assign(:dismissed, Map.new(request.repository.dismissals, &{&1.fingerprint, &1}))
        |> assign(:groups, group_findings(run))
        |> follow(topics(request, run))
        |> track_progress(if in_flight?(request), do: [request.id], else: [])
    end
  end

  defp topics(request, run) do
    [
      Updates.review(request.id),
      Updates.dismissals(request.repository_id),
      Updates.installation(request.repository.installation_id)
    ] ++ if(run, do: [Updates.run(run.id)], else: [])
  end

  # Running, or stored and posting.
  defp in_flight?(request), do: request.status in [:running, :reviewed]

  defp group_findings(nil), do: []

  defp group_findings(run) do
    by_state = Enum.group_by(run.findings, & &1.state)

    [
      {:shown, "Posted on the pull request", Map.get(by_state, :shown, [])},
      {:hidden, "Verified but not posted", Map.get(by_state, :hidden, [])},
      {:rejected, "Rejected by verification", Map.get(by_state, :rejected, [])}
    ]
    |> Enum.reject(fn {_state, _title, findings} -> findings == [] end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title={"##{@request.pull_number} #{@request.title}"}>
      <:subtitle>
        <.link navigate={"/repos/#{@request.repository.id}"}>
          {@request.repository.owner}/{@request.repository.name}
        </.link>
        · <.sha sha={@request.head_sha} /> onto {@request.base_ref}
        <span :if={@request.requested_by}>· requested by {@request.requested_by}</span>
      </:subtitle>
      <:actions>
        <a class="button secondary" href={pull_request_url(@request)} rel="noreferrer">
          Pull request on GitHub
        </a>
      </:actions>
    </.page_header>

    <section class="card summary">
      <div>
        <div class="muted small">Status</div>
        <.status_badge status={@request.status} />
      </div>
      <div :if={@run}>
        <div class="muted small">Verdict</div>
        <.verdict_badge verdict={@run.verdict} />
      </div>
      <div :if={@run}>
        <div class="muted small">Took</div>
        {duration(@run.duration_ms)}
      </div>
      <div :if={@run && tokens(@run)}>
        <div class="muted small">Tokens</div>
        {tokens(@run)}
      </div>
      <div>
        <div class="muted small">Updated</div>
        <.time at={@request.updated_at} />
      </div>
    </section>

    <div :if={@request.error} class={"notice notice-#{@request.status} notice-row"}>
      <span>{@request.error}</span>
      <button
        :if={@owner? and posting_failed?(@request)}
        class="small"
        phx-click="retry_posting"
        phx-disable-with="Retrying…"
        title="Posts the stored review again, without model calls"
      >
        Retry posting
      </button>
    </div>

    <section :if={@owner? and @request.repository.enabled and @request.repository.active} class="card">
      <div class="card-header"><h2>Review again</h2></div>
      <.live_component
        module={Tackle.Web.ReviewRequestComponent}
        id="review-request"
        label="Review again"
        repository={@request.repository}
        pull_number={@request.pull_number}
        current_user={@current_user}
        signed_in_at={@signed_in_at}
      />
    </section>

    <.review_progress
      :if={progress(@progress, @request.id)}
      progress={progress(@progress, @request.id)}
    />

    <.empty :if={!@run && @request.status == :pending}>
      <p>The review is queued; this page updates by itself.</p>
    </.empty>

    <.empty :if={!@run && @request.status == :running && !progress(@progress, @request.id)}>
      <p>The review is running; this page updates by itself.</p>
    </.empty>

    <.empty :if={@run && @run.findings == []}>
      <p>No findings: the review found nothing to report.</p>
    </.empty>

    <section :for={{state, title, findings} <- @groups} class="findings">
      <h2>{title} <span class="muted">({length(findings)})</span></h2>
      <details :for={finding <- findings} class={"finding severity-#{finding.severity}"} open={state == :shown}>
        <summary>
          <span class={"badge severity-#{finding.severity}"}>{finding.severity}</span>
          <span :if={finding.blocking} class="badge verdict-blocking">blocking</span>
          <span :if={@dismissed[finding.fingerprint]} class="badge">dismissed</span>
          <span class="strong">{finding.title}</span>
          <span class="muted small location">{location(finding)}</span>
        </summary>
        <div class="finding-body">
          <p class="text">{finding.body}</p>
          <pre :if={finding.suggestion} class="suggestion">{finding.suggestion}</pre>
          <p :if={finding.evidence} class="muted small text">Why it was rejected: {finding.evidence}</p>
          <div class="finding-meta">
            <p class="muted small">
              {finding.category} · confidence {round(finding.confidence * 100)}%
              <span :if={finding.rule_id}>· rule {finding.rule_id}</span>
              <span :if={finding.reactions_up} title="Reactions on the comment on GitHub">
                · 👍 {finding.reactions_up} 👎 {finding.reactions_down}
              </span>
              <span :if={@dismissed[finding.fingerprint]}>
                · {dismissed_text(@dismissed[finding.fingerprint])}
              </span>
            </p>
            <span :if={@owner? and state != :rejected}>
              <button
                :if={!@dismissed[finding.fingerprint]}
                class="small secondary"
                phx-click="dismiss"
                phx-value-id={finding.id}
                phx-disable-with="Dismissing…"
                title="Later reviews of this repository will not report it"
              >
                Dismiss
              </button>
              <button
                :if={@dismissed[finding.fingerprint]}
                class="small secondary"
                phx-click="restore"
                phx-value-id={finding.id}
                phx-disable-with="Restoring…"
              >
                Restore
              </button>
            </span>
          </div>
        </div>
      </details>
    </section>

    <p :if={@earlier_runs > 0} class="muted small">
      This head was reviewed {@earlier_runs + 1} times; this page shows the latest run.
    </p>
    """
  end

  defp pull_request_url(request) do
    Forge.module(request.repository.installation.forge).pull_request_url(
      request.repository,
      request.pull_number
    )
  end

  defp posting_failed?(request),
    do: request.status == :failed and request.error == Store.posting_error()

  defp dismissed_text(%Dismissal{source: :forge, by: by}),
    do: "dismissed by #{by} (resolved on GitHub)"

  defp dismissed_text(%Dismissal{by: by}), do: "dismissed by #{by}"

  defp location(%{path: path, start_line: line, end_line: line}), do: "#{path}:#{line}"
  defp location(%{path: path, start_line: first, end_line: last}), do: "#{path}:#{first}–#{last}"

  defp duration(ms) when ms < 1000, do: "#{ms} ms"
  defp duration(ms) when ms < 60_000, do: "#{div(ms, 1000)} s"
  defp duration(ms), do: "#{div(ms, 60_000)} min #{rem(div(ms, 1000), 60)} s"

  defp tokens(%{usage: %{"total_tokens" => total}}) when is_integer(total),
    do: Integer.to_string(total)

  defp tokens(_run), do: nil
end
