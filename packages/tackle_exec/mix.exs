defmodule Tackle.Exec.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_exec,
      version: "0.1.0",
      description: "Port-connected exec-server for running Tackle tool primitives in a jail",
      source_url: "https://github.com/Makesesama/tackle",
      package: [licenses: ["MIT"], links: %{"GitHub" => "https://github.com/Makesesama/tackle"}],
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
