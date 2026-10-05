defmodule Tackle.SDK.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_sdk,
      version: "0.1.0",
      description:
        "JSON-RPC over stdio server exposing the Tackle.Lib agent loop to non-BEAM clients",
      source_url: "https://github.com/Makesesama/tackle",
      package: [licenses: ["MIT"], links: %{"GitHub" => "https://github.com/Makesesama/tackle"}],
      docs: [main: "readme", extras: ["README.md", "PROTOCOL.md"]],
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The framework-free agent core whose loop this server drives.
      {:tackle_lib, path: "../tackle_lib"}
    ]
  end
end
