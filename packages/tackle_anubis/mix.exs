defmodule Tackle.Anubis.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_anubis,
      version: "0.1.0",
      description: "Anubis MCP server bridge for Tackle.Lib tools",
      source_url: "https://github.com/Makesesama/tackle",
      package: [licenses: ["MIT"], links: %{"GitHub" => "https://github.com/Makesesama/tackle"}],
      docs: [main: "readme", extras: ["README.md"]],
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # The framework-free agent core whose tools this bridge exposes.
      {:tackle_lib, path: "../tackle_lib"},
      # The Anubis MCP server runtime and its Peri schemas. Required, not
      # optional: this package exists only to bridge Tackle.Lib tools into an
      # Anubis server, so the core library does not have to carry it.
      {:anubis_mcp, "~> 2.0"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
