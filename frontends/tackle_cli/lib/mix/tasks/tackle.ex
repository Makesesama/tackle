defmodule Mix.Tasks.Tackle do
  use Mix.Task

  @shortdoc "Runs the Tackle CLI in the development environment"
  @moduledoc """
  Runs the Tackle CLI through Mix so development dependencies, including native
  libraries, remain available on the filesystem.

      mix tackle
      mix tackle run "Inspect this project"
      mix tackle auth status

  Arguments are passed unchanged to the CLI parser.
  """

  @requirements ["compile"]

  @impl Mix.Task
  def run(args) do
    case Tackle.CLI.Main.main(args) do
      0 -> :ok
      status -> System.halt(status)
    end
  end
end
