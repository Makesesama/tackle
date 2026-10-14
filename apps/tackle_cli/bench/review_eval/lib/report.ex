defmodule Tackle.Bench.ReviewEval.Report do
  @moduledoc """
  Records of benchmark runs and their summary.

  `record/1` turns one review run into a JSON-encodable map (one line of the
  results file); `summarize/1` aggregates records per variant; `table/2` and
  `case_table/1` render the summary as Markdown.
  """

  alias Tackle.Lib.Usage

  @usage_fields [
    :input_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :output_tokens,
    :reasoning_tokens,
    :cost
  ]

  @doc """
  Builds the record of one run from a map with `:case` (prepared case),
  `:variant`, `:repeat`, `:duration_ms` (wall time, scope setup included),
  `:profiles` (stage stats), and either `:result` with `:score` (and
  optionally `:result_json`) or `:error`. `review_ms` is the review's own
  duration; `settings` holds each stage's resolved model and thinking level.
  """
  @spec record(map()) :: map()
  def record(%{case: prepared, variant: variant} = run) do
    base = %{
      "case" => prepared.case.id,
      "variant" => variant.name,
      "repeat" => run.repeat,
      "range" => prepared.range,
      "issues" => length(prepared.issues),
      "wall_ms" => run.duration_ms,
      "profiles" => json_profiles(Map.get(run, :profiles, %{}))
    }

    case run do
      %{result: result, score: score} ->
        summary = result.summary

        Map.merge(base, %{
          "status" => "ok",
          "review_ms" => Map.get(summary, :duration_ms),
          "settings" => json_settings(Map.get(summary, :settings)),
          "score" => json_score(score),
          "usage" => usage_map(result.usage),
          "stages" => json_stages(summary.stages),
          "units" => summary.units,
          "failed_units" => length(summary.failed_units),
          "incomplete_units" => length(summary.incomplete_units),
          "detected" => summary.detected,
          "candidates" => summary.candidates,
          "confirmed" => summary.confirmed,
          "rejected" => summary.rejected,
          "result" => Map.get(run, :result_json)
        })

      %{error: error} ->
        Map.merge(base, %{"status" => "error", "error" => error})
    end
  end

  defp json_settings(%{models: models, thinking: thinking}) do
    %{
      "models" => Map.new(models, fn {stage, model} -> {to_string(stage), model} end),
      "thinking" => Map.new(thinking, fn {stage, level} -> {to_string(stage), level} end)
    }
  end

  defp json_settings(_settings), do: nil

  defp json_score(score) do
    %{
      "issues" => score.issues,
      "found" => score.found,
      "detected" => score.detected,
      "shown" => score.shown,
      "extra" => score.extra,
      "per_issue" =>
        Enum.map(score.per_issue, fn %{id: id, outcome: outcome} ->
          %{"id" => id, "outcome" => format_outcome(outcome)}
        end)
    }
  end

  @doc "Formats an issue outcome of `Tackle.Bench.ReviewEval.Score`."
  @spec format_outcome(term()) :: String.t()
  def format_outcome({:dropped, reason}), do: "dropped:#{reason}"
  def format_outcome(outcome), do: to_string(outcome)

  defp json_profiles(profiles) do
    Map.new(profiles, fn {stage, stats} ->
      {to_string(stage),
       %{
         "system_prompt_bytes" => stats.system_prompt_bytes,
         "tools" => stats.tools,
         "max_iterations" => format_iterations(stats.max_iterations)
       }}
    end)
  end

  defp format_iterations(:infinity), do: "infinity"
  defp format_iterations(n), do: n

  defp json_stages(stages) do
    Map.new(stages, fn {stage, stats} ->
      {to_string(stage),
       %{
         "runs" => stats.runs,
         "failed" => stats.failed,
         "duration_ms" => stats.duration_ms,
         "usage" => usage_map(stats.usage)
       }}
    end)
  end

  @doc "The token buckets (and cost, when known) of a usage, as a string-keyed map."
  @spec usage_map(Usage.t() | nil) :: %{String.t() => number()}
  def usage_map(%Usage{} = usage) do
    for field <- @usage_fields,
        value = Map.get(usage, field),
        is_number(value),
        into: %{},
        do: {to_string(field), value}
  end

  def usage_map(_usage), do: %{}

  ## Summary

  @doc """
  Aggregates records per variant, in order of first appearance. Recall
  (`found`, `detected`) is over the issues of every run: a failed run finds
  nothing, so a variant cannot gain recall by failing on hard cases.
  Tokens, runs, and the review's own time are means per successful run (a
  failed run's usage is not known).
  """
  @spec summarize([map()]) :: [map()]
  def summarize(records) do
    records
    |> Enum.map(& &1["variant"])
    |> Enum.uniq()
    |> Enum.map(fn variant ->
      runs = Enum.filter(records, &(&1["variant"] == variant))
      ok = Enum.filter(runs, &(&1["status"] == "ok"))
      issues = sum(runs, & &1["issues"])

      %{
        variant: variant,
        runs: length(runs),
        errors: length(runs) - length(ok),
        issues: issues,
        found: sum(ok, &get_in(&1, ["score", "found"])),
        detected: sum(ok, &get_in(&1, ["score", "detected"])),
        recall: ratio(sum(ok, &get_in(&1, ["score", "found"])), issues),
        detect_recall: ratio(sum(ok, &get_in(&1, ["score", "detected"])), issues),
        extra: mean(ok, &get_in(&1, ["score", "extra"])),
        prompt_tokens: mean(ok, &prompt_tokens(&1["usage"])),
        uncached_tokens: mean(ok, &uncached_tokens(&1["usage"])),
        cache_read_tokens: mean(ok, &(&1["usage"]["cache_read_tokens"] || 0)),
        output_tokens: mean(ok, &(&1["usage"]["output_tokens"] || 0)),
        cost: cost(ok),
        detector_runs: mean(ok, &(get_in(&1, ["stages", "detector", "runs"]) || 0)),
        verifier_runs: mean(ok, &(get_in(&1, ["stages", "verifier", "runs"]) || 0)),
        incomplete_units: mean(ok, &((&1["failed_units"] || 0) + (&1["incomplete_units"] || 0))),
        duration_s: mean(ok, &((&1["review_ms"] || 0) / 1000))
      }
    end)
  end

  defp prompt_tokens(usage),
    do:
      (usage["input_tokens"] || 0) + (usage["cache_read_tokens"] || 0) +
        (usage["cache_write_tokens"] || 0)

  defp uncached_tokens(usage),
    do: (usage["input_tokens"] || 0) + (usage["cache_write_tokens"] || 0)

  # Only when every successful run reported a cost.
  defp cost([]), do: nil

  defp cost(ok) do
    if Enum.all?(ok, &is_number(&1["usage"]["cost"])),
      do: mean(ok, & &1["usage"]["cost"]),
      else: nil
  end

  defp sum(records, fun), do: records |> Enum.map(&(fun.(&1) || 0)) |> Enum.sum()

  defp mean([], _fun), do: nil
  defp mean(records, fun), do: sum(records, fun) / length(records)

  defp ratio(_n, 0), do: nil
  defp ratio(n, d), do: n / d

  @doc """
  Renders the summary as a Markdown table. With a `:baseline` variant name
  present in the summary, token columns also show the share of its value.
  """
  @spec table([map()], keyword()) :: String.t()
  def table(summary, opts \\ []) do
    baseline = Enum.find(summary, &(&1.variant == Keyword.get(opts, :baseline, "baseline")))

    header =
      "| variant | runs | err | recall | detected | extra/run | prompt tok | uncached | " <>
        "output tok | cost | det runs | ver runs | incompl. | time s |\n" <>
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"

    rows =
      Enum.map(summary, fn row ->
        cells = [
          row.variant,
          row.runs,
          row.errors,
          recall(row.found, row.issues, row.recall),
          recall(row.detected, row.issues, row.detect_recall),
          number(row.extra, 1),
          relative(row.prompt_tokens, baseline && baseline.prompt_tokens),
          relative(row.uncached_tokens, baseline && baseline.uncached_tokens),
          relative(row.output_tokens, baseline && baseline.output_tokens),
          if(row.cost, do: number(row.cost, 3), else: "–"),
          number(row.detector_runs, 1),
          number(row.verifier_runs, 1),
          number(row.incomplete_units, 1),
          number(row.duration_s, 0)
        ]

        "| " <> Enum.map_join(cells, " | ", &to_string/1) <> " |"
      end)

    Enum.join([header | rows], "\n")
  end

  @doc "Renders, per case and variant, the issues found over all repeats."
  @spec case_table([map()]) :: String.t()
  def case_table(records) do
    variants = records |> Enum.map(& &1["variant"]) |> Enum.uniq()
    cases = records |> Enum.map(& &1["case"]) |> Enum.uniq()

    header =
      "| case | " <>
        Enum.join(variants, " | ") <>
        " |\n|---|" <> String.duplicate("---:|", length(variants))

    rows =
      Enum.map(cases, fn kase ->
        cells =
          Enum.map(variants, fn variant ->
            runs = Enum.filter(records, &(&1["case"] == kase and &1["variant"] == variant))
            ok = Enum.filter(runs, &(&1["status"] == "ok"))
            errors = length(runs) - length(ok)
            found = sum(ok, &get_in(&1, ["score", "found"]))
            issues = sum(runs, & &1["issues"])
            cell = if runs == [], do: "–", else: "#{found}/#{issues}"
            if errors > 0, do: "#{cell} (#{errors} err)", else: cell
          end)

        "| #{kase} | " <> Enum.join(cells, " | ") <> " |"
      end)

    Enum.join([header | rows], "\n")
  end

  defp recall(_n, 0, _ratio), do: "–"
  defp recall(n, d, ratio), do: "#{n}/#{d} (#{round(ratio * 100)}%)"

  defp relative(nil, _baseline), do: "–"

  defp relative(value, baseline) when is_number(baseline) and baseline > 0,
    do: "#{count(value)} (#{round(value / baseline * 100)}%)"

  defp relative(value, _baseline), do: count(value)

  defp count(value) when value >= 1_000_000, do: "#{Float.round(value / 1_000_000, 2)}M"
  defp count(value) when value >= 1_000, do: "#{Float.round(value / 1_000, 1)}k"
  defp count(value), do: "#{round(value)}"

  defp number(nil, _digits), do: "–"
  defp number(value, 0), do: "#{round(value)}"
  defp number(value, digits), do: "#{Float.round(value / 1, digits)}"
end
