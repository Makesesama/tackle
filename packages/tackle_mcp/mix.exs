defmodule Tackle.Plugins.MCP.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_mcp,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Tackle.Plugins.MCP.Application, []},
      extra_applications: [:crypto, :logger]
    ]
  end

  defp deps do
    [
      {:anubis_mcp, "~> 2.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:tackle_lib, path: "../tackle_lib"}
    ]
  end
end
