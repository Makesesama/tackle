defmodule Tackle.Web.ReviewJob do
  @moduledoc """
  Runs a claimed Oban attempt through the review pipeline, ending at `:reviewed`.
  Posting is deliberately not part of this worker. Duplicate/terminal attempts
  return without Git or model calls. All database locks are short-lived.

  `run/1` takes `%{request_id: uuid, job: %Oban.Job{}}`. Optional `:opts` are
  trusted host test seams (`:models`, `:checkout`, `:checkout_opts`, `:jail`,
  `:llm_opts`), never
  request parameters or application-configurable local executor fallbacks.
  """

  alias Tackle.Review
  alias Tackle.Review.{Change, Rules, Stages}
  alias Tackle.Review.Tools.{ReportFindings, ReportVerdict}
  alias Tackle.Runtime.{AgentSpec, ScopeSpec}
  alias Tackle.Tools.{Bash, Read}
  alias Tackle.Web.{AgentBackend, Models}
  alias Tackle.Web.ReviewJob.{Lifecycle, Store}

  @spec run(map()) :: :ok | {:error, String.t()}
  def run(%{request_id: id, job: %Oban.Job{} = job} = input) do
    case Store.claim(id, job) do
      {:ok, {:claimed, request, repository}} ->
        execute(request, repository, job, Map.get(input, :opts, []))

      {:ok, :noop} ->
        :ok

      {:error, _reason} ->
        {:error, "could not claim review request"}
    end
  end

  defp execute(request, repository, job, opts) do
    started = System.monotonic_time(:millisecond)
    {:ok, owner} = Lifecycle.start(self(), opts)

    result =
      try do
        with {:ok, result} <- review(owner, request, repository, opts),
             :ok <- Lifecycle.check(owner),
             {:ok, _stored} <-
               Store.complete(
                 request.id,
                 job,
                 result,
                 System.monotonic_time(:millisecond) - started
               ) do
          :ok
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

      :ok ->
        :ok
    end
  end

  defp review(owner, request, repository, opts) do
    models = Keyword.get(opts, :models, Models)

    with {:ok, providers} <- models.enabled_providers(),
         {:ok, settings} <- models.resolve_settings(repository.settings, request.profile),
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
         {:ok, spec} <- scope_spec(providers, settings, checkout, jail, opts),
         {:ok, scope} <- Lifecycle.scope(owner, spec) do
      Review.run(change,
        requester: scope.root_agent_ref,
        profiles: spec.profiles,
        rules: discovery.rules,
        settings: settings,
        profile: request.profile,
        known_fingerprints: [],
        warnings: Enum.map(discovery.warnings, &warning/1)
      )
    end
  end

  defp scope_spec(providers, settings, checkout, jail, opts) do
    context = %{cwd: checkout.worktree, executor: jail.executor}
    common = [providers: providers, context: context, llm_opts: Keyword.get(opts, :llm_opts, [])]

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

  defp failure(:review_runtime_stopped), do: "review runtime stopped"
  defp failure(:review_jail_not_configured), do: "review jail is not configured"
  defp failure({:review_jail_failed, _reason}), do: "review jail verification failed"
  defp failure({:unknown_provider, _provider}), do: "review model provider is not enabled"
  defp failure({:unknown_model, _model}), do: "review model is not available"

  defp failure(_reason),
    do: "review failed; check checkout, model configuration and provider access"
end
