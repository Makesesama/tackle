defmodule Tackle.CLI.Review do
  @moduledoc """
  The headless `tackle review` command.

  It composes the same coding scope as an interactive run, without a durable
  session, loads the change from Git (`Tackle.Review.Change`), and runs
  `Tackle.Review.run/2` from the root agent with the scope's trusted agent
  profiles. Progress goes to standard error line by line; the result goes to
  standard output as text or JSON.

  Each review is recorded in the repository's `Tackle.Review.History` under
  `TACKLE_HOME`, and findings dismissed there are not reported again.
  Findings shown by an earlier review are reported again, so the exit status
  always reflects every blocking finding that has not been dismissed.

  Exit status: `0` when no blocking finding is shown, `1` when one is, and
  `2` when the review could not run.
  """

  alias Tackle.CLI.Output
  alias Tackle.CLI.Output.Review, as: ReviewOutput
  alias Tackle.CLI.Output.ReviewProgress
  alias Tackle.CLI.Run
  alias Tackle.Executor
  alias Tackle.Review
  alias Tackle.Review.{Change, History, Result}

  @blocking_status 1
  @failure_status 2

  @typedoc "Parsed `tackle review` options; see `Tackle.CLI.Parser`."
  @type options :: %{
          required(:model) => String.t() | nil,
          required(:thinking) => String.t() | nil,
          required(:range) => String.t() | nil,
          required(:staged) => boolean(),
          required(:profile) => :quiet | :default | :assertive | nil,
          required(:samples) => pos_integer(),
          required(:format) => :text | :json,
          optional(:tuning) => keyword(),
          optional(:progress_device) => IO.device()
        }

  @doc """
  Runs the command and returns its exit status.

  `:progress_device` (default `:stderr`) receives the progress lines.
  """
  @spec run(options()) :: non_neg_integer()
  def run(opts) do
    output = output(opts.format)

    case Run.start_ephemeral_scope(opts.model, opts.thinking) do
      {:ok, scope, scope_spec} ->
        try do
          review(scope, scope_spec, opts, output)
        after
          Run.stop_scope(scope.scope_ref)
        end

      {:error, reason} ->
        failure(reason, output)
    end
  end

  @doc "Returns the exit status for a result: `1` when a blocking finding is shown, else `0`."
  @spec exit_status(Result.t()) :: 0 | 1
  def exit_status(%Result{blocking: [_ | _]}), do: @blocking_status
  def exit_status(%Result{}), do: 0

  defp review(scope, scope_spec, opts, output) do
    # The change is read on the host, within the scope's (jail) workspace.
    workspace = Executor.workspace(Executor.from_context(scope_spec.root_spec.config.context))

    load_opts = [
      cwd: File.cwd!(),
      workspace: workspace,
      staged: opts.staged,
      range: opts.range
    ]

    with {:ok, change} <- load_change(load_opts),
         {:ok, result} <- run_review(change, scope, scope_spec, opts) do
      Output.puts(output, ReviewOutput.render(result, change, output))
      exit_status(result)
    else
      {:error, reason} -> failure(reason, output)
    end
  end

  defp load_change(opts) do
    case Change.load(opts) do
      {:ok, change} -> {:ok, change}
      {:error, reason} -> {:error, {:change, reason}}
    end
  end

  # The review runs in a task so this process can print each event as it
  # arrives while keeping the progress state. Events are sent before the
  # task replies, so all of them are printed before the result.
  defp run_review(change, scope, scope_spec, opts) do
    parent = self()
    tag = make_ref()
    device = Map.get(opts, :progress_device, :stderr)

    review_opts =
      [
        requester: scope.root_agent_ref,
        profiles: scope_spec.profiles,
        samples: opts.samples,
        history: history(change, device),
        on_event: &send(parent, {tag, &1})
      ] ++ profile_option(opts.profile) ++ Map.get(opts, :tuning, [])

    task = Task.async(fn -> Review.run(change, review_opts) end)
    await_review(task, tag, ReviewProgress.new(), device)
  end

  # Without `--profile`, the review applies the configured one.
  defp profile_option(nil), do: []
  defp profile_option(profile), do: [profile: profile]

  # History is an aid: without it the review still runs.
  defp history(change, device) do
    case History.open(change.root) do
      {:ok, history} ->
        history

      {:error, reason} ->
        IO.puts(device, "Review history is unavailable: #{History.format_error(reason)}")
        nil
    end
  end

  defp await_review(task, tag, progress, device) do
    receive do
      {^tag, event} ->
        {line, progress} = ReviewProgress.event(progress, event)
        if line, do: IO.puts(device, line)
        await_review(task, tag, progress, device)

      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        result
    end
  end

  defp failure(reason, output) do
    error_output = %{output | device: :stderr}
    Output.puts(error_output, ReviewOutput.render_error(reason, error_output))
    @failure_status
  end

  defp output(:json), do: Output.new(format: :json)
  defp output(:text), do: Output.new(format: :human)
end
