defmodule Tackle.Lib.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_lib,
      version: "0.1.0",
      description: "Provider-independent agent loop and extension contracts for Elixir",
      source_url: "https://github.com/Makesesama/tackle",
      package: [licenses: ["MIT"], links: %{"GitHub" => "https://github.com/Makesesama/tackle"}],
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jsv, "~> 0.22"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
