defmodule Tackle.Bench.ReviewEval.Runner do
  @moduledoc """
  Runs every selected variant on every case and writes one JSON line per
  review run.

  Each run reviews a prepared case (`Tackle.Bench.ReviewEval.Case.prepare/3`)
  in a fresh ephemeral scope composed like `tackle review`'s, started with
  the case's worktree as the working directory, so the agents read the
  reviewed code. Runs are ordered repeat by repeat, and within one by case
  then variant, so an interrupted benchmark still compares the variants on
  the same cases. Review history is off, so earlier runs never hide
  findings.

  The scope and review functions can be replaced (`:start_scope`,
  `:stop_scope`, `:run_review`) so the orchestration is testable without a
  model.
  """

  alias Tackle.Bench.ReviewEval.{Case, Report, Score, Variant}
  alias Tackle.CLI.Output.Review, as: ReviewOutput
  alias Tackle.Review.{Change, Units}

  @default_limit_ms :timer.minutes(30)

  @typedoc """
  Options:

    * `:cases` (required) - `Tackle.Bench.ReviewEval.Case` structs;
    * `:variants` (required) - `Tackle.Bench.ReviewEval.Variant` structs;
    * `:repo` (required) - a directory of the repository the cases use;
    * `:workdir` (required) - where the case case checkouts are created;
    * `:out` - the JSON Lines results file (default: none);
    * `:repeat` - runs per case and variant (default 1);
    * `:model`, `:thinking` - the root agent's model and thinking level,
      which inheriting stages use (default: the configuration's);
    * `:review_opts` - extra `Tackle.Review.run/2` options for every run,
      such as `:profile` or `:max_concurrency`; a variant's options win;
    * `:limit_ms` - how long one review may take (default 30 minutes);
    * `:slack` - see `Tackle.Bench.ReviewEval.Score`;
    * `:keep_worktrees` - keep the checkouts afterwards (default `false`);
    * `:log` - `fn line -> any end` for progress (default: standard error).
  """
  @type option :: {atom(), term()}

  @doc """
  Prepares the cases and runs the benchmark. Returns the records, also
  written to `:out` as they finish.
  """
  @spec run([option()]) :: {:ok, [map()]} | {:error, term()}
  def run(opts) do
    log = Keyword.get(opts, :log, &IO.puts(:stderr, &1))

    with {:ok, out} <- open_out(Keyword.get(opts, :out)) do
      try do
        with {:ok, prepared} <- prepare_all(opts, log) do
          try do
            {:ok, run_all(prepared, out, opts, log)}
          after
            unless Keyword.get(opts, :keep_worktrees, false), do: cleanup_all(prepared)
          end
        end
      after
        if out, do: File.close(out)
      end
    end
  end

  @doc """
  Prepares every case and describes its change (units, detector batches,
  changed lines) without running a review, then removes the worktrees
  unless `:keep_worktrees` is set. Validates cases without a model.
  """
  @spec check([option()]) :: {:ok, [map()]} | {:error, term()}
  def check(opts) do
    log = Keyword.get(opts, :log, &IO.puts(:stderr, &1))

    with {:ok, prepared} <- prepare_all(opts, log) do
      try do
        prepared
        |> Enum.reduce_while({:ok, []}, fn case_run, {:ok, acc} ->
          case describe(case_run) do
            {:ok, description} -> {:cont, {:ok, [description | acc]}}
            {:error, reason} -> {:halt, {:error, {:check_failed, case_run.case.id, reason}}}
          end
        end)
        |> case do
          {:ok, descriptions} -> {:ok, Enum.reverse(descriptions)}
          error -> error
        end
      after
        unless Keyword.get(opts, :keep_worktrees, false), do: cleanup_all(prepared)
      end
    end
  end

  defp describe(case_run) do
    with {:ok, change} <- Change.load(cwd: case_run.worktree, range: case_run.range),
         {:ok, split} <- Units.split(change) do
      max = Keyword.fetch!(Units.defaults(), :max_changed_lines)
      code = Enum.filter(split.units, &(&1.kind == :code))
      changed = for unit <- code, do: unit.changed_lines

      {:ok,
       %{
         case: case_run.case.id,
         range: case_run.range,
         files: length(change.diff.files),
         units: length(split.units),
         batches: length(Units.batch(split.units, max)),
         changed_lines: Enum.sum(changed),
         issues: Enum.map(case_run.issues, &describe_issue/1),
         uncovered: uncovered(case_run.issues, code)
       }}
    end
  end

  defp describe_issue(issue) do
    places = Enum.map_join(issue.locations, ", ", &"#{&1.path}:#{&1.start_line}-#{&1.end_line}")
    "#{issue.id} #{places}"
  end

  # Issues with a location no code unit shows as changed: no finding could
  # point there, so the case is broken.
  defp uncovered(issues, code_units) do
    for issue <- issues,
        location <- issue.locations,
        not Enum.any?(code_units, fn unit ->
          unit.path == location.path and
            Enum.any?(unit.changed_ranges.new, fn range ->
              range.first <= location.end_line and range.last >= location.start_line
            end)
        end),
        uniq: true,
        do: issue.id
  end

  defp prepare_all(opts, log) do
    repo = Keyword.fetch!(opts, :repo)
    workdir = Keyword.fetch!(opts, :workdir)

    opts
    |> Keyword.fetch!(:cases)
    |> Enum.reduce_while({:ok, []}, fn kase, {:ok, acc} ->
      log.("preparing #{kase.id}")

      case Case.prepare(kase, repo, workdir) do
        {:ok, prepared} ->
          {:cont, {:ok, [prepared | acc]}}

        {:error, reason} ->
          Enum.each(acc, &Case.cleanup/1)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      error -> error
    end
  end

  defp cleanup_all(prepared), do: Enum.each(prepared, &Case.cleanup/1)

  defp open_out(nil), do: {:ok, nil}

  defp open_out(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.open(path, [:write, :utf8])
    end
  end

  # Within a repeat, each case runs the variants in a different rotation,
  # so no variant always runs right after another one and reuses the prompt
  # cache it warmed.
  defp run_all(prepared, out, opts, log) do
    variants = Keyword.fetch!(opts, :variants)
    repeat = Keyword.get(opts, :repeat, 1)

    plan =
      for r <- 1..repeat//1,
          {case_run, index} <- Enum.with_index(prepared),
          variant <- rotate(variants, index + r - 1),
          do: {r, case_run, variant}

    total = length(plan)

    plan
    |> Enum.with_index(1)
    |> Enum.map(fn {{r, case_run, variant}, index} ->
      log.("[#{index}/#{total}] #{case_run.case.id} × #{variant.name} (repeat #{r})")
      record = run_one(case_run, variant, r, opts)
      log.("  " <> describe_record(record))
      if out, do: IO.write(out, JSON.encode!(record) <> "\n")
      record
    end)
  end

  @doc false
  @spec rotate(list(), non_neg_integer()) :: list()
  def rotate([], _by), do: []

  def rotate(list, by) do
    {front, back} = Enum.split(list, rem(by, length(list)))
    back ++ front
  end

  defp describe_record(%{"status" => "ok"} = record) do
    score = record["score"]
    usage = record["usage"]

    prompt =
      (usage["input_tokens"] || 0) + (usage["cache_read_tokens"] || 0) +
        (usage["cache_write_tokens"] || 0)

    "found #{score["found"]}/#{score["issues"]} (detected #{score["detected"]}), " <>
      "#{score["extra"]} extra, #{prompt} prompt + #{usage["output_tokens"] || 0} output tokens, " <>
      "#{round(record["review_ms"] / 1000)}s"
  end

  defp describe_record(record), do: "failed: #{record["error"]}"

  @doc false
  @spec run_one(Case.prepared(), Variant.t(), pos_integer(), keyword()) :: map()
  def run_one(case_run, variant, repeat, opts) do
    start_scope = Keyword.get(opts, :start_scope, &default_start_scope/2)
    stop_scope = Keyword.get(opts, :stop_scope, &Tackle.CLI.Run.stop_scope(&1.scope_ref))
    started = System.monotonic_time(:millisecond)
    cwd = File.cwd!()
    base = %{case: case_run, variant: variant, repeat: repeat}

    outcome =
      try do
        with :ok <- reset(case_run) do
          File.cd!(case_run.worktree)

          case start_scope.(Keyword.get(opts, :model), Keyword.get(opts, :thinking)) do
            {:ok, scope, scope_spec} ->
              try do
                review(case_run, variant, scope, scope_spec, opts)
              after
                stop_scope.(scope)
              end

            {:error, reason} ->
              {:error, {:scope, reason}, %{}}
          end
        end
      after
        File.cd!(cwd)
      end

    duration = System.monotonic_time(:millisecond) - started

    run =
      case outcome do
        {:ok, result, change, stats} ->
          Map.merge(base, %{
            result: result,
            score: Score.score(result, case_run.issues, Keyword.take(opts, [:slack])),
            result_json: ReviewOutput.json_result(result, change),
            profiles: stats
          })

        {:error, reason, stats} ->
          Map.merge(base, %{error: format_error(reason), profiles: stats})
      end

    Report.record(Map.put(run, :duration_ms, duration))
  end

  # A run's agents have bash; whatever an earlier run changed in the
  # checkout is undone before the next one.
  defp reset(case_run) do
    case Case.reset(case_run) do
      :ok -> :ok
      {:error, reason} -> {:error, {:reset_failed, reason}, %{}}
    end
  end

  defp default_start_scope(model, thinking),
    do: Tackle.CLI.Run.start_ephemeral_scope(model, thinking)

  defp review(case_run, variant, scope, scope_spec, opts) do
    run_review = Keyword.get(opts, :run_review, &Tackle.Review.run/2)

    workspace =
      scope_spec.root_spec.config.context
      |> Tackle.Executor.from_context()
      |> Tackle.Executor.workspace()

    with {:ok, profiles, stats} <- Variant.profiles(variant, scope_spec.profiles),
         {:ok, change} <- load_change(case_run, workspace, stats) do
      review_opts =
        [requester: scope.root_agent_ref, profiles: profiles, history: nil]
        |> Keyword.merge(Keyword.get(opts, :review_opts, []))
        |> Keyword.merge(variant.review_opts)

      limit = Keyword.get(opts, :limit_ms, @default_limit_ms)

      case supervise(fn -> run_review.(change, review_opts) end, limit) do
        {:ok, {:ok, result}} -> {:ok, result, change, stats}
        {:ok, {:error, reason}} -> {:error, reason, stats}
        {:ok, other} -> {:error, {:crashed, {:unexpected_result, other}}, stats}
        {:crashed, reason} -> {:error, {:crashed, reason}, stats}
        :timeout -> {:error, {:timeout, limit}, stats}
      end
    else
      {:error, reason, stats} -> {:error, reason, stats}
      {:error, reason} -> {:error, reason, %{}}
    end
  end

  # Runs the review in an unlinked, monitored process, so a crash is a
  # failed run instead of the end of the benchmark. On timeout the process
  # is killed, which cancels the runs it owns.
  defp supervise(fun, limit) do
    parent = self()
    tag = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(parent, {tag, fun.()}) end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        {:ok, result}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:crashed, reason}
    after
      limit ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        end

        receive do
          {^tag, _late} -> :ok
        after
          0 -> :ok
        end

        :timeout
    end
  end

  defp load_change(case_run, workspace, stats) do
    case Change.load(cwd: case_run.worktree, workspace: workspace, range: case_run.range) do
      {:ok, change} -> {:ok, change}
      {:error, reason} -> {:error, {:change, reason}, stats}
    end
  end

  defp format_error({:scope, reason}), do: "scope: " <> ReviewOutput.format_error(reason)

  defp format_error({:reset_failed, reason}),
    do: "could not reset the checkout: #{inspect(reason)}"

  defp format_error({:crashed, reason}), do: "crashed: " <> inspect(reason)
  defp format_error({:timeout, limit}), do: "gave up after #{div(limit, 1000)}s"
  defp format_error(reason), do: ReviewOutput.format_error(reason)
end
