defmodule Tackle.Workflow.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_workflow,
      version: "0.1.0",
      description: "Lua-scripted agent workflows for the Tackle runtime",
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
      mod: {Tackle.Workflow.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Pure-Elixir sandboxed Lua 5.3 VM used to evaluate workflow scripts.
      {:lua, "~> 1.0"},
      # Scoped OTP orchestration the workflows drive.
      {:tackle_runtime, path: "../tackle_runtime"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
