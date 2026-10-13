defmodule Tackle.Review do
  @moduledoc """
  Reviews a code change and returns ranked, line-anchored findings.

  `run/2` drives a deterministic pipeline; models only work inside one
  batch of units or of candidates at a time:

      Units.split ─► Units.batch ─► Rules.resolve ─► Detector (samples × batch)
        ─► Cluster.merge ─► Filter.deterministic ─► Rank.preselect
        ─► Verifier (per batch of a unit's candidates) ─► Scorer (per batch)
        ─► Rank.select ─► Result ─► History.record_run

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

  ## Cost and quality

  Every detector and verifier batch is a delegated agent run, the main
  cost of a review. The options `:units`, `:verify_batch`, `:verify_limit`,
  `:score_batch`, and `:thinking` trade quality for cost, and
  `result.summary.stages` reports each stage's runs, token usage (including
  cached tokens), and wall time, so settings can be compared.

  The stage configurations are resolved once, when the review starts: a
  profile that inherits its model (`model_source: :parent`) gets the
  requester's current model and thinking level, then `:models` and
  `:thinking` apply. With `:shared_cache_key` (default `true`), all runs of
  a stage share one prompt cache key (the `:prompt_cache_key` LLM option),
  so providers that route cached prompts by key can reuse the stage's common
  prompt prefix across runs.

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
    :thinking,
    :units,
    :verify_batch,
    :verify_limit,
    :score_batch,
    :shared_cache_key,
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
  @default_verify_batch 4
  @default_score_batch 10

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
    * `:samples` - detector runs per batch of units (default 1);
    * `:max_concurrency` - runs in flight at once (default: the requester
      handle's `max_children_per_agent`, otherwise #{@default_concurrency});
    * `:exclude` - extra globs of files not to review (default `[]`);
    * `:models` - per-stage model references overriding the profiles'
      models, as a map or keyword list with `:detector`, `:verifier`, and
      `:scorer` keys;
    * `:thinking` - per-stage thinking levels (`Tackle.Thinking.levels/0`)
      overriding the profiles' or inherited ones, with the same keys; the
      scorer otherwise uses the verifier's;
    * `:units` - unit sizing: the sizing options of
      `Tackle.Review.Units.split/2` (`:max_changed_lines`, default
      #{Keyword.fetch!(Units.defaults(), :max_changed_lines)}, `:context_ratio`, `:min_context`,
      `:fallback_context`) and `:pack_files` (default `true`), which reviews
      small units of several files in one detector run of at most
      `:max_changed_lines` changed lines (`Tackle.Review.Units.batch/2`);
    * `:verify_batch` - candidates of one unit verified per verifier run
      (default #{@default_verify_batch}; 1 verifies each alone);
    * `:verify_limit` - how many candidates at most are verified, the best
      by detector confidence (default: `Tackle.Review.Rank.verify_limit/1`
      of the profile);
    * `:score_batch` - findings scored per scorer call (default
      #{@default_score_batch});
    * `:shared_cache_key` - share one prompt cache key per stage across the
      review's runs (default `true`);
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
          | {:thinking, map() | keyword()}
          | {:units, keyword()}
          | {:verify_batch, pos_integer()}
          | {:verify_limit, pos_integer() | nil}
          | {:score_batch, pos_integer()}
          | {:shared_cache_key, boolean()}
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
  options, a requester whose model a stage cannot inherit
  (`{:requester_model_unavailable, reason}`), an invalid `:exclude` glob,
  cancellation (`:cancelled`), or when every unit failed
  (`{:detection_failed, failures}`).
  """
  @spec run(Change.t(), [option()]) :: {:ok, Result.t()} | {:error, term()}
  def run(%Change{} = change, opts) when is_list(opts) do
    started = System.monotonic_time(:millisecond)

    with {:ok, ctx} <- prepare(opts) do
      ctx = Map.put(ctx, :started, started)

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
         {:ok, thinking} <- thinking(Keyword.get(opts, :thinking, %{})),
         {:ok, units} <- units(Keyword.get(opts, :units, [])),
         {:ok, verify_batch} <-
           option(opts, :verify_batch, @default_verify_batch, &positive_integer?/1),
         {:ok, verify_limit} <-
           option(opts, :verify_limit, nil, &(is_nil(&1) or positive_integer?(&1))),
         {:ok, score_batch} <-
           option(opts, :score_batch, @default_score_batch, &positive_integer?/1),
         {:ok, shared_cache_key} <- option(opts, :shared_cache_key, true, &is_boolean/1),
         cache_keys = cache_keys(shared_cache_key),
         {:ok, detector} <-
           pin_stage(requester, detector, :detector, models, thinking, cache_keys),
         {:ok, verifier} <-
           pin_stage(requester, verifier, :verifier, models, thinking, cache_keys),
         {:ok, scorer} <-
           scorer(Keyword.get(opts, :scorer, Scorer.LLM), verifier, models, thinking, cache_keys),
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
         units: units,
         settings:
           settings(units, verify_batch, verify_limit, score_batch, shared_cache_key, [
             {:detector, detector.config},
             {:verifier, verifier.config},
             {:scorer, scorer}
           ]),
         verify_batch: verify_batch,
         verify_limit: verify_limit,
         score_batch: score_batch,
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

  defp thinking(thinking) when is_list(thinking) or is_map(thinking) do
    if Enum.all?(thinking, &valid_thinking?/1),
      do: {:ok, Map.new(thinking)},
      else: {:error, {:invalid_option, :thinking, thinking}}
  end

  defp thinking(thinking), do: {:error, {:invalid_option, :thinking, thinking}}

  defp valid_thinking?({stage, level}),
    do: stage in @stages and (is_nil(level) or level in Tackle.Thinking.levels())

  defp valid_thinking?(_entry), do: false

  defp units(units) when is_list(units) do
    {pack_files, sizing} = Keyword.pop(units, :pack_files, true)

    cond do
      not Keyword.keyword?(units) ->
        {:error, {:invalid_option, :units, units}}

      not is_boolean(pack_files) ->
        {:error, {:invalid_option, :units, {:pack_files, pack_files}}}

      true ->
        case Units.validate_options(sizing) do
          :ok -> {:ok, %{sizing: sizing, pack_files: pack_files}}
          {:error, reason} -> {:error, {:invalid_option, :units, reason}}
        end
    end
  end

  defp units(units), do: {:error, {:invalid_option, :units, units}}

  # One prompt cache key per stage and review, within the 64 characters
  # providers accept.
  defp cache_keys(false), do: %{}

  defp cache_keys(true) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    Map.new(@stages, &{&1, "tackle-review-#{id}-#{&1}"})
  end

  # Resolves a stage's configuration once: the requester's model and
  # thinking level for an inheriting profile, then the per-stage model and
  # thinking level, then the shared cache key. The pinned spec no longer
  # inherits, so every run of the stage uses the same configuration.
  defp pin_stage(requester, spec, stage, models, thinking, cache_keys) do
    with {:ok, config} <- Delegation.base_config(requester, spec),
         {:ok, config} <- select_model(config, stage, models[stage]),
         {:ok, config} <- select_thinking(config, stage, thinking[stage]) do
      config = %{config | llm_opts: put_cache_key(config.llm_opts, cache_keys[stage])}
      {:ok, %{spec | config: config, model_source: :configured}}
    end
  end

  # The settings that decide a review's cost, recorded with its result.
  defp settings(units, verify_batch, verify_limit, score_batch, shared_cache_key, stages) do
    sizing = Keyword.merge(Units.defaults(), units.sizing)

    %{
      max_changed_lines: sizing[:max_changed_lines],
      context_ratio: sizing[:context_ratio],
      min_context: sizing[:min_context],
      fallback_context: sizing[:fallback_context],
      pack_files: units.pack_files,
      verify_batch: verify_batch,
      verify_limit: verify_limit,
      score_batch: score_batch,
      shared_cache_key: shared_cache_key,
      models: Map.new(stages, fn {stage, config} -> {stage, stage_model(config)} end),
      thinking: Map.new(stages, fn {stage, config} -> {stage, stage_thinking(config)} end)
    }
  end

  defp stage_model(%Config{model_ref: model_ref}), do: model_ref
  defp stage_model(%{llm: %{ref: ref}}), do: ref
  defp stage_model(_none), do: nil

  defp stage_thinking(%{llm_opts: llm_opts}), do: Tackle.Thinking.from_llm_opts(llm_opts)
  defp stage_thinking(_none), do: nil

  defp put_cache_key(llm_opts, nil), do: llm_opts
  defp put_cache_key(llm_opts, key), do: Keyword.put(llm_opts, :prompt_cache_key, key)

  defp scorer(nil, _verifier, _models, _thinking, _cache_keys), do: {:ok, nil}

  # The scorer uses the verifier's resolved model and thinking level unless
  # the scorer stage overrides them.
  defp scorer(module, verifier, models, thinking, cache_keys) when is_atom(module) do
    with :ok <- ensure_scorer(module),
         {:ok, config} <- select_model(verifier.config, :scorer, models[:scorer]),
         {:ok, config} <- select_thinking(config, :scorer, thinking[:scorer]) do
      llm_opts =
        config.llm_opts
        |> Keyword.delete(:prompt_cache_key)
        |> put_cache_key(cache_keys[:scorer])
        |> Keyword.put(:credential_store, Auth.credential_store())

      {:ok, %{module: module, llm: config.llm, llm_opts: llm_opts}}
    end
  end

  defp scorer(other, _verifier, _models, _thinking, _cache_keys),
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

  defp select_thinking(config, _stage, nil), do: {:ok, config}

  defp select_thinking(config, stage, level) do
    case Config.reconfigure(config, thinking: level) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, {:invalid_option, :thinking, {stage, level, reason}}}
    end
  end

  ## Pipeline

  defp review(change, ctx) do
    with {:ok, split} <- Units.split(change, [exclude: ctx.exclude] ++ ctx.units.sizing) do
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
        usages: [],
        stages: %{}
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
      state.units
      |> batches(ctx.units)
      |> Enum.map(fn units ->
        resolutions = Enum.map(units, &Rules.resolve(rules, &1, paths: paths))
        {units, resolutions}
      end)

    warnings =
      jobs
      |> Enum.flat_map(fn {_units, resolutions} -> Enum.flat_map(resolutions, & &1.warnings) end)
      |> Enum.map(&format_warning/1)
      |> Enum.uniq()

    run = fn {units, resolutions} ->
      units
      |> Detector.run(
        [
          requester: ctx.requester,
          spec: ctx.detector,
          rules: resolutions |> Enum.flat_map(& &1.rules) |> Enum.uniq_by(& &1.id),
          index: state.index,
          samples: ctx.samples
        ] ++ ctx.run_opts
      )
      |> case do
        {:error, reason} when reason != :cancelled ->
          {:ok, %{samples: [], errors: [reason], runs: 0, usage: nil}}

        result ->
          result
      end
    end

    pool_opts = [
      cancellation: ctx.signal,
      cancelled?: &match?({:error, :cancelled}, &1),
      on_start: fn {units, _resolutions} ->
        Enum.each(units, &emit(ctx, {:unit, &1.id, :started}))
      end,
      on_result: fn {units, _resolutions}, result ->
        Enum.each(units, &emit(ctx, unit_event(&1, result)))
      end
    ]

    with {:ok, results, duration} <-
           timed(fn -> Pool.map(jobs, ctx.concurrency, run, pool_opts) end) do
      detection(jobs, results, duration, %{state | warnings: state.warnings ++ warnings})
    end
  end

  defp batches(units, %{pack_files: false}), do: Enum.map(units, &[&1])

  defp batches(units, %{sizing: sizing}) do
    max =
      Keyword.get(
        sizing,
        :max_changed_lines,
        Keyword.fetch!(Units.defaults(), :max_changed_lines)
      )

    Units.batch(units, max)
  end

  defp unit_event(unit, {:ok, %{samples: [_ | _]}}), do: {:unit, unit.id, :done}
  defp unit_event(unit, {:ok, %{errors: [reason | _]}}), do: {:unit, unit.id, {:failed, reason}}
  defp unit_event(unit, {:error, reason}), do: {:unit, unit.id, {:failed, reason}}

  defp detection(jobs, results, duration, state) do
    outcomes = Enum.zip(jobs, results)

    failed =
      for {{units, _resolutions}, {:ok, %{samples: [], errors: [reason | _]}}} <- outcomes,
          unit <- units,
          do: %{unit: unit.id, reason: reason}

    successes = for {_job, {:ok, %{samples: [_ | _]} = result}} <- outcomes, do: result
    reports = for {_job, {:ok, result}} <- outcomes, do: result

    stats =
      stage_stats(
        Enum.sum_by(reports, & &1.runs),
        Enum.sum_by(reports, &length(&1.errors)),
        Enum.map(reports, & &1.usage),
        duration
      )

    state = put_stage(state, :detector, stats)

    if successes == [] do
      {:error, {:detection_failed, failed}}
    else
      lines = lines_by_path(state.code_units)

      groups =
        for result <- successes,
            findings <- result.samples,
            do: Enum.map(findings, &fingerprint(&1, lines))

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

  # Merged and filtered candidates, minus those the profile could never
  # show; only the kept ones are announced and verified.
  defp candidates(groups, state, rules, ctx) do
    {filtered, dropped} =
      groups
      |> Cluster.merge()
      |> Filter.deterministic(changed: state.index, rules: rules, known_fingerprints: ctx.known)

    {candidates, preselected} =
      Rank.preselect(filtered, ctx.profile, samples: ctx.samples, limit: ctx.verify_limit)

    Enum.each(candidates, &emit(ctx, {:candidate, &1}))
    {candidates, dropped ++ preselected}
  end

  ## Verification

  defp verify(candidates, state, rules, ctx) do
    rules_by_id = Map.new(rules, &{&1.id, &1})

    # Candidates of one unit share the code a verifier reads.
    batches =
      candidates
      |> Enum.group_by(&home_unit(&1, state).id)
      |> Enum.sort_by(fn {_id, [first | _]} -> Enum.find_index(candidates, &(&1 == first)) end)
      |> Enum.flat_map(fn {_id, findings} -> Enum.chunk_every(findings, ctx.verify_batch) end)

    run = fn [first | _] = findings ->
      findings
      |> Verifier.run(
        home_unit(first, state),
        [requester: ctx.requester, spec: ctx.verifier, rules: rules_by_id] ++ ctx.run_opts
      )
      |> case do
        {:error, reason} when reason != :cancelled ->
          {:ok, %{verdicts: Enum.map(findings, fn _finding -> {:error, reason} end), usage: nil}}

        result ->
          result
      end
    end

    pool_opts = [
      cancellation: ctx.signal,
      cancelled?: &match?({:error, :cancelled}, &1),
      on_result: fn
        _findings, {:error, :cancelled} ->
          :ok

        findings, {:ok, result} ->
          findings
          |> Enum.zip(result.verdicts)
          |> Enum.each(fn {finding, verdict} ->
            emit(ctx, {:verdict, finding.fingerprint, applied_verdict(verdict)})
          end)
      end
    ]

    with {:ok, results, duration} <-
           timed(fn -> Pool.map(batches, ctx.concurrency, run, pool_opts) end) do
      reports = for {:ok, report} <- results, do: report

      acc =
        batches
        |> Enum.zip(results)
        |> Enum.flat_map(fn {findings, {:ok, report}} -> Enum.zip(findings, report.verdicts) end)
        |> Enum.reduce(%{verified: [], rejected: [], failures: []}, &add_verdict/2)

      verification = %{
        verified: Enum.reverse(acc.verified),
        rejected: Enum.reverse(acc.rejected),
        failures: Enum.reverse(acc.failures)
      }

      stats =
        stage_stats(
          length(batches),
          Enum.count(reports, fn report ->
            Enum.all?(report.verdicts, &match?({:error, _}, &1))
          end),
          Enum.map(reports, & &1.usage),
          duration
        )

      {:ok, verification, put_stage(state, :verifier, stats)}
    end
  end

  defp applied_verdict({:ok, %{verdict: verdict}}), do: verdict
  defp applied_verdict({:error, _reason}), do: :uncertain

  defp add_verdict({finding, {:ok, %{verdict: :rejected} = report}}, acc),
    do: %{acc | rejected: [%{finding: finding, evidence: report.evidence} | acc.rejected]}

  defp add_verdict({finding, {:ok, report}}, acc),
    do: %{acc | verified: [%{finding | verdict: report.verdict} | acc.verified]}

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

  defp score([], state, _rules, _ctx), do: {:ok, %{scored: [], failures: []}, state}

  defp score(findings, state, rules, ctx) do
    rules_by_id = Map.new(rules, &{&1.id, &1})
    context = %{llm: ctx.scorer.llm, llm_opts: ctx.scorer.llm_opts}
    batches = Enum.chunk_every(findings, ctx.score_batch)

    run = fn batch ->
      items =
        Enum.map(batch, fn finding ->
          %{
            finding: finding,
            unit: home_unit(finding, state),
            rule: Map.get(rules_by_id, finding.rule_id)
          }
        end)

      Scorer.score(ctx.scorer.module, items, context)
    end

    with {:ok, results, duration} <-
           timed(fn -> Pool.map(batches, ctx.concurrency, run, cancellation: ctx.signal) end) do
      {scored, failures} =
        batches
        |> Enum.zip(results)
        |> Enum.flat_map(&score_outcome/1)
        |> Enum.reduce({[], []}, fn
          {:ok, finding}, {scored, failures} ->
            {[finding | scored], failures}

          {:error, finding, failure}, {scored, failures} ->
            {[finding | scored], [failure | failures]}
        end)

      stats =
        stage_stats(
          length(batches),
          Enum.count(results, &match?({:error, _}, &1)),
          for({:ok, _confidences, usage} <- results, do: usage),
          duration
        )

      {:ok, %{scored: Enum.reverse(scored), failures: Enum.reverse(failures)},
       put_stage(state, :scorer, stats)}
    end
  end

  defp score_outcome({batch, {:ok, confidences, _usage}}) do
    Enum.zip_with(batch, confidences, fn finding, confidence ->
      {:ok, %{finding | confidence: confidence}}
    end)
  end

  # A failed batch keeps the detector's confidence.
  defp score_outcome({batch, {:error, reason}}) do
    Enum.map(batch, &{:error, &1, %{fingerprint: &1.fingerprint, reason: reason}})
  end

  ## Stage statistics

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)

    case fun.() do
      {:ok, results} -> {:ok, results, System.monotonic_time(:millisecond) - started}
      other -> other
    end
  end

  defp stage_stats(runs, failed, usages, duration_ms) do
    %{runs: runs, failed: failed, usage: Usage.aggregate(usages), duration_ms: duration_ms}
  end

  defp put_stage(state, stage, stats) do
    %{state | stages: Map.put(state.stages, stage, stats), usages: [stats.usage | state.usages]}
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
      settings: ctx.settings,
      stages: state.stages,
      duration_ms: System.monotonic_time(:millisecond) - ctx.started,
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
