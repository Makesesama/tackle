defmodule Tackle.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle,
      version: "0.1.0",
      description: "Developer agent harness built on Tackle.Lib and Tackle.Runtime",
      source_url: "https://github.com/Makesesama/tackle",
      package: [licenses: ["MIT"], links: %{"GitHub" => "https://github.com/Makesesama/tackle"}],
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Tackle.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:deps_nix, "~> 3.0", only: :dev},
      {:tackle_lib, path: "../tackle_lib"},
      {:tackle_runtime, path: "../tackle_runtime"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "deps.nix": ["deps.nix --output ../../nix/deps.nix"]
    ]
  end
end
