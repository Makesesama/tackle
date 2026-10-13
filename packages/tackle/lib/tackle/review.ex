defmodule Tackle.Review do
  @moduledoc """
  Reviews a code change and returns ranked, line-anchored findings.

  `run/2` drives a deterministic pipeline; models only work inside one
  batch of units or of candidates at a time:

      Units.split ─► Units.batch ─► Rules.resolve ─► Detector (samples × batch)
        ─► Cluster ─► Filter.deterministic + visible lanes + verify limit
        ─► Verifier (per batch of a unit's candidates) ─► Scorer (per batch)
        ─► Rank.select ─► Result ─► History.record_run

  Detection and verification overlap: detector and verifier runs share one
  bounded work queue, and a finished detector batch's new candidates are
  verified while other batches are still being reviewed. Findings are
  merged into clusters (`Tackle.Review.Cluster.same?/2`) that keep their
  clearest finding; the filters and the profile's lanes
  (`Tackle.Review.Rank.visible?/2`) are checked on that finding whenever a
  cluster changes before it is verified, and a finding matching a cluster
  being verified only adds support. While detection runs, candidates are
  verified until half of the verification limit (`:verify_limit`) is used;
  later ones wait until detection ends and compete for the remaining slots
  by score, so whenever there are no more candidates than the limit, every
  one is verified. A verdict applies to its cluster's clearest finding.
  Scoring starts once every verdict is in.

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
  cached tokens), and wall time from its first run's start to its last
  run's end (detection and verification overlap, so these spans add up to
  more than `summary.duration_ms`), so settings can be compared.

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
    * `{:candidate, finding}` - a filtered candidate sent to the verifier,
      possibly while other units are still being reviewed;
    * `{:verdict, fingerprint, :confirmed | :rejected | :uncertain}` - per
      candidate; a failed verification counts as `:uncertain`;
    * `{:done, result}` or `{:error, reason}` - last.

  The callback must not raise.

  ## Cancellation

  Cancel the `:cancellation` signal (`Tackle.Lib.Cancellation`), or cancel
  the requester's branch or scope, and `run/2` returns `{:error, :cancelled}`
  after stopping the runs still in flight. Killing the calling process
  cancels them as well. A single run cancelled on its own only fails that
  run.

  ## Failed runs

  A failed run never invalidates the review. Detector runs report findings
  as they confirm them, and whatever a run reported before it failed (an
  agent error, the step limit, a timeout, a crash, or its own cancellation)
  is kept: its unit is listed in `summary.incomplete_units` when the run had
  not finished, and in `summary.failed_units` only when it reported
  nothing. A verifier run that fails keeps the verdicts it reported; its
  other findings stay uncertain.
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
    * `:verify_limit` - how many candidates at most are verified: the first
      half as they are found, the rest the best of the remaining ones by
      detector confidence (default: `Tackle.Review.Rank.verify_limit/1` of
      the profile);
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
  `result.summary` lists them, and the findings their runs reported before
  failing are kept. Returns `{:error, reason}` for invalid
  options, a requester whose model a stage cannot inherit
  (`{:requester_model_unavailable, reason}`), an invalid `:exclude` glob,
  cancellation (`:cancelled`), or when every unit failed without reporting
  a finding (`{:detection_failed, failures}`).
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

    with {:ok, flow, state} <- detect_and_verify(state, rules, ctx),
         {:ok, scoring, state} <- score(flow.verified, state, rules, ctx) do
      selection = Rank.select(scoring.scored, ctx.profile, samples: ctx.samples)

      outcome = %{
        selection: selection,
        filtered: flow.dropped,
        rejected: flow.rejected,
        failed_units: flow.failed_units,
        incomplete_units: flow.incomplete_units,
        detected: flow.detected,
        candidates: flow.candidates,
        verified: flow.verified,
        verification_failures: flow.verification_failures,
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

  ## Detection and verification
  #
  # Detector and verifier runs share one work queue (`Pool.run/5`), so the
  # findings of a finished detector batch are verified while other batches
  # are still being reviewed. Findings are fingerprinted and merged into
  # clusters (`Cluster.same?/2`); a cluster keeps its clearest finding and
  # the samples that reported it. Each time a cluster that is not yet
  # verified changes, its clearest finding is checked again: the
  # deterministic filters and the profile's lanes decide whether it is a
  # candidate. A candidate is verified right away while detection runs and
  # fewer than half of the verification limit are used; later ones are held
  # until detection ends and then compete for the remaining slots by rank.
  # With no more candidates than the limit, every one is verified, as
  # without streaming. A verified cluster's verdict applies to its clearest
  # finding at the end, as it did when clusters were merged before
  # verification.

  defp detect_and_verify(state, rules, ctx) do
    paths = Enum.map(state.change.diff.files, & &1.path)

    jobs =
      state.units
      |> batches(ctx.units)
      |> Enum.map(fn units ->
        {:detect, units, Enum.map(units, &Rules.resolve(rules, &1, paths: paths))}
      end)

    warnings =
      jobs
      |> Enum.flat_map(fn {:detect, _units, resolutions} ->
        Enum.flat_map(resolutions, & &1.warnings)
      end)
      |> Enum.map(&format_warning/1)
      |> Enum.uniq()

    state = %{state | warnings: state.warnings ++ warnings}
    limit = ctx.verify_limit || Rank.verify_limit(ctx.profile)

    flow = %{
      detecting: length(jobs),
      detections: [],
      detected: 0,
      samples: 0,
      clusters: %{},
      dispatched: [],
      limit: limit,
      eager: div(limit, 2),
      verdicts: %{},
      verifications: [],
      spans: %{}
    }

    env = %{
      state: state,
      ctx: ctx,
      rules: rules,
      rules_by_id: Map.new(rules, &{&1.id, &1}),
      lines: lines_by_path(state.code_units)
    }

    opts = [
      cancellation: ctx.signal,
      cancelled?: &match?({:error, :cancelled}, &1),
      on_start: &flow_started(&1, &2, env),
      on_result: &flow_result(&1, &2, &3, env)
    ]

    with {:ok, flow} <- Pool.run(jobs, ctx.concurrency, &run_job(&1, env), flow, opts) do
      finish_flow(flow, state)
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

  defp run_job({:detect, units, resolutions}, env) do
    units
    |> Detector.run(
      [
        requester: env.ctx.requester,
        spec: env.ctx.detector,
        rules: resolutions |> Enum.flat_map(& &1.rules) |> Enum.uniq_by(& &1.id),
        index: env.state.index,
        samples: env.ctx.samples
      ] ++ env.ctx.run_opts
    )
    |> case do
      {:error, reason} when reason != :cancelled ->
        {:ok, %{samples: [], incomplete: [], errors: [reason], runs: 0, usage: nil}}

      result ->
        result
    end
  end

  defp run_job({:verify, _ids, findings, unit}, env) do
    findings
    |> Verifier.run(
      unit,
      [requester: env.ctx.requester, spec: env.ctx.verifier, rules: env.rules_by_id] ++
        env.ctx.run_opts
    )
    |> case do
      {:error, reason} when reason != :cancelled ->
        {:ok, %{verdicts: Enum.map(findings, fn _finding -> {:error, reason} end), usage: nil}}

      result ->
        result
    end
  end

  defp flow_started({:detect, units, _resolutions} = job, flow, env) do
    Enum.each(units, &emit(env.ctx, {:unit, &1.id, :started}))
    span(flow, job, :start)
  end

  defp flow_started(job, flow, _env), do: span(flow, job, :start)

  defp flow_result(_job, {:error, :cancelled}, flow, _env), do: {[], flow}

  defp flow_result({:detect, units, _resolutions} = job, result, flow, env) do
    Enum.each(units, &emit(env.ctx, unit_event(&1, result)))

    flow =
      %{span(flow, job, :finish) | detecting: flow.detecting - 1}
      |> Map.update!(:detections, &[{units, result} | &1])

    {flow, touched} =
      case result do
        {:ok, %{samples: samples}} -> Enum.reduce(samples, {flow, []}, &add_sample(&1, &2, env))
        _failed -> {flow, []}
      end

    {dispatch, flow} = admit(touched |> Enum.reverse() |> Enum.uniq(), flow, env)
    {release, flow} = if flow.detecting == 0, do: release(flow, env), else: {[], flow}
    verify_jobs(dispatch ++ release, flow, env)
  end

  defp flow_result({:verify, ids, findings, _unit} = job, result, flow, env) do
    # A crashed run decides nothing: its findings stay uncertain.
    report =
      case result do
        {:ok, report} -> report
        {:error, reason} -> %{verdicts: Enum.map(ids, fn _id -> {:error, reason} end), usage: nil}
      end

    findings
    |> Enum.zip(report.verdicts)
    |> Enum.each(fn {finding, verdict} ->
      emit(env.ctx, {:verdict, finding.fingerprint, applied_verdict(verdict)})
    end)

    verdicts = ids |> Enum.zip(report.verdicts) |> Map.new()

    flow =
      %{span(flow, job, :finish) | verdicts: Map.merge(flow.verdicts, verdicts)}
      |> Map.update!(:verifications, &[report | &1])

    {[], flow}
  end

  defp unit_event(unit, {:ok, %{samples: [_ | _]}}), do: {:unit, unit.id, :done}
  defp unit_event(unit, {:ok, %{errors: [reason | _]}}), do: {:unit, unit.id, {:failed, reason}}
  defp unit_event(unit, {:error, reason}), do: {:unit, unit.id, {:failed, reason}}

  # The first start and last finish of each stage's runs.
  defp span(flow, job, edge) do
    stage = if elem(job, 0) == :detect, do: :detector, else: :verifier
    now = System.monotonic_time(:millisecond)
    span = flow.spans |> Map.get(stage, {now, now}) |> extend_span(edge, now)
    %{flow | spans: Map.put(flow.spans, stage, span)}
  end

  defp extend_span(span, :start, _now), do: span
  defp extend_span({first, last}, :finish, now), do: {first, max(last, now)}

  # Adds one detector sample's findings to the clusters; returns the ids of
  # the clusters it created or changed.
  defp add_sample(findings, {flow, touched}, env) do
    findings = Enum.map(findings, &fingerprint(&1, env.lines))
    sample = flow.samples
    flow = %{flow | detected: flow.detected + length(findings), samples: sample + 1}
    Enum.reduce(findings, {flow, touched}, &add_finding(&1, &2, sample))
  end

  defp add_finding(finding, {flow, touched}, sample) do
    match = Enum.find(cluster_ids(flow), &Cluster.same?(flow.clusters[&1].finding, finding))

    case match do
      nil ->
        id = map_size(flow.clusters)
        cluster = %{finding: finding, samples: MapSet.new([sample]), status: :new, sent: nil}
        {%{flow | clusters: Map.put(flow.clusters, id, cluster)}, [id | touched]}

      id ->
        flow =
          update_in(flow.clusters[id], fn cluster ->
            %{
              cluster
              | finding: Cluster.clearer(cluster.finding, finding),
                samples: MapSet.put(cluster.samples, sample)
            }
          end)

        {flow, [id | touched]}
    end
  end

  # Checks created or changed clusters that are not verified yet: a
  # candidate is dispatched while detection runs and the eager share of the
  # limit is not used up, otherwise held; a cluster the filters or the
  # profile's lanes reject waits, as a later finding may make it clearer.
  defp admit(ids, flow, env) do
    {dispatch, flow} = Enum.reduce(ids, {[], flow}, &admit_cluster(&1, &2, env))
    {Enum.reverse(dispatch), flow}
  end

  defp admit_cluster(id, {dispatch, flow}, env) do
    eligibility =
      if flow.clusters[id].status == :dispatched,
        do: :dispatched,
        else: eligibility(cluster_finding(flow, id), env)

    cond do
      eligibility == :dispatched ->
        {dispatch, flow}

      eligibility != :ok ->
        {:error, reason} = eligibility
        {dispatch, put_status(flow, id, {:rejected, reason})}

      flow.detecting > 0 and length(flow.dispatched) < flow.eager ->
        {[id | dispatch], dispatched(flow, id)}

      true ->
        {dispatch, put_status(flow, id, :held)}
    end
  end

  defp eligibility(finding, env) do
    filtered =
      Filter.deterministic([finding],
        changed: env.state.index,
        rules: env.rules,
        known_fingerprints: env.ctx.known
      )

    case filtered do
      {[_finding], []} ->
        if Rank.visible?(finding, env.ctx.profile), do: :ok, else: {:error, :hidden_lane}

      {[], [{_finding, reason}]} ->
        {:error, reason}
    end
  end

  # Once detection is over, the held candidates compete for the remaining
  # slots by score, ties in order of discovery.
  defp release(flow, env) do
    held = Enum.filter(cluster_ids(flow), &(flow.clusters[&1].status == :held))
    remaining = max(flow.limit - length(flow.dispatched), 0)

    {kept, over} =
      held
      |> Enum.with_index()
      |> Enum.sort_by(fn {id, index} ->
        {-Rank.score(cluster_finding(flow, id), env.ctx.samples), index}
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.split(remaining)

    kept = MapSet.new(kept)
    flow = Enum.reduce(over, flow, &put_status(&2, &1, {:rejected, :over_verify_limit}))
    dispatch = Enum.filter(held, &MapSet.member?(kept, &1))
    {dispatch, Enum.reduce(dispatch, flow, &dispatched(&2, &1))}
  end

  # Cluster ids count up from 0 in order of discovery.
  defp cluster_ids(flow), do: Enum.to_list(0..(map_size(flow.clusters) - 1)//1)

  defp cluster_finding(flow, id) do
    cluster = Map.fetch!(flow.clusters, id)
    %{cluster.finding | support: MapSet.size(cluster.samples)}
  end

  defp put_status(flow, id, status),
    do: update_in(flow.clusters[id], &%{&1 | status: status})

  # The finding sent to the verifier is kept for the verdict's evidence.
  defp dispatched(flow, id) do
    sent = cluster_finding(flow, id)
    flow = update_in(flow.clusters[id], &%{&1 | status: :dispatched, sent: sent})
    %{flow | dispatched: [id | flow.dispatched]}
  end

  # Verifier jobs for dispatched clusters: a unit's candidates share runs
  # of at most `verify_batch` findings.
  defp verify_jobs(ids, flow, env) do
    entries =
      Enum.map(ids, fn id ->
        finding = flow.clusters[id].sent
        {id, finding, home_unit(finding, env.state)}
      end)

    by_unit = Enum.group_by(entries, fn {_id, _finding, unit} -> unit.id end)

    jobs =
      entries
      |> Enum.map(fn {_id, _finding, unit} -> unit.id end)
      |> Enum.uniq()
      |> Enum.flat_map(fn unit_id ->
        by_unit
        |> Map.fetch!(unit_id)
        |> Enum.chunk_every(env.ctx.verify_batch)
        |> Enum.map(fn [{_id, _finding, unit} | _] = chunk ->
          {:verify, Enum.map(chunk, &elem(&1, 0)), Enum.map(chunk, &elem(&1, 1)), unit}
        end)
      end)

    Enum.each(entries, fn {_id, finding, _unit} -> emit(env.ctx, {:candidate, finding}) end)
    {jobs, flow}
  end

  defp finish_flow(flow, state) do
    detections = Enum.reverse(flow.detections)

    failed_units =
      for {units, result} <- detections,
          reason = detection_failure(result),
          reason != nil,
          unit <- units,
          do: %{unit: unit.id, reason: reason}

    reports = for {_units, {:ok, report}} <- detections, do: report

    # Every sample stopped early, but what they reported is kept.
    incomplete_units =
      for {units, {:ok, %{incomplete: [reason | _] = incomplete, samples: samples}}} <-
            detections,
          length(incomplete) == length(samples),
          unit <- units,
          do: %{unit: unit.id, reason: reason}

    if Enum.all?(reports, &(&1.samples == [])) do
      {:error, {:detection_failed, failed_units}}
    else
      detector =
        stage_stats(
          Enum.sum_by(reports, & &1.runs),
          Enum.sum_by(reports, &(length(&1.errors) + length(&1.incomplete))),
          Enum.map(reports, & &1.usage),
          span_ms(flow, :detector)
        )

      verifier =
        stage_stats(
          length(flow.verifications),
          Enum.count(flow.verifications, fn report ->
            Enum.all?(report.verdicts, &match?({:error, _}, &1))
          end),
          Enum.map(flow.verifications, & &1.usage),
          span_ms(flow, :verifier)
        )

      # Ordered by location, so the result does not depend on which run
      # finished first.
      acc =
        flow.dispatched
        |> Enum.map(fn id ->
          {cluster_finding(flow, id), flow.clusters[id].sent, Map.get(flow.verdicts, id)}
        end)
        |> Enum.sort_by(fn {finding, _sent, _verdict} -> location_key(finding) end)
        |> Enum.reduce(%{verified: [], rejected: [], failures: []}, &add_verdict/2)

      dropped =
        for id <- cluster_ids(flow),
            {:rejected, reason} <- [flow.clusters[id].status],
            do: {cluster_finding(flow, id), reason}

      result = %{
        failed_units: failed_units,
        incomplete_units: incomplete_units,
        detected: flow.detected,
        candidates: length(flow.dispatched),
        dropped: dropped,
        verified: Enum.reverse(acc.verified),
        rejected: Enum.reverse(acc.rejected),
        verification_failures: Enum.reverse(acc.failures)
      }

      state = state |> put_stage(:detector, detector) |> put_stage(:verifier, verifier)
      {:ok, result, state}
    end
  end

  defp detection_failure({:ok, %{samples: [], errors: [reason | _]}}), do: reason
  defp detection_failure({:error, reason}), do: reason
  defp detection_failure(_result), do: nil

  defp location_key(%Finding{location: location, fingerprint: fingerprint}),
    do: {location.path, location.side, location.start_line, location.end_line, fingerprint}

  defp span_ms(flow, stage) do
    case Map.get(flow.spans, stage) do
      {first, last} -> last - first
      nil -> 0
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

  defp applied_verdict({:ok, %{verdict: verdict}}), do: verdict
  defp applied_verdict({:error, _reason}), do: :uncertain

  # A verdict applies to the cluster's clearest finding; a rejection keeps
  # the finding the verifier saw, which its evidence is about.
  defp add_verdict({finding, sent, {:ok, %{verdict: :rejected} = report}}, acc) do
    rejected = %{sent | support: finding.support}
    %{acc | rejected: [%{finding: rejected, evidence: report.evidence} | acc.rejected]}
  end

  defp add_verdict({finding, _sent, {:ok, report}}, acc),
    do: %{acc | verified: [%{finding | verdict: report.verdict} | acc.verified]}

  defp add_verdict({finding, _sent, failure}, acc) do
    reason =
      case failure do
        {:error, reason} -> reason
        nil -> :no_verdict
      end

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
      incomplete_units: [],
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
      incomplete_units: outcome.incomplete_units,
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
