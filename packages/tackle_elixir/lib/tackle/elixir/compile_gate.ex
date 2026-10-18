defmodule Tackle.Elixir.CompileGate do
  @moduledoc """
  A `Tackle.Lib.Hook` that checks whether the agent's changes compile
  before its turn ends.

  The gate compiles in the project's node (`Tackle.Elixir.ProjectNodes`),
  which runs where the agent's commands run, in the jail when the session is
  jailed, and returns the compiler's diagnostics as data.

  It watches the `edit` and `write` tools. Before the first change in a turn
  to an Elixir source of a Mix project, it compiles the project to record the
  diagnostics that already exist (the baseline). When the model gives its
  final answer, it compiles each changed project again. Errors and warnings
  that are not in the baseline are sent back as one user message and the turn
  continues, so the model can repair them; the turn completes when the
  project has nothing new to report, or after `max_rounds` continuations. A
  diagnostic keeps its identity when edits move it to another line. Without
  a baseline (the node could not start or compile in time) only errors are
  reported.

  The gate stays quiet otherwise: a project whose node cannot start or load
  it, or whose compile times out, is skipped, not reported, and a cancelled
  turn stops waiting for the compile.

  Changes made through `bash` are not watched; a turn that only edits files
  with shell commands is not checked.

  ## Configuration

  The hook reads `Tackle.Elixir.CompileGate.Settings` from the context key
  `:compile_gate`; without settings, or with `enabled: false`, it does
  nothing. It keeps its per-turn state under `:compile_gate_turn` and removes
  it in `after_turn/2`. With a `log_path`, every baseline and check is
  appended to that file as a JSON line, so the gate's decisions can be
  reviewed later.
  """

  @behaviour Tackle.Lib.Hook

  alias Tackle.Elixir.CompileGate.Settings
  alias Tackle.Elixir.Diagnostic
  alias Tackle.Elixir.Project
  alias Tackle.Elixir.ProjectNodes
  alias Tackle.Executor
  alias Tackle.Lib.State
  alias Tackle.Lib.Tool.Call

  @settings_key :compile_gate
  @turn_key :compile_gate_turn
  @file_tools ["edit", "write"]
  @max_reported 20
  @max_message_bytes 12_000

  @impl true
  def before_tool_call(%State{} = state, %Call{name: name} = call, context)
      when name in @file_tools do
    with %Settings{enabled: true} = settings <- Map.get(context, @settings_key),
         {:ok, file} <- changed_file(call, context),
         true <- Project.elixir_file?(file),
         executor = Executor.from_context(context),
         {:ok, root} <- Project.root(executor, file),
         true <- Project.compile_input?(Path.relative_to(file, root)) do
      turn = Map.get(context, @turn_key, %{projects: %{}, rounds: 0})
      turn = track(turn, root, %{state: state, settings: settings, context: context})
      {:ok, Map.put(context, @turn_key, turn)}
    else
      _not_tracked -> :ok
    end
  end

  def before_tool_call(_state, _call, _context), do: :ok

  @impl true
  def before_turn_end(%State{} = state, context) do
    with %Settings{enabled: true} = settings <- Map.get(context, @settings_key),
         %{projects: projects, rounds: rounds} = turn when map_size(projects) > 0 <-
           Map.get(context, @turn_key) do
      run = %{state: state, settings: settings, context: context}

      case check_projects(projects, run) do
        :cancelled -> :ok
        checks -> decide(checks, turn, rounds, run)
      end
    else
      _nothing_to_check -> :ok
    end
  end

  @impl true
  def after_turn(_state, %{@turn_key => _turn} = context),
    do: {:ok, Map.delete(context, @turn_key)}

  def after_turn(_state, _context), do: :ok

  # -- Tracking changes -------------------------------------------------------

  defp changed_file(%Call{arguments: arguments}, context) when is_map(arguments) do
    case Map.get(arguments, "path", Map.get(arguments, :path)) do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path, cwd(context))}
      _missing -> :error
    end
  end

  defp changed_file(_call, _context), do: :error

  defp track(%{projects: projects} = turn, root, run) do
    if Map.has_key?(projects, root),
      do: turn,
      else: %{turn | projects: Map.put(projects, root, baseline(root, run))}
  end

  defp baseline(root, run) do
    {result, duration_ms} = timed(fn -> compile(root, run) end)

    {baseline, outcome} =
      case result do
        {:ok, %{diagnostics: diagnostics}} ->
          {MapSet.new(diagnostics, &key/1), "ok"}

        {:error, reason} ->
          {:unavailable, error_outcome(reason)}
      end

    log(run, %{
      "event" => "baseline",
      "project" => root,
      "outcome" => outcome,
      "errors" => count(result, :error),
      "warnings" => count(result, :warning),
      "duration_ms" => duration_ms
    })

    baseline
  end

  # -- Checking at the end of the turn ---------------------------------------

  defp check_projects(projects, run) do
    projects
    |> Enum.sort()
    |> Enum.reduce_while([], fn {root, baseline}, checks ->
      case check(root, baseline, run) do
        :cancelled -> {:halt, :cancelled}
        check -> {:cont, [check | checks]}
      end
    end)
    |> case do
      :cancelled -> :cancelled
      checks -> Enum.reverse(checks)
    end
  end

  defp check(root, baseline, run) do
    {result, duration_ms} = timed(fn -> compile(root, run) end)

    case result do
      {:error, :cancelled} ->
        :cancelled

      {:error, reason} ->
        %{root: root, outcome: error_outcome(reason), new: [], duration_ms: duration_ms}

      {:ok, %{diagnostics: diagnostics}} ->
        new = diagnostics |> reportable() |> new_diagnostics(baseline, run.settings)
        %{root: root, outcome: :checked, new: new, duration_ms: duration_ms}
    end
  end

  # Errors and warnings only, and without the "cannot compile module ...
  # (errors have been logged)" error that repeats the errors of its file.
  defp reportable(diagnostics) do
    files_with_errors =
      for %Diagnostic{severity: :error, file: file} = diagnostic <- diagnostics,
          not logged_summary?(diagnostic),
          into: MapSet.new(),
          do: file

    Enum.filter(diagnostics, fn diagnostic ->
      diagnostic.severity in [:error, :warning] and
        not (logged_summary?(diagnostic) and diagnostic.file in files_with_errors)
    end)
  end

  defp logged_summary?(%Diagnostic{severity: :error, message: message}),
    do: String.contains?(message, "(errors have been logged)")

  defp logged_summary?(_diagnostic), do: false

  defp new_diagnostics(diagnostics, :unavailable, _settings),
    do: diagnostics |> Enum.filter(&(&1.severity == :error)) |> Enum.uniq_by(&key/1)

  defp new_diagnostics(diagnostics, baseline, %Settings{warnings: warnings}) do
    diagnostics
    |> Enum.filter(&(warnings or &1.severity == :error))
    |> Enum.reject(&MapSet.member?(baseline, key(&1)))
    |> Enum.uniq_by(&key/1)
  end

  # A diagnostic's identity across compiles: line and column numbers are left
  # out, also inside the message (type warnings cite `file:line:column`), so a
  # warning that edits move to another line is the same warning.
  defp key(%Diagnostic{severity: severity, file: file, message: message}),
    do: {severity, file, String.replace(message, ~r/:\d+(:\d+)?/, "")}

  defp decide(checks, turn, rounds, run) do
    # Projects with errors first, so their errors are not crowded out of the
    # message by another project's warnings.
    reported =
      checks
      |> Enum.filter(&(&1.new != []))
      |> Enum.sort_by(fn check ->
        if Enum.any?(check.new, &(&1.severity == :error)), do: 0, else: 1
      end)

    continue? = reported != [] and rounds < run.settings.max_rounds

    Enum.each(checks, fn check ->
      log(run, %{
        "event" => "check",
        "project" => check.root,
        "outcome" => check_outcome(check, continue?),
        "round" => rounds,
        "errors" => Enum.count(check.new, &(&1.severity == :error)),
        "warnings" => Enum.count(check.new, &(&1.severity == :warning)),
        "duration_ms" => check.duration_ms
      })
    end)

    if continue? do
      message = message(reported, cwd(run.context))
      {:continue, [message], Map.put(run.context, @turn_key, %{turn | rounds: rounds + 1})}
    else
      :ok
    end
  end

  defp check_outcome(%{outcome: :checked, new: []}, _continue?), do: "passed"
  defp check_outcome(%{outcome: :checked}, true), do: "blocked"
  defp check_outcome(%{outcome: :checked}, false), do: "not_blocked"
  defp check_outcome(%{outcome: outcome}, _continue?), do: outcome

  # -- The message -------------------------------------------------------------

  defp message(reported, cwd) do
    sections =
      reported
      |> Enum.map(fn check ->
        texts = check.new |> Enum.sort_by(&severity_rank/1) |> Enum.map(&format(&1, check.root))
        {check, texts}
      end)
      |> limit_diagnostics()
      |> Enum.map(fn {check, shown, total} -> section(check, shown, total, cwd) end)

    Enum.join(
      [
        "Compile check: `mix compile` reports problems that were not there before " <>
          "the changes in this turn."
        | sections
      ],
      "\n\n"
    )
  end

  # Errors first, then at most @max_reported diagnostics and about
  # @max_message_bytes of their text across all projects.
  defp limit_diagnostics(checks) do
    {limited, _budget} =
      Enum.map_reduce(checks, {@max_reported, @max_message_bytes}, fn {check, diagnostics},
                                                                      budget ->
        {shown, budget} = take_within(diagnostics, budget, [])
        {{check, shown, length(diagnostics)}, budget}
      end)

    limited
  end

  defp take_within([text | rest], {count, bytes}, shown)
       when count > 0 and (shown == [] or byte_size(text) <= bytes) do
    take_within(rest, {count - 1, bytes - byte_size(text)}, [text | shown])
  end

  defp take_within(_rest, budget, shown), do: {Enum.reverse(shown), budget}

  defp section(check, shown, total, cwd) do
    errors = Enum.count(check.new, &(&1.severity == :error))
    warnings = Enum.count(check.new, &(&1.severity == :warning))
    heading = "In #{display_root(check.root, cwd)}: #{counts(errors, warnings)}"
    hidden = total - length(shown)

    [heading | shown]
    |> then(fn parts ->
      if hidden > 0,
        do: parts ++ ["(#{plural(hidden, "more diagnostic")} not shown)"],
        else: parts
    end)
    |> Enum.join("\n\n")
  end

  defp display_root(root, cwd) do
    case Path.relative_to(root, cwd) do
      ^root -> root
      "." -> "the project"
      relative -> relative
    end
  end

  defp counts(errors, 0), do: plural(errors, "new error")
  defp counts(0, warnings), do: plural(warnings, "new warning")

  defp counts(errors, warnings),
    do: "#{plural(errors, "new error")}, #{plural(warnings, "new warning")}"

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"

  # Like the compiler prints it, with the file relative to the project.
  defp format(%Diagnostic{} = diagnostic, root) do
    location =
      case {diagnostic.file, diagnostic.line, diagnostic.column} do
        {nil, _line, _column} -> nil
        {file, nil, _column} -> Path.relative_to(file, root)
        {file, line, nil} -> "#{Path.relative_to(file, root)}:#{line}"
        {file, line, column} -> "#{Path.relative_to(file, root)}:#{line}:#{column}"
      end

    text = "#{diagnostic.severity}: #{String.trim_trailing(diagnostic.message)}"
    if location, do: text <> "\n  └─ " <> location, else: text
  end

  defp severity_rank(%Diagnostic{severity: :error}), do: 0
  defp severity_rank(%Diagnostic{severity: :warning}), do: 1

  # -- Helpers -------------------------------------------------------------

  defp compile(root, run) do
    ProjectNodes.compile(Executor.from_context(run.context), root,
      timeout_ms: run.settings.timeout_ms,
      cancellation_signal: Map.get(run.context, :cancellation_signal)
    )
  end

  defp error_outcome(:timeout), do: "timeout"
  defp error_outcome(:cancelled), do: "cancelled"
  defp error_outcome(_reason), do: "unavailable"

  defp count({:ok, %{diagnostics: diagnostics}}, severity),
    do: Enum.count(diagnostics, &(&1.severity == severity))

  defp count(_result, _severity), do: nil

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  defp cwd(context) do
    case Map.get(context, :cwd) do
      cwd when is_binary(cwd) -> Path.expand(cwd)
      _other -> File.cwd!()
    end
  end

  # The log is a convenience for reviewing the gate; failing to write it never
  # affects the turn.
  defp log(%{settings: %Settings{log_path: nil}}, _entry), do: :ok

  defp log(%{settings: %Settings{log_path: path}, state: state}, entry) do
    line =
      entry
      |> Map.merge(%{
        "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "session_id" => state.session_id
      })
      |> JSON.encode!()

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, [line, ?\n], [:append])
    end

    :ok
  end
end
