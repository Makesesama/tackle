defmodule Mix.Tasks.Tackle do
  use Mix.Task

  @cli_project Path.expand("../../../../../apps/tackle_cli", __DIR__)

  @shortdoc "Runs the Tackle CLI in the development environment"
  @moduledoc """
  Runs the CLI application while keeping its dependencies in the separate
  `apps/tackle_cli` Mix project.

      mix tackle
      mix tackle run "Inspect this project"
      mix tackle auth status

  Outside `apps/tackle_cli`, the arguments are passed to the frontend's
  `mix tackle` task in a separate `mix` process, and its exit status becomes
  this task's. That process does not own this one's terminal input, so
  interactive commands such as `auth login` belong in the CLI project, where
  this task calls the CLI in-process and the adapter's own prompts read the
  terminal:

      cd apps/tackle_cli && mix tackle auth login ID
  """

  @requirements ["compile"]

  @impl Mix.Task
  def run(args) do
    if Mix.Project.config()[:app] == :tackle_cli do
      run_cli(args)
    else
      run_frontend(args)
    end
  end

  defp run_frontend(args) do
    unless File.regular?(Path.join(@cli_project, "mix.exs")) do
      Mix.raise("Tackle CLI project not found at #{@cli_project}")
    end

    mix = System.find_executable("mix") || Mix.raise("could not find the mix executable")

    port =
      Port.open(
        {:spawn_executable, mix},
        [
          :nouse_stdio,
          :exit_status,
          {:cd, @cli_project},
          {:args, ["tackle" | args]}
        ]
      )

    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> System.halt(status)
    end
  end

  defp run_cli(args) do
    # Resolved at runtime: the CLI entrypoint lives in the frontend project,
    # which is not compiled as part of the root harness.
    module = Module.concat(Tackle.CLI, Main)

    case module.main(args) do
      0 -> :ok
      status -> System.halt(status)
    end
  end
end
