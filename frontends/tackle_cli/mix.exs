defmodule Tackle.CLI.MixProject do
  use Mix.Project

  @app :tackle_cli

  def project do
    [
      app: @app,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :tackle_codex, :tackle_deepseek, :tackle],
      mod: {Tackle.CLI.Application, []}
    ]
  end

  defp deps do
    [
      {:tackle, path: "../.."},
      {:tackle_codex, path: "../../plugins/tackle_codex"},
      {:tackle_deepseek, path: "../../plugins/tackle_deepseek"},
      {:optimus, "~> 0.6"},
      {:owl, "~> 0.13"},
      {:ucwidth, "~> 0.2"},
      {:ex_ratatui, "~> 0.15.0"},
      {:rustler, ">= 0.0.0"},
      {:burrito, "~> 1.6"}
    ]
  end

  defp escript do
    [main_module: Tackle.CLI.Main, name: "tackle"]
  end

  defp releases do
    [
      {@app,
       [
         steps: [
           :assemble,
           &Tackle.CLI.Release.verify_linux_nifs/1,
           &Burrito.wrap/1
         ],
         burrito: [
           # NIFs are built for the host CPU; build each target on a matching
           # host with the toolchain in the development shell or Nix package.
           targets: [
             linux_aarch64: [os: :linux, cpu: :aarch64],
             linux_x86_64: [os: :linux, cpu: :x86_64],
             macos: [os: :darwin, cpu: :x86_64],
             macos_silicon: [os: :darwin, cpu: :aarch64],
             windows: [os: :windows, cpu: :x86_64]
           ]
         ]
       ]}
    ]
  end
end
