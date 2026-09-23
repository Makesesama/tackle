defmodule Tackle.Plugins.DeepSeek.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_deepseek,
      version: "0.1.0",
      description: "DeepSeek provider adapter for Tackle.Lib",
      source_url: "https://github.com/Makesesama/tackle",
      package: [licenses: ["MIT"], links: %{"GitHub" => "https://github.com/Makesesama/tackle"}],
      docs: [main: "readme", extras: ["README.md"]],
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Req 0.8 uses Elixir's standard-library JSON module.
      {:req, "== 0.8.0-rc.0"},
      {:tackle_lib, path: "../tackle_lib"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
