defmodule Tackle.Plugins.Ollama.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_ollama,
      version: "0.1.0",
      description: "Ollama adapter for Tackle.Lib: Ollama Cloud, local, and self-hosted servers",
      source_url: "https://github.com/Makesesama/tackle",
      package: [licenses: ["MIT"], links: %{"GitHub" => "https://github.com/Makesesama/tackle"}],
      docs: [main: "readme", extras: ["README.md"]],
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:req, "== 0.8.0-rc.0"},
        {:tackle_lib, path: "../tackle_lib"},
        {:ex_doc, "~> 0.40", only: :dev, runtime: false}
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto, :logger]]
end
