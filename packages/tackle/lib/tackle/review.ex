defmodule Tackle.Review do
  @moduledoc """
  Reviews a code change and returns ranked, line-anchored findings.

  `run/2` drives a deterministic pipeline; models only work inside one unit
  or one candidate at a time:

      Units.split ─► Rules.resolve ─► Detector (samples × unit)
        ─► Cluster.merge ─► Filter.deterministic ─► Verifier (per candidate)
        ─► Scorer ─► Rank.select ─► Result ─► History.record_run

  The detector and verifier stages are delegated runs of the
  `review-detector` and `review-verifier` profiles (see
  `Tackle.Agents.Default`), requested from `:requester` through
  `Tackle.Runtime`. The runtime scope therefore supplies concurrency limits
  and cancellation, and the runs appear among the scope's tasks. Profiles
  are trusted specs, normally the scope's own (`ScopeSpec.profiles`), so a
  project's `.tackle/agents/review-detector.md` overrides the built-in
  prompt like any other profile.

  The scorer (`Tackle.Review.Scorer`) recalibrates each verified finding's
  confidence; `Tackle.Review.Rank` applies the profile's thresholds and cap.

  ## History

  With `:history` (a `Tackle.Review.History`), findings whose fingerprints
  have one of the `:skip_outcomes` events recorded are not reported again
  (dropped as `:known`), and the finished run is recorded with its shown and
  rejected findings. History is an aid, not a requirement: when it cannot
  be read or written, the review still runs and `result.summary.warnings`
  says why.

  ## Events

  `:on_event` receives, in the calling process:

    * `{:started, %{units: n}}` - before any model call;
    * `{:unit, id, :started | :done | {:failed, reason}}` - per review unit;
    * `{:candidate, finding}` - a merged, filtered finding sent to the
      verifier;
    * `{:verdict, fingerprint, :confirmed | :rejected | :uncertain}` - per
      candidate; a failed verification counts as `:uncertain`;
    * `{:done, result}` or `{:error, reason}` - last.

  The callback must not raise.

  ## Cancellation

  Cancel the `:cancellation` signal (`Tackle.Lib.Cancellation`), or cancel
  the requester's branch or scope, and `run/2` returns `{:error, :cancelled}`
  after stopping the runs still in flight. Killing the calling process
  cancels them as well.
  """

  alias Tackle.{Auth, Config, Executor}
  alias Tackle.Lib.{Cancellation, Usage}

  alias Tackle.Review.{
    Change,
    Cluster,
    Delegation,
    Detector,
    Filter,
    Finding,
    History,
    Locations,
    Pool,
    Rank,
    Result,
    Rules,
    Scorer,
    Units,
    Verifier
  }

  alias Tackle.Review.Rules.Rule
  alias Tackle.Runtime.{AgentRef, AgentSpec, Handle}
  alias Tackle.Tools.{ReportFindings, ReportVerdict}

  @option_keys [
    :requester,
    :profiles,
    :rules,
    :profile,
    :samples,
    :max_concurrency,
    :exclude,
    :models,
    :scorer,
    :known_fingerprints,
    :history,
    :skip_outcomes,
    :on_event,
    :cancellation,
    :capacity_wait
  ]
  @stages [:detector, :verifier, :scorer]
  @default_concurrency 2

  @typedoc "A progress event; see the module documentation."
  @type event ::
          {:started, %{units: non_neg_integer()}}
          | {:unit, String.t(), :started | :done | {:failed, term()}}
          | {:candidate, Finding.t()}
          | {:verdict, String.t(), :confirmed | :rejected | :uncertain}
          | {:done, Result.t()}
          | {:error, term()}

  @typedoc """
  Options:

    * `:requester` (required) - the agent the review's runs are delegated
      from: a `Tackle.Runtime.Handle` or `Tackle.Runtime.AgentRef` whose
      agent may delegate;
    * `:profiles` (required) - trusted profiles by name, as in
      `Tackle.Runtime.ScopeSpec` (specs or resolver functions); must contain
      `review-detector` with the `report_findings` tool and `review-verifier`
      with the `report_verdict` tool;
    * `:rules` - the rules to apply, of any status (default: discovered with
      `Tackle.Review.Rules.discover/1` from the change's directory, through
      the detector profile's executor);
    * `:profile` - `:quiet`, `:default` (default), or `:assertive`
      (see `Tackle.Review.Rank`);
    * `:samples` - detector runs per unit (default 1);
    * `:max_concurrency` - runs in flight at once (default: the requester
      handle's `max_children_per_agent`, otherwise #{@default_concurrency});
    * `:exclude` - extra globs of files not to review (default `[]`);
    * `:models` - per-stage model references overriding the profiles'
      models, as a map or keyword list with `:detector`, `:verifier`, and
      `:scorer` keys;
    * `:scorer` - a `Tackle.Review.Scorer` module, or `nil` to keep the
      detector's confidence (default `Tackle.Review.Scorer.LLM`). It uses
      the model a verifier run would use, resolved when the review starts:
      the requester's current model and thinking level when the verifier
      profile inherits its model (`model_source: :parent`), otherwise the
      profile's own; then `models[:verifier]`, then `models[:scorer]`;
    * `:known_fingerprints` - fingerprints of findings not to report again,
      such as dismissed ones (default none);
    * `:history` - a `Tackle.Review.History` to skip known findings with
      and to record the run in (default `nil`, no history);
    * `:skip_outcomes` - the history events whose findings are not reported
      again (default `[:dismissed]`); add `:shown` for an incremental review
      that reports only findings not shown before;
    * `:on_event` - `fn event -> any end` (see the module documentation);
    * `:cancellation` - a `Tackle.Lib.Cancellation` signal;
    * `:capacity_wait` - how long a run waits for a free slot, in
      milliseconds (see `Tackle.Review.Delegation`).
  """
  @type option ::
          {:requester, Delegation.requester()}
          | {:profiles, %{optional(String.t()) => AgentSpec.t() | (-> {:ok, AgentSpec.t()})}}
          | {:rules, [Rule.t()]}
          | {:profile, Rank.profile()}
          | {:samples, pos_integer()}
          | {:max_concurrency, pos_integer()}
          | {:exclude, [String.t()]}
          | {:models, map() | keyword()}
          | {:scorer, module() | nil}
          | {:known_fingerprints, Enumerable.t()}
          | {:history, History.t() | nil}
          | {:skip_outcomes, [History.event()]}
          | {:on_event, (event() -> any())}
          | {:cancellation, Cancellation.signal() | nil}
          | {:capacity_wait, non_neg_integer()}

  @doc """
  Reviews a change (see the module documentation).

  Returns `{:ok, result}` even when some units or verifications failed;
  `result.summary` lists them. Returns `{:error, reason}` for invalid
  options, a requester whose model the scorer cannot inherit
  (`{:requester_model_unavailable, reason}`), an invalid `:exclude` glob,
  cancellation (`:cancelled`), or when every unit failed
  (`{:detection_failed, failures}`).
  """
  @spec run(Change.t(), [option()]) :: {:ok, Result.t()} | {:error, term()}
  def run(%Change{} = change, opts) when is_list(opts) do
    with {:ok, ctx} <- prepare(opts) do
      case review(change, history_known(ctx)) do
        {:ok, result, rules} ->
          result = record(result, change, rules, ctx)
          emit(ctx, {:done, result})
          {:ok, result}

        {:error, reason} ->
          emit(ctx, {:error, reason})
          {:error, reason}
      end
    end
  end

  ## Options

  defp prepare(opts) do
    with :ok <- known_options(opts),
         {:ok, requester} <- requester(Keyword.get(opts, :requester)),
         {:ok, profiles} <- fetch_option(opts, :profiles, &is_map/1),
         {:ok, detector} <- stage_spec(profiles, Detector.profile(), ReportFindings),
         {:ok, verifier} <- stage_spec(profiles, Verifier.profile(), ReportVerdict),
         {:ok, profile} <- option(opts, :profile, :default, &(&1 in Rank.profiles())),
         {:ok, samples} <- option(opts, :samples, 1, &positive_integer?/1),
         {:ok, concurrency} <-
           option(opts, :max_concurrency, default_concurrency(requester), &positive_integer?/1),
         {:ok, exclude} <- option(opts, :exclude, [], &string_list?/1),
         {:ok, models} <- models(Keyword.get(opts, :models, %{})),
         {:ok, scorer} <-
           scorer(Keyword.get(opts, :scorer, Scorer.LLM), requester, verifier, models),
         {:ok, rules} <- option(opts, :rules, nil, &rule_list?/1),
         {:ok, known} <- option(opts, :known_fingerprints, [], &Enumerable.impl_for/1),
         {:ok, history} <- option(opts, :history, nil, &(is_nil(&1) or is_struct(&1, History))),
         {:ok, skip_outcomes} <- option(opts, :skip_outcomes, [:dismissed], &events?/1),
         {:ok, on_event} <- option(opts, :on_event, fn _event -> :ok end, &is_function(&1, 1)),
         {:ok, signal} <-
           option(opts, :cancellation, nil, &(is_nil(&1) or is_struct(&1, Cancellation.Signal))),
         {:ok, capacity_wait} <-
           option(opts, :capacity_wait, nil, &(is_nil(&1) or non_negative_integer?(&1))) do
      {:ok,
       %{
         requester: requester,
         detector: detector,
         verifier: verifier,
         profile: profile,
         samples: samples,
         concurrency: concurrency,
         exclude: exclude,
         models: models,
         scorer: scorer,
         rules: rules,
         known: MapSet.new(known),
         history: history,
         skip_outcomes: skip_outcomes,
         warnings: [],
         on_event: on_event,
         signal: signal,
         run_opts: if(capacity_wait, do: [capacity_wait: capacity_wait], else: [])
       }}
    end
  end

  defp known_options(opts) do
    case opts |> Keyword.keys() |> Enum.uniq() |> Kernel.--(@option_keys) do
      [] -> :ok
      unknown -> {:error, {:unknown_options, unknown}}
    end
  end

  defp requester(%Handle{} = handle), do: {:ok, handle}
  defp requester(%AgentRef{} = agent_ref), do: {:ok, agent_ref}
  defp requester(nil), do: {:error, {:missing_option, :requester}}
  defp requester(other), do: {:error, {:invalid_option, :requester, other}}

  defp fetch_option(opts, key, valid?) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> validate(key, value, valid?)
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp option(opts, key, default, valid?) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> validate(key, value, valid?)
      :error -> {:ok, default}
    end
  end

  defp validate(key, value, valid?) do
    if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_option, key, value}}
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)
  defp events?(value), do: is_list(value) and Enum.all?(value, &(&1 in History.events()))

  defp rule_list?(value),
    do: is_nil(value) or (is_list(value) and Enum.all?(value, &is_struct(&1, Rule)))

  defp default_concurrency(%Handle{limits: %{max_children_per_agent: max}}) when max > 0, do: max
  defp default_concurrency(_requester), do: @default_concurrency

  defp stage_spec(profiles, name, tool) do
    with {:ok, spec} <- resolve_profile(profiles, name) do
      check_stage_tool(spec, name, tool)
    end
  end

  defp check_stage_tool(%AgentSpec{config: %Config{tools: tools}} = spec, name, tool) do
    if tool in tools,
      do: {:ok, spec},
      else: {:error, {:missing_tool, name, tool.name()}}
  end

  defp check_stage_tool(_spec, name, _tool), do: {:error, {:unsupported_agent_config, name}}

  defp resolve_profile(profiles, name) do
    case Map.get(profiles, name) do
      %AgentSpec{} = spec ->
        {:ok, spec}

      resolver when is_function(resolver, 0) ->
        case resolver.() do
          {:ok, %AgentSpec{} = spec} -> {:ok, spec}
          other -> {:error, {:invalid_profile, name, other}}
        end

      nil ->
        {:error, {:missing_profile, name}}

      other ->
        {:error, {:invalid_profile, name, other}}
    end
  end

  defp models(models) when is_list(models) or is_map(models) do
    if Enum.all?(models, &valid_model?/1),
      do: {:ok, Map.new(models)},
      else: {:error, {:invalid_option, :models, models}}
  end

  defp models(models), do: {:error, {:invalid_option, :models, models}}

  defp valid_model?({stage, model}),
    do: stage in @stages and (is_nil(model) or (is_binary(model) and model != ""))

  defp valid_model?(_entry), do: false

  defp scorer(nil, _requester, _verifier, _models), do: {:ok, nil}

  defp scorer(module, requester, verifier, models) when is_atom(module) do
    with :ok <- ensure_scorer(module),
         {:ok, config} <- Delegation.base_config(requester, verifier),
         {:ok, config} <- select_model(config, :verifier, models[:verifier]),
         {:ok, config} <- select_model(config, :scorer, models[:scorer]) do
      llm_opts = Keyword.put(config.llm_opts, :credential_store, Auth.credential_store())
      {:ok, %{module: module, llm: config.llm, llm_opts: llm_opts}}
    end
  end

  defp scorer(other, _requester, _verifier, _models),
    do: {:error, {:invalid_option, :scorer, other}}

  defp ensure_scorer(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :score, 2),
      do: :ok,
      else: {:error, {:invalid_option, :scorer, module}}
  end

  # Applies a per-stage model on top of a stage configuration, as the
  # runtime applies a run's `:model` (the profile's thinking level is kept).
  defp select_model(config, _stage, nil), do: {:ok, config}

  defp select_model(config, stage, model) do
    case Config.reconfigure(config, model: model) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, {:invalid_option, :models, {stage, model, reason}}}
    end
  end

  ## Pipeline

  defp review(change, ctx) do
    with {:ok, split} <- Units.split(change, exclude: ctx.exclude) do
      code_units = Enum.filter(split.units, &(&1.kind == :code))
      # The change-level unit alone has no lines a finding could point at.
      units = if code_units == [], do: [], else: split.units
      emit(ctx, {:started, %{units: length(units)}})

      state = %{
        change: change,
        units: units,
        code_units: code_units,
        skipped: split.skipped,
        index: Locations.index(code_units),
        warnings: ctx.warnings,
        usages: []
      }

      if units == [],
        do: {:ok, result(empty_outcome(), state, ctx), []},
        else: pipeline(state, ctx)
    end
  end

  defp pipeline(state, ctx) do
    {rules, warnings} = rules(state.change, ctx)
    state = %{state | warnings: state.warnings ++ warnings}

    with {:ok, detection, state} <- detect(state, rules, ctx),
         {candidates, filtered} <- candidates(detection.groups, state, rules, ctx),
         {:ok, verification, state} <- verify(candidates, state, rules, ctx),
         {:ok, scoring, state} <- score(verification.verified, state, rules, ctx) do
      selection = Rank.select(scoring.scored, ctx.profile, samples: ctx.samples)

      outcome = %{
        selection: selection,
        filtered: filtered,
        rejected: verification.rejected,
        failed_units: detection.failed,
        detected: detection.detected,
        candidates: length(candidates),
        verified: verification.verified,
        verification_failures: verification.failures,
        scoring_failures: scoring.failures
      }

      {:ok, result(outcome, state, ctx), rules}
    end
  end

  defp rules(change, ctx) do
    case ctx.rules do
      nil ->
        executor = Executor.from_context(ctx.detector.config.context)
        discovery = Rules.discover(cwd: change.cwd, executor: executor)
        {discovery.rules, Enum.map(discovery.warnings, &format_warning/1)}

      rules ->
        {rules, []}
    end
  end

  defp format_warning(%{path: nil, message: message}), do: message
  defp format_warning(%{path: path, message: message}), do: "#{path}: #{message}"

  ## Detection

  defp detect(state, rules, ctx) do
    paths = Enum.map(state.change.diff.files, & &1.path)

    jobs =
      Enum.map(state.units, fn unit ->
        resolution = Rules.resolve(rules, unit, paths: paths)
        {unit, resolution}
      end)

    warnings =
      jobs
      |> Enum.flat_map(fn {_unit, resolution} -> resolution.warnings end)
      |> Enum.map(&format_warning/1)
      |> Enum.uniq()

    run = fn {unit, resolution} ->
      Detector.run(
        unit,
        [
          requester: ctx.requester,
          spec: ctx.detector,
          rules: resolution.rules,
          allowed: Locations.for_unit(unit, state.index),
          index: state.index,
          samples: ctx.samples,
          model: ctx.models[:detector]
        ] ++ ctx.run_opts
      )
    end

    pool_opts = [
      cancellation: ctx.signal,
      cancelled?: &match?({:error, :cancelled}, &1),
      on_start: fn {unit, _resolution} -> emit(ctx, {:unit, unit.id, :started}) end,
      on_result: fn {unit, _resolution}, result -> emit(ctx, unit_event(unit, result)) end
    ]

    with {:ok, results} <- Pool.map(jobs, ctx.concurrency, run, pool_opts) do
      detection(jobs, results, %{state | warnings: state.warnings ++ warnings})
    end
  end

  defp unit_event(unit, {:ok, _result}), do: {:unit, unit.id, :done}
  defp unit_event(unit, {:error, reason}), do: {:unit, unit.id, {:failed, reason}}

  defp detection(jobs, results, state) do
    outcomes = Enum.zip_with(jobs, results, fn {unit, _resolution}, result -> {unit, result} end)
    failed = for {unit, {:error, reason}} <- outcomes, do: %{unit: unit.id, reason: reason}

    if length(failed) == length(outcomes) do
      {:error, {:detection_failed, failed}}
    else
      lines = lines_by_path(state.code_units)
      successes = for {_unit, {:ok, result}} <- outcomes, do: result

      groups =
        for result <- successes,
            findings <- result.samples,
            do: Enum.map(findings, &fingerprint(&1, lines))

      state = %{state | usages: state.usages ++ Enum.map(successes, & &1.usage)}
      detected = groups |> Enum.map(&length/1) |> Enum.sum()

      {:ok, %{groups: groups, failed: failed, detected: detected}, state}
    end
  end

  # The lines of every code unit by path, so a finding's fingerprint does not
  # depend on which unit reported it.
  defp lines_by_path(code_units) do
    code_units
    |> Enum.group_by(& &1.path, & &1.lines)
    |> Map.new(fn {path, lines} ->
      {path, lines |> Enum.concat() |> Enum.uniq_by(&{&1.kind, &1.old, &1.new})}
    end)
  end

  defp fingerprint(finding, lines) do
    excerpt = Finding.excerpt(Map.get(lines, finding.location.path, []), finding.location)
    Finding.put_fingerprint(finding, excerpt)
  end

  defp candidates(groups, state, rules, ctx) do
    {candidates, dropped} =
      groups
      |> Cluster.merge()
      |> Filter.deterministic(changed: state.index, rules: rules, known_fingerprints: ctx.known)

    Enum.each(candidates, &emit(ctx, {:candidate, &1}))
    {candidates, dropped}
  end

  ## Verification

  defp verify(candidates, state, rules, ctx) do
    rules_by_id = Map.new(rules, &{&1.id, &1})

    run = fn finding ->
      Verifier.run(
        finding,
        home_unit(finding, state),
        [
          requester: ctx.requester,
          spec: ctx.verifier,
          rule: Map.get(rules_by_id, finding.rule_id),
          model: ctx.models[:verifier]
        ] ++ ctx.run_opts
      )
    end

    pool_opts = [
      cancellation: ctx.signal,
      cancelled?: &match?({:error, :cancelled}, &1),
      on_result: fn
        _finding, {:error, :cancelled} -> :ok
        finding, result -> emit(ctx, {:verdict, finding.fingerprint, applied_verdict(result)})
      end
    ]

    with {:ok, results} <- Pool.map(candidates, ctx.concurrency, run, pool_opts) do
      acc = %{verified: [], rejected: [], failures: [], usages: []}

      acc =
        candidates
        |> Enum.zip(results)
        |> Enum.reduce(acc, &add_verdict/2)

      verification = %{
        verified: Enum.reverse(acc.verified),
        rejected: Enum.reverse(acc.rejected),
        failures: Enum.reverse(acc.failures)
      }

      {:ok, verification, %{state | usages: state.usages ++ Enum.reverse(acc.usages)}}
    end
  end

  defp applied_verdict({:ok, %{verdict: verdict}}), do: verdict
  defp applied_verdict({:error, _reason}), do: :uncertain

  defp add_verdict({finding, {:ok, %{verdict: :rejected} = report}}, acc) do
    %{
      acc
      | rejected: [%{finding: finding, evidence: report.evidence} | acc.rejected],
        usages: [report.usage | acc.usages]
    }
  end

  defp add_verdict({finding, {:ok, report}}, acc) do
    %{
      acc
      | verified: [%{finding | verdict: report.verdict} | acc.verified],
        usages: [report.usage | acc.usages]
    }
  end

  defp add_verdict({finding, {:error, reason}}, acc) do
    %{
      acc
      | verified: [%{finding | verdict: :uncertain} | acc.verified],
        failures: [%{fingerprint: finding.fingerprint, reason: reason} | acc.failures]
    }
  end

  # The code unit showing the finding's changed lines.
  defp home_unit(finding, state) do
    location = finding.location

    Enum.find(state.code_units, fn unit ->
      unit.path == location.path and
        Locations.changed?(location, Locations.for_unit(unit, state.index))
    end) || Enum.find(state.code_units, &(&1.path == location.path)) || hd(state.units)
  end

  ## Scoring

  defp score(findings, state, _rules, %{scorer: nil}),
    do: {:ok, %{scored: findings, failures: []}, state}

  defp score(findings, state, rules, ctx) do
    rules_by_id = Map.new(rules, &{&1.id, &1})

    run = fn finding ->
      context = %{
        unit: home_unit(finding, state),
        rule: Map.get(rules_by_id, finding.rule_id),
        llm: ctx.scorer.llm,
        llm_opts: ctx.scorer.llm_opts
      }

      Scorer.score(ctx.scorer.module, finding, context)
    end

    with {:ok, results} <-
           Pool.map(findings, ctx.concurrency, run, cancellation: ctx.signal) do
      {scored, failures, usages} =
        findings
        |> Enum.zip(results)
        |> Enum.reduce({[], [], []}, fn
          {finding, {:ok, confidence, usage}}, {scored, failures, usages} ->
            {[%{finding | confidence: confidence} | scored], failures, [usage | usages]}

          {finding, {:error, reason}}, {scored, failures, usages} ->
            failure = %{fingerprint: finding.fingerprint, reason: reason}
            {[finding | scored], [failure | failures], usages}
        end)

      {:ok, %{scored: Enum.reverse(scored), failures: Enum.reverse(failures)},
       %{state | usages: state.usages ++ Enum.reverse(usages)}}
    end
  end

  ## History

  defp history_known(%{history: nil} = ctx), do: ctx

  defp history_known(%{history: history} = ctx) do
    case History.fingerprints(history, ctx.skip_outcomes) do
      {:ok, fingerprints} ->
        %{ctx | known: MapSet.union(ctx.known, fingerprints)}

      {:error, reason} ->
        warning = "review history could not be read: #{History.format_error(reason)}"
        %{ctx | warnings: append_warning(ctx.warnings, warning)}
    end
  end

  defp record(result, _change, _rules, %{history: nil}), do: result

  defp record(result, change, rules, ctx) do
    prompts = %{
      ctx.detector.name => ctx.detector.config.system_prompt,
      ctx.verifier.name => ctx.verifier.config.system_prompt
    }

    case History.record_run(ctx.history, change, result, rules: rules, prompts: prompts) do
      {:ok, _run_id} ->
        result

      {:error, reason} ->
        warning = "review history could not be written: #{History.format_error(reason)}"
        update_in(result.summary.warnings, &append_warning(&1, warning))
    end
  end

  defp append_warning(warnings, warning), do: Enum.reverse([warning | Enum.reverse(warnings)])

  ## Result

  defp empty_outcome do
    %{
      selection: %{blocking: [], optional: [], dropped: []},
      filtered: [],
      rejected: [],
      failed_units: [],
      detected: 0,
      candidates: 0,
      verified: [],
      verification_failures: [],
      scoring_failures: []
    }
  end

  defp result(outcome, state, ctx) do
    %{blocking: blocking, optional: optional} = outcome.selection

    dropped =
      Enum.map(outcome.filtered ++ outcome.selection.dropped, fn {finding, reason} ->
        %{finding: finding, reason: reason}
      end)

    summary = %{
      profile: ctx.profile,
      samples: ctx.samples,
      units: length(state.units),
      files: state.code_units |> Enum.map(& &1.path) |> Enum.uniq(),
      skipped: state.skipped,
      failed_units: outcome.failed_units,
      detected: outcome.detected,
      candidates: outcome.candidates,
      confirmed: Enum.count(outcome.verified, &(&1.verdict == :confirmed)),
      uncertain: Enum.count(outcome.verified, &(&1.verdict == :uncertain)),
      rejected: length(outcome.rejected),
      verification_failures: outcome.verification_failures,
      scoring_failures: outcome.scoring_failures,
      blocking: length(blocking),
      optional: length(optional),
      verdict: Result.verdict(blocking, optional),
      warnings: state.warnings
    }

    %Result{
      blocking: blocking,
      optional: optional,
      rejected: outcome.rejected,
      dropped: dropped,
      summary: summary,
      usage: Usage.aggregate(state.usages)
    }
  end

  defp emit(ctx, event), do: ctx.on_event.(event)
end
