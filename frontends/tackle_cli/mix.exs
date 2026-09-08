defmodule Tackle.CLI.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_cli,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :tackle]
    ]
  end

  defp deps do
    [
      {:tackle, path: "../.."},
      {:optimus, "~> 0.6"},
      {:ex_ratatui, "~> 0.13"}
    ]
  end

  defp escript do
    [main_module: Tackle.CLI.Main]
  end
end
