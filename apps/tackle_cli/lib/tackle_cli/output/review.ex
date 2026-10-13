defmodule Tackle.CLI.Output.Review do
  @moduledoc """
  Renders the result of `tackle review` for people and for machines.

  Text output lists the shown findings grouped into blocking and optional
  ones (severity, `path:line`, title, trigger, and rule), followed by a
  summary of what was reviewed. JSON output encodes the whole
  `Tackle.Review.Result` together with the reviewed change; atoms become
  strings and failure reasons become messages.
  """

  alias Tackle.CLI.Output
  alias Tackle.Lib.Usage
  alias Tackle.Review.{Change, Delegation, Finding, Result}

  @usage_fields [
    :input_tokens,
    :output_tokens,
    :reasoning_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :total_tokens,
    :cost,
    :currency
  ]

  @doc "Renders a review result in the output's format (`:json` or text)."
  @spec render(Result.t(), Change.t(), Output.t()) :: Owl.Data.t()
  def render(%Result{} = result, %Change{} = change, %Output{format: :json}) do
    JSON.encode!(json_result(result, change))
  end

  def render(%Result{} = result, %Change{} = change, %Output{} = output) do
    sections =
      [
        group("Blocking", result.blocking, output),
        group("Optional", result.optional, output),
        notes(result.summary, output),
        summary(result, change, output)
      ]
      |> Enum.reject(&(&1 == []))

    Enum.intersperse(sections, "\n\n")
  end

  @doc """
  Renders a failure in the output's format.

  `reason` is `{:change, reason}` when the change could not be loaded and any
  other term when the review could not start or failed.
  """
  @spec render_error(term(), Output.t()) :: Owl.Data.t()
  def render_error(reason, %Output{format: :json}),
    do: JSON.encode!(%{"error" => format_error(reason)})

  def render_error(reason, %Output{} = output),
    do: Output.style(output, :danger, "error: " <> format_error(reason))

  @doc "Describes a review failure in one line."
  @spec format_error(term()) :: String.t()
  def format_error({:change, reason}), do: Change.format_error(reason)
  def format_error(:cancelled), do: "the review was cancelled"

  def format_error({:detection_failed, [%{reason: reason} | _rest] = failures}) do
    "every review unit failed (#{length(failures)}); first: #{Delegation.format_error(reason)}"
  end

  def format_error({:requester_model_unavailable, reason}),
    do: "the review model is unavailable: #{inspect(reason)}"

  def format_error({:missing_profile, name}), do: "the agent profile #{name} is missing"

  def format_error({:missing_tool, name, tool}),
    do: "the agent profile #{name} must keep the #{tool} tool"

  def format_error({:unsupported_agent_config, name}),
    do: "the agent profile #{name} has an unsupported configuration"

  def format_error({:invalid_profile, name, _value}),
    do: "the agent profile #{name} could not be loaded"

  def format_error(reason), do: Tackle.CLI.Jail.format_error(reason) || inspect(reason)

  @doc "Converts a result and its change into JSON-encodable data."
  @spec json_result(Result.t(), Change.t()) :: map()
  def json_result(%Result{} = result, %Change{} = change) do
    %{
      "verdict" => to_string(result.summary.verdict),
      "change" => json_change(change),
      "blocking" => Enum.map(result.blocking, &json_finding/1),
      "optional" => Enum.map(result.optional, &json_finding/1),
      "rejected" =>
        Enum.map(result.rejected, fn %{finding: finding, evidence: evidence} ->
          %{"finding" => json_finding(finding), "evidence" => evidence}
        end),
      "dropped" =>
        Enum.map(result.dropped, fn %{finding: finding, reason: reason} ->
          %{"finding" => json_finding(finding), "reason" => to_string(reason)}
        end),
      "summary" => json_summary(result.summary),
      "usage" => json_usage(result.usage)
    }
  end

  @doc "Converts a finding into JSON-encodable data."
  @spec json_finding(Finding.t()) :: map()
  def json_finding(%Finding{} = finding) do
    %{
      "title" => finding.title,
      "category" => to_string(finding.category),
      "severity" => to_string(finding.severity),
      "blocking" => finding.blocking,
      "confidence" => finding.confidence,
      "rule_id" => finding.rule_id,
      "location" => %{
        "path" => finding.location.path,
        "side" => to_string(finding.location.side),
        "start_line" => finding.location.start_line,
        "end_line" => finding.location.end_line
      },
      "trigger" => finding.trigger,
      "body" => finding.body,
      "suggestion" => finding.suggestion,
      "support" => finding.support,
      "verdict" => finding.verdict && to_string(finding.verdict),
      "fingerprint" => finding.fingerprint
    }
  end

  @doc "Formats a finding's location as `path:line`, `path:first-last`, with ` (old)` for removed lines."
  @spec location(Finding.location()) :: String.t()
  def location(%{path: path, side: side, start_line: first, end_line: last}) do
    lines = if first == last, do: "#{first}", else: "#{first}-#{last}"
    suffix = if side == :old, do: " (old)", else: ""
    "#{path}:#{lines}#{suffix}"
  end

  ## Text

  defp group(_label, [], _output), do: []

  defp group(label, findings, output) do
    heading = Output.style(output, :heading, "#{label} (#{length(findings)})")
    [heading | Enum.map(findings, &["\n", finding(&1, output)])]
  end

  defp finding(%Finding{} = finding, output) do
    severity = finding.severity |> to_string() |> String.upcase() |> String.pad_trailing(7)

    uncertain =
      if finding.verdict == :uncertain, do: [" ", muted(output, "(unverified)")], else: []

    [
      ["  ", Output.style(output, severity_role(finding.severity), severity), " "],
      [Output.style(output, :accent, location(finding.location)), "  ", finding.title, uncertain],
      ["\n", detail("Trigger", finding.trigger, output)],
      rule(finding.rule_id, output)
    ]
  end

  defp rule(nil, _output), do: []
  defp rule(rule_id, output), do: ["\n", detail("Rule", rule_id, output)]

  defp detail(label, text, output) do
    text = text |> String.split("\n") |> Enum.map_join(" ", &String.trim/1)
    [String.duplicate(" ", 10), muted(output, label <> ": "), text]
  end

  defp severity_role(severity) when severity in [:blocker, :high], do: :danger
  defp severity_role(:medium), do: :warning
  defp severity_role(_severity), do: :muted

  defp notes(summary, output) do
    lines =
      Enum.map(summary.failed_units, fn %{unit: unit, reason: reason} ->
        "Unit #{unit} was not reviewed: #{Delegation.format_error(reason)}"
      end) ++
        Enum.map(summary.incomplete_units, fn %{unit: unit, reason: reason} ->
          "Unit #{unit} was reviewed only in part (#{Delegation.format_error(reason)}); " <>
            "the findings reported before are kept"
        end) ++
        Enum.map(summary.verification_failures, fn %{reason: reason} ->
          "A finding could not be verified: #{Delegation.format_error(reason)}"
        end) ++
        Enum.map(summary.scoring_failures, fn %{reason: reason} ->
          "A finding kept its detector confidence: #{Delegation.format_error(reason)}"
        end) ++ summary.warnings

    case lines do
      [] ->
        []

      lines ->
        [
          Output.style(output, :warning, "Notes"),
          Enum.map(lines, &["\n  ", &1])
        ]
    end
  end

  defp summary(result, change, output) do
    summary = result.summary
    files = length(summary.files)

    reviewed =
      if summary.units == 0,
        do: "Nothing to review in #{describe_change(change)}",
        else:
          "Reviewed #{plural(files, "file")} in #{plural(summary.units, "unit")} " <>
            "(#{describe_change(change)}, #{summary.profile} profile)"

    counts =
      "#{summary.blocking} blocking, #{summary.optional} optional · " <>
        "#{plural(summary.candidates, "candidate")}, #{summary.rejected} rejected"

    skipped =
      case summary.skipped do
        [] -> []
        skipped -> ["\n", muted(output, "Skipped: " <> Enum.map_join(skipped, ", ", &skip/1))]
      end

    [
      verdict(summary.verdict, output),
      ["\n", muted(output, reviewed)],
      ["\n", muted(output, counts)],
      skipped,
      cost(summary, output)
    ]
  end

  @doc """
  Describes a review's total cost in one short phrase, such as
  `"12 model runs, 340.2k tokens (210.0k cached), 3m 5s"`, or `nil` when the
  summary has no stage statistics. Tokens count all input (uncached,
  cached, and cache writes) and output.
  """
  @spec cost_summary(map()) :: String.t() | nil
  def cost_summary(%{stages: stages} = summary) when map_size(stages) > 0 do
    runs = stages |> Map.values() |> Enum.map(& &1.runs) |> Enum.sum()
    usage = stages |> Map.values() |> Enum.map(& &1.usage) |> Usage.aggregate()
    total = prompt_tokens(usage) + (usage.output_tokens || 0)

    cached =
      case usage.cache_read_tokens do
        cached when is_integer(cached) and cached > 0 -> " (#{count(cached)} cached)"
        _none -> ""
      end

    "#{plural(runs, "model run")}, #{count(total)} tokens#{cached}, " <>
      duration(Map.get(summary, :duration_ms))
  end

  def cost_summary(_summary), do: nil

  # `Tackle.Lib.Usage` keeps uncached input, cache reads, and cache writes
  # in separate buckets; together they are the prompt.
  defp prompt_tokens(%Usage{} = usage),
    do:
      (usage.input_tokens || 0) + (usage.cache_read_tokens || 0) + (usage.cache_write_tokens || 0)

  # One line per stage that ran, then the total of all stages.
  defp cost(summary, output) do
    case stage_costs(summary) do
      [] ->
        []

      costs ->
        duration = duration(Map.get(summary, :duration_ms))
        lines = Enum.map(costs, fn {label, text} -> "  #{label}: " <> text end)
        Enum.map(["Cost (#{duration}):" | lines], &["\n", muted(output, &1)])
    end
  end

  @doc """
  Describes a review's cost per stage that ran, then in total, as
  `{label, text}` pairs such as `{"detector", "3 runs, 12.0k in, 1.2k out, 8.1s"}`.
  Empty when the summary has no stage statistics.
  """
  @spec stage_costs(map()) :: [{String.t(), String.t()}]
  def stage_costs(summary) when is_map(summary) do
    stages = Map.get(summary, :stages, %{})

    costs =
      for stage <- [:detector, :verifier, :scorer],
          stats = Map.get(stages, stage),
          stats != nil,
          do: {to_string(stage), describe_stage(stage, stats)}

    case costs do
      [] ->
        []

      costs ->
        duration = duration(Map.get(summary, :duration_ms))
        costs ++ [{"total", describe_total(stages, duration)}]
    end
  end

  defp describe_total(stages, duration) do
    runs = stages |> Map.values() |> Enum.map(& &1.runs) |> Enum.sum()
    usage = stages |> Map.values() |> Enum.map(& &1.usage) |> Usage.aggregate()
    "#{plural(runs, "model run")}, #{tokens(usage)}, #{duration}"
  end

  defp describe_stage(stage, stats) do
    noun = if stage == :scorer, do: "call", else: "run"
    failed = if stats.failed > 0, do: " (#{stats.failed} failed)", else: ""

    "#{plural(stats.runs, noun)}#{failed}, #{tokens(stats.usage)}, #{duration(stats.duration_ms)}"
  end

  defp tokens(%Usage{} = usage) do
    prompt = prompt_tokens(usage)

    cached =
      case usage.cache_read_tokens do
        cached when is_integer(cached) and cached > 0 ->
          " (#{count(cached)} cached, #{round(cached * 100 / prompt)}%)"

        _none ->
          ""
      end

    reasoning =
      case usage.reasoning_tokens do
        reasoning when is_integer(reasoning) and reasoning > 0 ->
          " (#{count(reasoning)} reasoning)"

        _none ->
          ""
      end

    "#{count(prompt)} in#{cached}, " <>
      "#{count(usage.output_tokens || 0)} out#{reasoning}"
  end

  defp tokens(_usage), do: "no usage reported"

  defp count(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp count(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp count(n), do: Integer.to_string(n)

  defp duration(nil), do: "?"
  defp duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"
  defp duration(ms), do: "#{div(ms, 60_000)}m #{rem(div(ms, 1_000), 60)}s"

  defp verdict(:blocking, output), do: Output.style(output, :danger, "Blocking findings found.")
  defp verdict(:optional, output), do: Output.style(output, :warning, "Only optional findings.")
  defp verdict(:clean, output), do: Output.style(output, :success, "No findings.")

  defp skip(%{path: path, reason: reason}),
    do: "#{path} (#{reason |> to_string() |> String.replace("_", " ")})"

  defp describe_change(%Change{mode: :staged}), do: "staged changes"

  defp describe_change(%Change{mode: :branch, base_ref: base_ref}),
    do: "changes since #{base_ref}"

  defp describe_change(%Change{head_sha: :worktree, base_ref: base_ref}),
    do: "#{base_ref} to the working tree"

  defp describe_change(%Change{base_ref: base_ref, head_sha: head}),
    do: "#{base_ref}..#{short(head)}"

  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
  defp short(other), do: to_string(other)

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"

  defp muted(output, text), do: Output.style(output, :muted, text)

  ## JSON

  defp json_change(%Change{} = change) do
    %{
      "mode" => to_string(change.mode),
      "root" => change.root,
      "base_ref" => change.base_ref,
      "base_sha" => change.base_sha,
      "head_sha" => to_string(change.head_sha)
    }
  end

  defp json_unit(%{unit: unit, reason: reason}),
    do: %{"unit" => unit, "reason" => Delegation.format_error(reason)}

  defp json_summary(summary) do
    %{
      "profile" => to_string(summary.profile),
      "samples" => summary.samples,
      "units" => summary.units,
      "files" => summary.files,
      "skipped" =>
        Enum.map(summary.skipped, &%{"path" => &1.path, "reason" => to_string(&1.reason)}),
      "failed_units" => Enum.map(summary.failed_units, &json_unit/1),
      "incomplete_units" => Enum.map(summary.incomplete_units, &json_unit/1),
      "detected" => summary.detected,
      "candidates" => summary.candidates,
      "confirmed" => summary.confirmed,
      "uncertain" => summary.uncertain,
      "rejected" => summary.rejected,
      "verification_failures" => Enum.map(summary.verification_failures, &json_failure/1),
      "scoring_failures" => Enum.map(summary.scoring_failures, &json_failure/1),
      "blocking" => summary.blocking,
      "optional" => summary.optional,
      "verdict" => to_string(summary.verdict),
      "warnings" => summary.warnings,
      "settings" => json_settings(Map.get(summary, :settings)),
      "stages" => json_stages(Map.get(summary, :stages, %{})),
      "duration_ms" => Map.get(summary, :duration_ms)
    }
  end

  defp json_settings(nil), do: nil

  defp json_settings(settings) do
    Map.new(settings, fn
      {key, value} when is_map(value) ->
        {to_string(key), Map.new(value, fn {stage, inner} -> {to_string(stage), inner} end)}

      {key, value} ->
        {to_string(key), value}
    end)
  end

  defp json_stages(stages) do
    Map.new(stages, fn {stage, stats} ->
      {to_string(stage),
       %{
         "runs" => stats.runs,
         "failed" => stats.failed,
         "duration_ms" => stats.duration_ms,
         "usage" => json_usage(stats.usage)
       }}
    end)
  end

  defp json_failure(%{fingerprint: fingerprint, reason: reason}),
    do: %{"fingerprint" => fingerprint, "reason" => Delegation.format_error(reason)}

  defp json_usage(%Usage{} = usage) do
    usage
    |> Map.take(@usage_fields)
    |> Enum.filter(fn {_field, value} -> is_number(value) or is_binary(value) end)
    |> Map.new(fn {field, value} -> {to_string(field), value} end)
  end

  defp json_usage(_usage), do: %{}
end
