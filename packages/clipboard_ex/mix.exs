defmodule ClipboardEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :clipboard_ex,
      version: "0.1.0",
      description: "Native system clipboard access for Elixir, backed by Rust's arboard",
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
      mod: {Clipboard.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:rustler, "~> 0.38", runtime: false}
    ]
  end
end
