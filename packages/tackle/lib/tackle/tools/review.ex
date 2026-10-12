defmodule Tackle.Tools.Review do
  @moduledoc """
  Opt-in tool that reviews the current code change with `Tackle.Review`,
  so an agent can review its own work and then fix what was found.

  The change is loaded from Git in the agent's working directory
  (`Tackle.Review.Change`, which reads the repository on the host even for
  a jailed agent, limited to the agent's workspace; see its documentation):
  by default the branch's changes
  against the default branch, committed or not; `staged` reviews the index;
  `range` a revision range. The result is a compact list of the shown
  findings, blocking first, with location, severity, trigger, explanation,
  and suggestion.

  The review's detector and verifier runs are delegated from the calling
  agent, like `Tackle.Tools.Subagent`, so the tool needs:

    * the host to add this module to the agent's tools;
    * a runtime handle with delegation granted;
    * the `review-detector` and `review-verifier` profiles among the
      scope's trusted profiles (as `Tackle.Coding` provides them).

  The runs count against the agent's child limit and stop when the tool
  call ends.

  ## History

  Each review is recorded in the repository's `Tackle.Review.History`, and
  findings the user dismissed are not reported again. Findings shown
  earlier are reported again, so a second review after a fix shows what is
  still wrong. Hosts configure history through the session context's
  `:review_history`: `false` disables it, a keyword list is passed to
  `Tackle.Review.History.open/2` (default `[]`, the process's
  `TACKLE_HOME`). When history is unavailable the review still runs and the
  result says so.
  """

  use Tackle.Lib.Tool

  alias Tackle.AgentScope.Coordinator
  alias Tackle.Executor
  alias Tackle.Review
  alias Tackle.Review.{Change, Delegation, Detector, Finding, History, Result, Verifier}
  alias Tackle.Runtime.{Handle, Registry}

  @profiles %{"quiet" => :quiet, "default" => :default, "assertive" => :assertive}

  tool_name("review_changes")

  description(
    "Review the current code change for bugs and project rule violations, and return the " <>
      "findings worth acting on (location, severity, trigger, explanation). By default it " <>
      "reviews everything the current branch changes against the default branch, " <>
      "committed or not; set `staged` to review only staged changes, or `range` for a Git " <>
      "revision range such as `main..HEAD`. Use it after making changes to check your work, " <>
      "then fix the blocking findings. Untracked files are not reviewed. The review runs " <>
      "several delegated agents and can take a while."
  )

  input do
    field(:range, :string,
      description:
        "Git revision range to review, such as `main..HEAD`, `a...b`, or a single revision " <>
          "compared with the working tree; omit to review the branch"
    )

    field(:staged, :boolean, description: "Review only the staged changes (index against HEAD)")

    field(:profile, :string,
      enum: Map.keys(@profiles) |> Enum.sort(),
      description:
        "quiet: blocking findings only; default: blocking and confident optional findings; " <>
          "assertive: everything plausible"
    )
  end

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, context) when is_map(args) and is_map(context) do
    with {:ok, handle} <- fetch_handle(context),
         :ok <- ensure_delegation(handle),
         {:ok, change} <- load_change(args, context) do
      {history, notes} = history(change, context)

      opts = [
        requester: handle,
        profiles: profiles(handle),
        profile: Map.fetch!(@profiles, Map.get(args, "profile") || "default"),
        history: history
      ]

      case Review.run(change, opts) do
        {:ok, result} -> {:ok, render(result, change, notes)}
        {:error, reason} -> {:error, "The review failed: " <> describe_error(reason)}
      end
    end
  end

  @impl true
  def model_error(reason) when is_binary(reason), do: reason
  def model_error(_reason), do: nil

  ## Setup

  defp fetch_handle(context) do
    case Handle.from_context(context) do
      %Handle{} = handle -> {:ok, handle}
      nil -> {:error, "review_changes is unavailable: this agent has no runtime handle"}
    end
  end

  defp ensure_delegation(%Handle{allow_delegation: true}), do: :ok

  defp ensure_delegation(%Handle{}),
    do: {:error, "review_changes needs delegation, which is not permitted for this agent"}

  defp load_change(args, context) do
    opts = [
      cwd: cwd(context),
      workspace: context |> Executor.from_context() |> Executor.workspace(),
      staged: Map.get(args, "staged") == true,
      range: Map.get(args, "range")
    ]

    case Change.load(opts) do
      {:ok, change} -> {:ok, change}
      {:error, reason} -> {:error, "Cannot load the change: " <> Change.format_error(reason)}
    end
  end

  defp cwd(%{cwd: cwd}) when is_binary(cwd), do: cwd
  defp cwd(%{"cwd" => cwd}) when is_binary(cwd), do: cwd
  defp cwd(_context), do: nil

  # The stage profiles come from the agent's own scope, resolved when the
  # review starts, so the tool can only use what the scope already allows.
  defp profiles(%Handle{scope_ref: scope_ref}) do
    Map.new([Detector.profile(), Verifier.profile()], fn name ->
      {name, fn -> resolve_profile(scope_ref, name) end}
    end)
  end

  defp resolve_profile(scope_ref, name) do
    case Registry.coordinator(scope_ref) do
      {:ok, coordinator} -> Coordinator.resolve_profile(coordinator, name)
      {:error, :not_found} -> {:error, :scope_not_found}
    end
  end

  defp history(change, context) do
    case Map.get(context, :review_history, []) do
      false ->
        {nil, []}

      opts when is_list(opts) ->
        case History.open(change.root, opts) do
          {:ok, history} ->
            {history, []}

          {:error, reason} ->
            {nil, ["Review history is unavailable: #{History.format_error(reason)}"]}
        end

      other ->
        {nil, ["Review history is misconfigured: #{inspect(other)}"]}
    end
  end

  ## Errors

  defp describe_error(:cancelled), do: "the review was cancelled"

  defp describe_error({:detection_failed, [%{reason: reason} | _rest] = failures}),
    do:
      "every review unit failed (#{length(failures)}); first: #{Delegation.format_error(reason)}"

  defp describe_error({:invalid_profile, name, _reason}),
    do: "the #{name} agent profile is not available in this session"

  defp describe_error({:missing_profile, name}),
    do: "the #{name} agent profile is not available in this session"

  defp describe_error({:missing_tool, name, tool}),
    do: "the #{name} agent profile must keep the #{tool} tool"

  defp describe_error({:requester_model_unavailable, reason}),
    do: "the review model is unavailable: #{inspect(reason)}"

  defp describe_error(reason), do: inspect(reason)

  ## Output

  defp render(%Result{} = result, change, notes) do
    summary = result.summary

    header =
      if summary.units == 0 do
        "Nothing to review in #{describe_change(change)}."
      else
        "Reviewed #{plural(length(summary.files), "file")} (#{describe_change(change)}): " <>
          "#{summary.blocking} blocking, #{summary.optional} optional finding(s)."
      end

    sections = [
      header,
      group("Blocking", result.blocking, 1),
      group("Optional", result.optional, length(result.blocking) + 1),
      notes_section(notes ++ result_notes(result))
    ]

    sections
    |> Enum.reject(&(&1 == nil))
    |> Enum.join("\n\n")
  end

  defp group(_label, [], _first), do: nil

  defp group(label, findings, first) do
    lines =
      findings
      |> Enum.with_index(first)
      |> Enum.map(fn {finding, number} -> finding(finding, number) end)

    Enum.join(["#{label}:" | lines], "\n")
  end

  defp finding(%Finding{} = finding, number) do
    rule = if finding.rule_id, do: ", rule #{finding.rule_id}", else: ""
    unverified = if finding.verdict == :uncertain, do: " (unverified)", else: ""

    [
      "#{number}. #{location(finding.location)} [#{finding.severity}, #{finding.category}#{rule}] " <>
        finding.title <> unverified,
      indent("Trigger: " <> finding.trigger),
      indent(finding.body),
      if(finding.suggestion, do: indent("Suggestion:\n" <> finding.suggestion))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("   " <> &1))
  end

  defp location(%{path: path, side: side, start_line: first, end_line: last}) do
    lines = if first == last, do: "#{first}", else: "#{first}-#{last}"
    suffix = if side == :old, do: " (removed lines)", else: ""
    "#{path}:#{lines}#{suffix}"
  end

  defp result_notes(%Result{summary: summary, dropped: dropped}) do
    known = Enum.count(dropped, &(&1.reason == :known))

    Enum.map(summary.failed_units, fn %{unit: unit, reason: reason} ->
      "Unit #{unit} was not reviewed: #{Delegation.format_error(reason)}"
    end) ++
      Enum.map(summary.verification_failures, fn %{reason: reason} ->
        "A finding could not be verified: #{Delegation.format_error(reason)}"
      end) ++
      if(known > 0, do: ["#{plural(known, "dismissed finding")} not reported again."], else: []) ++
      summary.warnings
  end

  defp notes_section([]), do: nil
  defp notes_section(notes), do: Enum.join(["Notes:" | Enum.map(notes, &("- " <> &1))], "\n")

  defp describe_change(%Change{mode: :staged}), do: "staged changes"
  defp describe_change(%Change{mode: :branch, base_ref: base}), do: "changes since #{base}"

  defp describe_change(%Change{head_sha: :worktree, base_ref: base}),
    do: "#{base} to the working tree"

  defp describe_change(%Change{base_ref: base, head_sha: head}),
    do: "#{base}..#{String.slice(to_string(head), 0, 12)}"

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"
end
