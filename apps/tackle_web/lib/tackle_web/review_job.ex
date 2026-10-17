defmodule Tackle.Web.ReviewJob do
  @moduledoc """
  Runs a claimed Oban attempt through the review pipeline to `:reviewed`,
  then posts the stored review. Posting happens after the review's checkout,
  jail, and agents are torn down, from the freshly read request. An attempt
  that claims an already `:reviewed` request only posts: no checkout, models,
  or token budget. Duplicate/terminal attempts return without Git, model, or
  forge calls. All database locks are short-lived.

  A failed posting keeps the request `:reviewed` for the job's next attempt;
  the final one fails with `Tackle.Web.ReviewJob.Store.posting_error/0`.

  `run/1` takes `%{request_id: uuid, job: %Oban.Job{}}`. Optional `:opts` are
  trusted host test seams (`:models`, called as `enabled_providers(owner_id)`
  and `resolve_settings(owner_id, settings, profile)`; `:checkout`,
  `:checkout_opts`, `:jail`, `:llm_opts`, `:posting`), never request
  parameters or application-configurable local executor fallbacks. `:posting` defaults to
  `Tackle.Web.Posting` and is called as `post(request, repository, job, opts)`,
  returning `:ok` or `{:error, message}` with a fixed, safe message.
  """

  alias Tackle.Review
  alias Tackle.Review.{Change, Rules, Stages}
  alias Tackle.Review.Tools.{ReportFindings, ReportVerdict}
  alias Tackle.Runtime.{AgentSpec, ScopeSpec}
  alias Tackle.Tools.{Bash, Read}
  alias Tackle.Web.{AgentBackend, Feedback, Models, Posting}
  alias Tackle.Web.Forges.Installation
  alias Tackle.Web.ReviewJob.{Lifecycle, Store}
  alias Tackle.Web.Reviews.ReviewRequest

  @spec run(map()) :: :ok | {:error, String.t()}
  def run(%{request_id: id, job: %Oban.Job{} = job} = input) do
    case Store.claim(id, job) do
      {:ok, {:claimed, request, repository}} ->
        opts = Map.get(input, :opts, [])

        case execute(request, repository, job, opts) do
          :ok -> post_reviewed(request.id, repository, job, opts)
          :stale -> :ok
          {:error, message} -> {:error, message}
        end

      {:ok, {:post, request, repository}} ->
        post(request, repository, job, Map.get(input, :opts, []))

      {:ok, :noop} ->
        :ok

      {:error, _reason} ->
        {:error, "could not claim review request"}
    end
  end

  # :ok when this attempt stored the run, :stale when it lost ownership (and
  # must not post), or an error after recording the failed attempt.
  defp execute(request, repository, job, opts) do
    started = System.monotonic_time(:millisecond)
    {:ok, owner} = Lifecycle.start(self(), opts)

    result =
      try do
        with {:ok, result} <- review(owner, request, repository, opts),
             :ok <- Lifecycle.check(owner),
             {:ok, stored} <-
               Store.complete(
                 request.id,
                 job,
                 result,
                 System.monotonic_time(:millisecond) - started
               ) do
          stored
        else
          {:error, reason} -> {:error, failure(reason)}
        end
      rescue
        _error ->
          {:error, "review failed; check checkout, model configuration and provider access"}
      catch
        :exit, _reason -> {:error, "review runtime stopped"}
      after
        Lifecycle.stop(owner)
      end

    case result do
      {:error, message} ->
        Store.attempt_failed(request.id, job, message)
        {:error, message}

      stored ->
        stored
    end
  end

  # The review's resources are stopped by now; post what was stored.
  defp post_reviewed(id, repository, job, opts) do
    case Ash.get(ReviewRequest, id, not_found_error?: false) do
      {:ok, %ReviewRequest{status: :reviewed} = request} -> post(request, repository, job, opts)
      {:ok, _changed} -> :ok
      {:error, _reason} -> {:error, Store.posting_error()}
    end
  end

  defp post(request, repository, job, opts) do
    posting = Keyword.get(opts, :posting, Posting)

    result =
      try do
        case posting.post(request, repository, job, opts) do
          :ok -> :ok
          {:error, message} when is_binary(message) -> {:error, message}
          _other -> {:error, Store.posting_error()}
        end
      rescue
        _error -> {:error, Store.posting_error()}
      catch
        :exit, _reason -> {:error, Store.posting_error()}
      end

    with {:error, message} <- result do
      Store.attempt_failed(request.id, job, message)
      {:error, message}
    end
  end

  defp review(owner, request, repository, opts) do
    models = Keyword.get(opts, :models, Models)

    # The installation's owner pays: their providers and review defaults
    # (docs/TACKLE_WEB_PLAN.md §7.12).
    with {:ok, %{id: owner_id}} <- Installation.owner(repository.installation),
         {:ok, providers} <- models.enabled_providers(owner_id),
         {:ok, settings} <-
           models.resolve_settings(owner_id, repository.settings, request.profile),
         {:ok, checkout} <- Lifecycle.prepare(owner, request),
         {:ok, jail} <- Lifecycle.jail(owner, checkout),
         {:ok, change} <-
           Change.load(
             cwd: checkout.worktree,
             workspace: checkout.state_dir,
             range: "#{request.base_sha}...#{request.head_sha}"
           ),
         {:ok, files} <- Rules.read_tree(checkout.worktree, request.base_sha),
         discovery =
           Rules.load([{:project, files}], builtin_rules: settings.default_rules || :all),
         {:ok, spec} <- scope_spec({owner_id, providers}, settings, checkout, jail, opts),
         {:ok, scope} <- Lifecycle.scope(owner, spec) do
      Review.run(change,
        requester: scope.root_agent_ref,
        profiles: spec.profiles,
        rules: discovery.rules,
        settings: settings,
        profile: request.profile,
        # Findings dismissed in the repository are not reported again (§7.13).
        known_fingerprints: Feedback.dismissed_fingerprints(repository.id),
        warnings: Enum.map(discovery.warnings, &warning/1)
      )
    end
  end

  defp scope_spec({owner_id, providers}, settings, checkout, jail, opts) do
    context = %{cwd: checkout.worktree, executor: jail.executor}

    common = [
      providers: providers,
      owner_id: owner_id,
      context: context,
      llm_opts: Keyword.get(opts, :llm_opts, [])
    ]

    with {:ok, root} <-
           agent("root", settings.models.verifier, common,
             system_prompt: "Review coordinator; never run a turn.",
             allow_delegation: true
           ),
         {:ok, detector} <- stage(Stages.detector(), :detector, settings, common, ReportFindings),
         {:ok, verifier} <- stage(Stages.verifier(), :verifier, settings, common, ReportVerdict) do
      ScopeSpec.new(
        backend: AgentBackend,
        root_spec: root,
        profiles: %{detector.name => detector, verifier.name => verifier}
      )
    end
  end

  defp stage(stage, key, settings, common, report) do
    agent(stage.name, Map.fetch!(settings.models, key), common,
      system_prompt: stage.prompt,
      tools: [Read, Bash, report],
      thinking: Map.get(settings.thinking, key),
      max_steps: Map.get(settings.max_steps, key, stage.max_steps)
    )
  end

  defp agent(name, model, common, opts) do
    {delegation, config_opts} = Keyword.pop(opts, :allow_delegation, false)

    with {:ok, config} <-
           AgentBackend.config(Keyword.merge(common, [model: model] ++ config_opts)) do
      AgentSpec.new(name: name, config: config, allow_delegation: delegation, timeout: 1_200_000)
    end
  end

  defp warning(%{path: nil, message: message}), do: message
  defp warning(%{path: path, message: message}), do: "#{path}: #{message}"

  # Configuration failures must be readable without reflecting credentials,
  # provider response bodies, Git stderr, or arbitrary exceptions into the UI.
  defp failure({:missing_review_models, stages}),
    do: "review models are required for: " <> Enum.map_join(stages, ", ", &Atom.to_string/1)

  defp failure(:installation_has_no_owner),
    do: "the installation has no owner; an admin can set one"

  defp failure(:owner_not_signed_in),
    do: "the installation's owner has not signed in to tackle yet"

  defp failure(:review_runtime_stopped), do: "review runtime stopped"
  defp failure(:review_jail_not_configured), do: "review jail is not configured"
  defp failure({:review_jail_failed, _reason}), do: "review jail verification failed"
  defp failure({:unknown_provider, _provider}), do: "review model provider is not enabled"
  defp failure({:unknown_model, _model}), do: "review model is not available"

  defp failure(_reason),
    do: "review failed; check checkout, model configuration and provider access"
end
