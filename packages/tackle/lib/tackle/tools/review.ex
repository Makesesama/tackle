defmodule Tackle.Tools.Review do
  @moduledoc """
  Opt-in tool that reviews the current code change with `Tackle.Review`,
  so an agent can review its own work and then fix what was found. It runs
  the review through `Tackle.LocalReview`, so the session's review settings,
  the user's and project's rules (read through the session executor), and
  the history apply.

  Rules and history are found with the session's homes
  (`Tackle.Config.homes/1`).

  The change is loaded from Git in the agent's working directory
  (`Tackle.Review.Change`, which reads the repository on the host even for
  a jailed agent, limited to the agent's workspace; see its documentation):
  by default the branch's changes
  against the default branch, committed or not; `staged` reviews the index;
  `range` a revision range. The result is a compact list of the shown
  findings, blocking first, with location, severity, trigger, explanation,
  and suggestion. Verified findings the review profile's thresholds or cap
  keep out of that list (`Tackle.Review.Result.hidden/1`) follow in a
  short `Verified but not shown under the <profile> profile:` section,
  one `- ` line each with the reason and an indented trigger (at most
  ten), so a verdict the review reported while running never
  disappears without a trace.

  The review's detector and verifier runs are delegated from the calling
  agent, like `Tackle.Tools.Subagent`, so the tool needs:

    * the host to add this module to the agent's tools;
    * delegation granted to the agent by its scope;
    * the `review-detector` and `review-verifier` profiles among the
      scope's trusted profiles (as `Tackle.Coding` provides them).

  The runs count against the agent's child limit, which is also how many
  the review keeps in flight (see `Tackle.Review`), and stop when the tool
  call ends.

  ## History

  Each review is recorded in the repository's `Tackle.LocalReview.History`, and
  findings the user dismissed are not reported again. Findings shown
  earlier are reported again, so a second review after a fix shows what is
  still wrong. Hosts configure history through the session context's
  `:review_history`: `false` disables it, a keyword list is passed to
  `Tackle.LocalReview.History.open/2` (default `[]`, the session's Tackle
  home). When history is unavailable the review still runs and the result
  says so.

  ## Progress

  When the session context carries an `:event_callback`, the tool reports
  the review while it runs as `:tool_progress` events whose data holds the
  call's `:tool_call_id`, `name: "review_changes"`, and a `:review` map
  with a `:kind` (instead of the textual `:delta` other tools stream):

    * `:loaded` - `target` (what is reviewed), `files`, `additions`,
      `deletions`, and `profile`, once the change is loaded;
    * `:started` - `units`, how many review units the change splits into;
    * `:unit` - `unit` id and `status` (`:started`, `:done`, `:failed`,
      the latter with an `error` text);
    * `:candidate` - a `finding` sent to the verifier: `fingerprint`,
      `title`, `severity`, `category`, and `location`;
    * `:verdict` - the candidate's `fingerprint` and `verdict`;
    * `:done` - the `summary` counts: `units`, `files`, `candidates`,
      `confirmed`, `uncertain`, `rejected`, `blocking`, `optional`, and
      `duration_ms`.

  The data is plain maps of strings, numbers, and atoms, so frontends can
  forward it as JSON. The result text stays the model-facing contract;
  frontends may read its finding lines
  (`N. path:line [severity, category, rule ID] title`) to draw a settled
  call.
  """

  use Tackle.Lib.Tool

  alias Tackle.Config
  alias Tackle.Executor
  alias Tackle.Lib.Tool
  alias Tackle.LocalReview
  alias Tackle.Review.{Change, Delegation, Detector, Finding, Rank, Result, Verifier}
  alias Tackle.Review.Settings, as: ReviewSettings
  alias Tackle.Runtime
  alias Tackle.Runtime.AgentRef

  @profiles %{"quiet" => :quiet, "default" => :default, "assertive" => :assertive}
  @hidden_limit 10
  @hidden_heading "Verified but not shown under the"

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
          "assertive: everything plausible. Omit to use the configured default"
    )
  end

  @spec run(map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(args, context) when is_map(args) and is_map(context) do
    with {:ok, agent_ref} <- fetch_agent_ref(context),
         :ok <- ensure_delegation(agent_ref),
         {:ok, change} <- load_change(args, context) do
      homes = Config.homes(context)
      {history, notes} = history(change, context, homes[:home])
      profile = profile(args, context)
      report = reporter(context)
      report.(loaded(change, Atom.to_string(profile)))

      opts =
        [
          requester: agent_ref,
          profiles: profiles(agent_ref),
          profile: profile,
          executor: Executor.from_context(context),
          history: history,
          on_event: &report_event(report, &1)
        ] ++ homes

      case LocalReview.run(change, opts) do
        {:ok, result} -> {:ok, format_result(result, change, notes)}
        {:error, reason} -> {:error, "The review failed: " <> describe_error(reason)}
      end
    end
  end

  ## Setup

  defp fetch_agent_ref(context) do
    case AgentRef.from_context(context) do
      %AgentRef{} = agent_ref -> {:ok, agent_ref}
      nil -> {:error, "review_changes is unavailable: this agent has no runtime reference"}
    end
  end

  defp ensure_delegation(agent_ref) do
    case Runtime.delegation_limits(agent_ref) do
      {:ok, _limits} ->
        :ok

      {:error, :delegation_not_allowed} ->
        {:error, "review_changes needs delegation, which is not permitted for this agent"}

      {:error, reason} ->
        {:error, "review_changes is unavailable: #{inspect(reason)}"}
    end
  end

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

  # The model's choice, then the session's review settings, then `:default`.
  defp profile(args, context) do
    Map.get(@profiles, Map.get(args, "profile")) || configured_profile(context) || :default
  end

  defp configured_profile(%{review_settings: %ReviewSettings{profile: profile}}), do: profile
  defp configured_profile(_context), do: nil

  defp cwd(%{cwd: cwd}) when is_binary(cwd), do: cwd
  defp cwd(%{"cwd" => cwd}) when is_binary(cwd), do: cwd
  defp cwd(_context), do: nil

  # The stage profiles come from the agent's own scope, resolved when the
  # review starts, so the tool can only use what the scope already allows.
  defp profiles(agent_ref) do
    Map.new([Detector.profile(), Verifier.profile()], fn name ->
      {name, fn -> Runtime.resolve_profile(agent_ref, name) end}
    end)
  end

  defp history(change, context, home) do
    case Map.get(context, :review_history, []) do
      false ->
        {nil, []}

      opts when is_list(opts) ->
        LocalReview.open_history(change, Keyword.put_new(opts, :home, home))

      other ->
        {nil, ["Review history is misconfigured: #{inspect(other)}"]}
    end
  end

  ## Progress

  defp reporter(context) do
    fn review -> Tool.progress(context, %{name: "review_changes", review: review}) end
  end

  defp loaded(%Change{} = change, profile) do
    files = change.diff.files

    %{
      kind: :loaded,
      target: describe_change(change),
      files: length(files),
      additions: files |> Enum.map(& &1.additions) |> Enum.sum(),
      deletions: files |> Enum.map(& &1.deletions) |> Enum.sum(),
      profile: profile
    }
  end

  defp report_event(report, event) do
    case progress(event) do
      nil -> :ok
      review -> report.(review)
    end
  end

  defp progress({:started, %{units: units}}), do: %{kind: :started, units: units}

  defp progress({:unit, id, {:failed, reason}}),
    do: %{kind: :unit, unit: id, status: :failed, error: Delegation.format_error(reason)}

  defp progress({:unit, id, status}) when status in [:started, :done],
    do: %{kind: :unit, unit: id, status: status}

  defp progress({:candidate, %Finding{} = finding}) do
    %{
      kind: :candidate,
      finding: %{
        fingerprint: finding.fingerprint,
        title: finding.title,
        severity: finding.severity,
        category: finding.category,
        location: Map.take(finding.location, [:path, :side, :start_line, :end_line])
      }
    }
  end

  defp progress({:verdict, fingerprint, verdict}),
    do: %{kind: :verdict, fingerprint: fingerprint, verdict: verdict}

  defp progress({:done, %Result{summary: summary}}) do
    counts =
      Map.take(summary, [
        :units,
        :candidates,
        :confirmed,
        :uncertain,
        :rejected,
        :blocking,
        :optional,
        :duration_ms
      ])

    %{kind: :done, summary: Map.put(counts, :files, length(summary.files))}
  end

  defp progress(_event), do: nil

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

  @doc """
  The tool's result text for `result`: a headline, the blocking and
  optional findings with their details, and `notes` followed by the
  review's own notes. Frontends parse its headline and finding lines to
  draw a settled call (see the moduledoc's Progress section).
  """
  @spec format_result(Result.t(), Change.t(), [String.t()]) :: String.t()
  def format_result(%Result{} = result, %Change{} = change, notes) when is_list(notes) do
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
      hidden_section(Result.hidden(result), summary.profile),
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

  # Verified findings the profile's thresholds or cap kept out of the
  # lists above. Listing them keeps the result consistent with the verdicts
  # the review reported while it ran, and lets the agent judge them.
  defp hidden_section([], _profile), do: nil

  defp hidden_section(hidden, profile) do
    {listed, rest} = Enum.split(hidden, @hidden_limit)

    lines =
      Enum.map(listed, fn %{finding: finding, reason: reason} ->
        "- #{location(finding.location)} [#{finding.severity}, #{finding.category}] " <>
          "#{finding.title} (#{hidden_reason(finding, reason, profile)})\n" <>
          indent("Trigger: " <> finding.trigger)
      end)

    more = if rest == [], do: [], else: ["- … and #{length(rest)} more"]
    Enum.join([@hidden_heading <> " #{profile} profile:" | lines ++ more], "\n")
  end

  defp hidden_reason(finding, :below_threshold, profile) do
    lane = if finding.blocking, do: :blocking, else: :optional
    %{min_confidence: min} = Map.fetch!(Rank.thresholds(profile), lane)

    "#{finding.verdict}, confidence #{decimal(finding.confidence)} below " <>
      "the #{lane} threshold #{decimal(min)}"
  end

  defp hidden_reason(_finding, :uncertain, _profile),
    do: "unverified; the profile shows only confirmed findings in this lane"

  defp hidden_reason(finding, :over_cap, profile),
    do: "#{finding.verdict}, over the cap of #{Rank.thresholds(profile).cap} findings"

  defp hidden_reason(_finding, :hidden_lane, _profile),
    do: "the profile hides optional findings"

  defp hidden_reason(finding, reason, _profile), do: "#{finding.verdict}, #{reason}"

  defp decimal(number), do: :erlang.float_to_binary(number / 1, decimals: 2)

  defp result_notes(%Result{summary: summary, dropped: dropped}) do
    known = Enum.count(dropped, &(&1.reason == :known))
    scoring_failures = Map.get(summary, :scoring_failures, [])

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
      scoring_notes(scoring_failures) ++
      if(known > 0, do: ["#{plural(known, "dismissed finding")} not reported again."], else: []) ++
      summary.warnings
  end

  defp scoring_notes([]), do: []

  defp scoring_notes([%{reason: reason} | _rest] = failures) do
    [
      "#{plural(length(failures), "finding")} could not be scored and kept the " <>
        "detector's confidence: #{reason |> Delegation.format_error() |> String.slice(0, 200)}"
    ]
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
