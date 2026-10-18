defmodule Tackle.Elixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_elixir,
      version: "0.1.0",
      description:
        "Elixir project nodes for Tackle agents: compile and inspect a Mix project in its own BEAM node",
      source_url: "https://github.com/Makesesama/tackle",
      package: [licenses: ["MIT"], links: %{"GitHub" => "https://github.com/Makesesama/tackle"}],
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {Tackle.Elixir.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:tackle_lib, path: "../tackle_lib"},
      # The executor contract, so project nodes run where the agent's tools run.
      {:tackle_tools, path: "../tackle_tools"},
      # Frame decoding for the broker protocol, shared with the exec-server.
      {:tackle_exec, path: "../tackle_exec"}
    ]
  end
end
