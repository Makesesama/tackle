defmodule Tackle.CLI.ReviewRules do
  @moduledoc """
  The `tackle review rules` command: checks the review rules in effect in
  the current directory and prints them, with the rule files that do not
  load and why.

  It runs `Tackle.LocalReview.Rules.check/1`, the check behind the agent's
  `check_review_rules` tool, and prints `Tackle.LocalReview.Rules.format_check/1`'s
  text, so a person and an agent see the same result. As in a session,
  project rules are read through the session executor (the jail when
  `TACKLE_EXEC_LAUNCHER` is set), and the built-in rules are those
  `review.default_rules` selects in `config.json` and the project's
  `.tackle/config.json`.

  Exit status: `0` when every rule file loads, `1` when one does not, and
  `2` when the check could not run.
  """

  alias Tackle.CLI.Distribution
  alias Tackle.CLI.Output.Review, as: ReviewOutput
  alias Tackle.Config.Sources
  alias Tackle.Executor
  alias Tackle.LocalReview.Rules, as: RuleDiscovery
  alias Tackle.Review.Settings, as: ReviewSettings

  @problem_status 1
  @failure_status 2

  @doc """
  Runs the check and returns the exit status.

  Options, for tests: `:env` (default: the process environment) and `:cwd`
  (default: the current directory). The report goes to standard output,
  errors to standard error.
  """
  @spec run(keyword()) :: non_neg_integer()
  def run(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    cwd = opts |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> Path.expand()

    with {:ok, executor} <- Tackle.CLI.Jail.ensure_started(env: env, cwd: cwd),
         executor = executor || Executor.local(),
         {:ok, builtin_rules} <- builtin_rules(env, cwd, executor) do
      check =
        RuleDiscovery.check(
          [cwd: cwd, executor: executor, builtin_rules: builtin_rules] ++
            Tackle.Paths.homes(env: env)
        )

      IO.puts(RuleDiscovery.format_check(check))
      if check.warnings == [], do: 0, else: @problem_status
    else
      {:error, reason} ->
        IO.puts(:stderr, "error: " <> ReviewOutput.format_error(reason))
        @failure_status
    end
  end

  # The configuration files are read as a session reads them, without its
  # instruction files and skills; an invalid `review` object fails the
  # check as it would fail the session.
  defp builtin_rules(env, cwd, executor) do
    with {:ok, adapters} <- Distribution.adapters(),
         {:ok, sources} <-
           Sources.read(
             env: env,
             cwd: cwd,
             available_adapters: adapters,
             instructions: false,
             overrides: [context: %{executor: executor}]
           ),
         {:ok, settings} <-
           ReviewSettings.new(Keyword.get(sources.file_options, :review), sources.providers) do
      case settings do
        %ReviewSettings{default_rules: ids} when is_list(ids) -> {:ok, ids}
        _none -> {:ok, :all}
      end
    end
  end
end
