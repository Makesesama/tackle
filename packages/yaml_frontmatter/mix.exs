defmodule YamlFrontmatter.MixProject do
  use Mix.Project

  def project do
    [
      app: :yaml_frontmatter,
      version: "0.1.0",
      description: "A small parser for the YAML front matter of Markdown files",
      source_url: "https://github.com/Makesesama/tackle",
      package: [licenses: ["MIT"], links: %{"GitHub" => "https://github.com/Makesesama/tackle"}],
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  def application do
    [extra_applications: []]
  end
end
