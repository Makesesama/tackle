defmodule Mix.Tasks.Tackle do
  use Mix.Task

  @cli_project Path.expand("../../../frontends/tackle_cli", __DIR__)

  @shortdoc "Runs the Tackle CLI in the development environment"
  @moduledoc """
  Runs the CLI frontend from the repository root while keeping its dependencies
  in the separate `frontends/tackle_cli` Mix project.

      mix tackle
      mix tackle run "Inspect this project"
      mix tackle auth status

  Arguments, terminal input, terminal output, and the CLI exit status are passed
  through to the frontend's `mix tackle` task.
  """

  @requirements ["compile"]

  @impl Mix.Task
  def run(args) do
    cond do
      Mix.Project.config()[:app] == :tackle_cli ->
        run_cli(args)

      args == ["auth", "login", "deepseek"] ->
        login_deepseek()

      true ->
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

  # The delegated frontend process does not own the parent Mix process's input
  # device, so interactive credentials must be read before delegation.
  defp login_deepseek do
    with {:ok, _apps} <- Application.ensure_all_started(:tackle),
         {:ok, api_key} <- read_deepseek_api_key(),
         :ok <- Tackle.Auth.put("deepseek", %{"api_key" => api_key}) do
      Mix.shell().info("Stored credentials for deepseek.")
    else
      {:error, reason} -> Mix.raise("could not store DeepSeek credentials: #{inspect(reason)}")
    end
  end

  defp read_deepseek_api_key do
    Mix.shell().prompt("DeepSeek API key: ")
    |> normalize_api_key()
  end

  defp normalize_api_key(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :empty_api_key}
      api_key -> {:ok, api_key}
    end
  end

  defp normalize_api_key(_value), do: {:error, :secret_input_eof}
end
