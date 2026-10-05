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
      aliases: aliases(),
      escript: escript(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [
        :logger,
        :tackle_codex,
        :tackle_deepseek,
        :tackle_anthropic,
        :tackle_openrouter,
        :tackle_mcp,
        :tackle_sdk,
        :tackle
      ],
      mod: {Tackle.CLI.Application, []}
    ]
  end

  defp deps do
    [
      {:tackle, path: "../../packages/tackle"},
      {:tackle_codex, path: "../../packages/tackle_codex"},
      {:tackle_deepseek, path: "../../packages/tackle_deepseek"},
      {:tackle_anthropic, path: "../../packages/tackle_anthropic"},
      {:tackle_openrouter, path: "../../packages/tackle_openrouter"},
      {:tackle_mcp, path: "../../packages/tackle_mcp"},
      {:tackle_sdk, path: "../../packages/tackle_sdk"},
      {:optimus, "~> 0.6"},
      {:owl, "~> 0.13"},
      {:ucwidth, "~> 0.2"},
      {:ex_ratatui, "~> 0.15.0"},
      {:rustler, ">= 0.0.0"},
      {:burrito, "~> 1.6"},
      # Generates nix/tackle-cli-deps.nix; see the "deps.nix" alias below.
      {:deps_nix, "~> 3.0", only: :dev}
    ]
  end

  defp aliases do
    [
      # --include-paths: the tackle_* packages are path deps in this monorepo;
      #   without it they are omitted from the generated file.
      # --no-app-config: otherwise every dependency is given an appConfigPath and
      #   any edit to config/ invalidates and rebuilds all of them.
      "deps.nix": [
        "deps.nix --include-paths --no-app-config --output ../../nix/tackle-cli-deps.nix"
      ]
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
           &Tackle.CLI.Release.standalone_boot/1,
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
