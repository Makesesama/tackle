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
      extra_applications: [:logger, :tackle_codex, :tackle_deepseek, :tackle]
    ]
  end

  defp deps do
    [
      {:tackle, path: "../.."},
      {:tackle_codex, path: "../../plugins/tackle_codex"},
      {:tackle_deepseek, path: "../../plugins/tackle_deepseek"},
      {:optimus, "~> 0.6"},
      {:owl, "~> 0.13"},
      {:ucwidth, "~> 0.2"},
      {:ex_ratatui,
       git: "ssh://git@git.makussu.de:2122/Makussu/ex_ratatui.git",
       ref: "410c2e7a99be4f546eaafd222dafe4e0b99b25a0"},
      {:rustler, ">= 0.0.0"}
    ]
  end

  defp escript do
    [main_module: Tackle.CLI.Main, name: "tackle"]
  end
end
