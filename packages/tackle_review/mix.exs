defmodule Tackle.Review.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_review,
      version: "0.1.0",
      description: "Code review on Tackle.Runtime: ranked, line-anchored findings for a change",
      source_url: "https://github.com/Makesesama/tackle",
      package: [licenses: ["MIT"], links: %{"GitHub" => "https://github.com/Makesesama/tackle"}],
      docs: [main: "Tackle.Review"],
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:tackle_lib, path: "../tackle_lib"},
      {:tackle_runtime, path: "../tackle_runtime"},
      {:gix_ex, path: "../gix_ex"},
      {:yaml_frontmatter, path: "../yaml_frontmatter"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false}
    ]
  end
end
