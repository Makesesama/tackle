defmodule Tackle.Web.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_web,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Tackle.Web.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      # Generates nix/tackle-web-deps.nix so Nix builds every dependency for
      # this project. Required on NixOS: Nix builds the Rust/NIF dependencies
      # and the Erlang ones that need rebar3, instead of Mix downloading
      # precompiled binaries that expect an FHS dynamic loader.
      {:deps_nix, "~> 3.0", only: :dev},

      # Harness + the reusable agent core and their Phoenix glue.
      {:tackle, path: "../.."},
      {:tackle_lib, path: "../../packages/tackle_lib"},
      {:tackle_phoenix, path: "../../packages/tackle_phoenix"},

      # Provider adapters. These are the repo's plugin packages, wired in the
      # same way any external plugin would be: both implement Tackle.Lib.LLM,
      # and the model reference the user picks decides which one runs.
      {:tackle_codex, path: "../../plugins/tackle_codex"},
      {:tackle_deepseek, path: "../../plugins/tackle_deepseek"},

      # Web layer. tackle_phoenix brings LiveView/PubSub, but not Phoenix itself.
      # LiveView is held at the same ~> 1.1.33 range tackle_phoenix requires;
      # 1.2.x would not resolve.
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.1.33"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:bandit, "~> 1.12"},
      {:lazy_html, ">= 0.1.0", only: :test},

      # Asset pipeline. On NixOS the binaries come from nixpkgs (see
      # config/dev.exs and nix/packages/tackle-web.nix) instead of being
      # downloaded by these packages.
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},

      # Assets checked in as git deps rather than npm packages: the Tailwind
      # plugins in assets/css/app.css resolve them through NODE_PATH=deps.
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},

      # GitHub API. Pinned to match the version already used by the
      # tackle_codex and tackle_deepseek plugins.
      {:req, "== 0.8.0-rc.0"},

      # GitHub OAuth (read-only scopes; no live call in tests).
      {:assent, "~> 0.3"},

      # Git access. `git` drives the CLI; `forcola` executes it as a port
      # program that kills the whole process group on timeout or BEAM death.
      {:git, "~> 0.7"},
      {:forcola, "~> 0.3"},
      {:git_diff, "~> 0.6"},

      # Syntax highlighting (tree-sitter, precompiled NIF).
      {:lumis, "~> 0.8"},
      # lumis declares rustler as optional. Nix forces the NIF to build from
      # source (no network in the sandbox), and rustler_precompiled requires
      # this to be present when doing so. Not used outside a Nix build.
      {:rustler, ">= 0.0.0", optional: true},

      # Dev/test only.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],

      # `--if-missing` is satisfied by the nixpkgs binaries symlinked into
      # place by nix/packages/tackle-web.nix, so these never hit the network
      # in a Nix build; in the dev shell they resolve via config path/. 
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind tackle_web", "esbuild tackle_web"],
      "assets.deploy": [
        "tailwind tackle_web --minify",
        "esbuild tackle_web --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],

      # --include-paths: tackle, tackle_lib and tackle_phoenix are path deps in
      #   this monorepo; without it they are omitted from the generated file.
      # --no-app-config: otherwise every dependency is given an appConfigPath and
      #   any edit to config/ invalidates and rebuilds all of them. Matches how
      #   nix/tackle-cli-deps.nix is generated.
      "deps.nix": [
        "deps.nix --include-paths --no-app-config --output nix/tackle-web-deps.nix"
      ]
    ]
  end
end
