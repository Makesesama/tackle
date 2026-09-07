defmodule Tackle.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

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
      {:tackle_lib, path: "packages/tackle_lib"}
    ]
  end

  defp aliases do
    [
      "deps.nix": ["deps.nix --output nix/deps.nix"]
    ]
  end
end
