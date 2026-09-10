defmodule Tackle.Plugins.Codex.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_codex,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Tackle.Plugins.Codex.Application, []},
      extra_applications: [:crypto, :logger]
    ]
  end

  defp deps do
    [
      # Req 0.8 uses Elixir's standard-library JSON module. Req 0.7 depends on
      # Jason, which this project deliberately does not include.
      {:req, "== 0.8.0-rc.0"},
      {:mint_web_socket, "~> 1.0"},
      {:tackle_lib, path: "../../packages/tackle_lib"}
    ]
  end
end
