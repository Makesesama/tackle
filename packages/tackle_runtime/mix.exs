defmodule Tackle.Runtime.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_runtime,
      version: "0.1.0",
      description: "Scoped OTP orchestration for Tackle agents",
      source_url: "https://github.com/Makesesama/tackle",
      package: [licenses: ["MIT"], links: %{"GitHub" => "https://github.com/Makesesama/tackle"}],
      docs: [main: "readme", extras: ["README.md"]],
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Tackle.Runtime.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:tackle_lib, path: "../tackle_lib"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
