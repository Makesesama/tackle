defmodule Tackle.Web.ReviewLive do
  @moduledoc """
  `/reviews/:id`: one review request of a pull request head, with its
  latest run: the verdict, what it cost, and its findings, those posted on
  the pull request first. Finding text comes from the models and is shown
  as plain text, never as HTML.
  """

  use Phoenix.LiveView

  require Ash.Query

  import Tackle.Web.Live
  import Tackle.Web.UI

  alias Tackle.Web.Forge
  alias Tackle.Web.Reviews.{Finding, ReviewRequest, ReviewRun}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case get(ReviewRequest, id, socket.assigns.current_user) do
      nil ->
        not_found(socket)

      request ->
        socket = socket |> assign(:request_id, request.id) |> load()
        {:ok, if(in_flight?(socket), do: schedule_refresh(socket), else: socket)}
    end
  end

  # Only a review in flight refreshes; a finished one does not change.
  @impl true
  def handle_info(:refresh, socket) do
    with_user(socket, fn socket ->
      socket = load(socket)
      if in_flight?(socket), do: schedule_refresh(socket), else: socket
    end)
  end

  defp in_flight?(%{assigns: %{request: %{status: status}}}),
    do: status in [:pending, :running, :reviewed]

  defp in_flight?(_socket), do: false

  defp load(socket) do
    user = socket.assigns.current_user

    findings =
      Finding
      |> Ash.Query.sort([:path, :start_line, :end_line])

    runs = ReviewRun |> Ash.Query.sort(inserted_at: :desc) |> Ash.Query.load(findings: findings)

    request =
      ReviewRequest
      |> Ash.Query.filter(id == ^socket.assigns.request_id)
      |> Ash.Query.load(repository: [:installation], runs: runs)
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
        |> assign(:groups, group_findings(run))
    end
  end

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
        <a href={"/repos/#{@request.repository.id}"}>
          {@request.repository.owner}/{@request.repository.name}
        </a>
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

    <p :if={@request.error} class={"notice notice-#{@request.status}"}>{@request.error}</p>

    <.empty :if={!@run && @request.status in [:pending, :running]}>
      <p>The review is {if @request.status == :pending, do: "queued", else: "running"}; this page updates by itself.</p>
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
          <span class="strong">{finding.title}</span>
          <span class="muted small location">{location(finding)}</span>
        </summary>
        <div class="finding-body">
          <p class="text">{finding.body}</p>
          <pre :if={finding.suggestion} class="suggestion">{finding.suggestion}</pre>
          <p :if={finding.evidence} class="muted small text">Why it was rejected: {finding.evidence}</p>
          <p class="muted small">
            {finding.category} · confidence {round(finding.confidence * 100)}%
            <span :if={finding.rule_id}>· rule {finding.rule_id}</span>
          </p>
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

  defp location(%{path: path, start_line: line, end_line: line}), do: "#{path}:#{line}"
  defp location(%{path: path, start_line: first, end_line: last}), do: "#{path}:#{first}–#{last}"

  defp duration(ms) when ms < 1000, do: "#{ms} ms"
  defp duration(ms) when ms < 60_000, do: "#{div(ms, 1000)} s"
  defp duration(ms), do: "#{div(ms, 60_000)} min #{rem(div(ms, 1000), 60)} s"

  defp tokens(%{usage: %{"total_tokens" => total}}) when is_integer(total),
    do: Integer.to_string(total)

  defp tokens(_run), do: nil
end
