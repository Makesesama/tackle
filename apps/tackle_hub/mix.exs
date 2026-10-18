defmodule Tackle.Hub.MixProject do
  use Mix.Project

  def project do
    [
      app: :tackle_hub,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {Tackle.Hub.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Review engine and what it runs on; see docs/TACKLE_HUB_PLAN.md §4.
      # The harness (packages/tackle) is deliberately not a dependency.
      {:tackle_lib, path: "../../packages/tackle_lib"},
      {:tackle_runtime, path: "../../packages/tackle_runtime"},
      {:tackle_review, path: "../../packages/tackle_review"},
      {:tackle_tools, path: "../../packages/tackle_tools"},
      {:tackle_exec, path: "../../packages/tackle_exec"},
      # The only model providers the app accepts (§7.2).
      {:tackle_openrouter, path: "../../packages/tackle_openrouter"},
      {:tackle_codex, path: "../../packages/tackle_codex"},

      # Data model, jobs, and encrypted attributes.
      {:ash, "~> 3.36"},
      {:ash_postgres, "~> 2.14"},
      {:ash_oban, "~> 0.10"},
      {:ash_cloak, "~> 0.4"},
      {:ash_phoenix, "~> 2.3"},
      # The admin UI (docs/TACKLE_HUB_PLAN.md §7.9); 0.x and earlier 1.x have advisories.
      {:ash_admin, "~> 1.3 and >= 1.3.2"},
      # Ash policies need a SAT solver; this one is pure Elixir (no NIF).
      {:simple_sat, "~> 0.1"},
      {:oban, "~> 2.24"},
      {:cloak, "~> 1.1"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},

      # Web.
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1"},
      {:bandit, "~> 1.8"},
      # Pinned like the provider packages, which require this exact version.
      {:req, "== 0.8.0-rc.0"},

      # Spark's formatter plugin and the Ash code generators need it.
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      # Generates nix/tackle-hub-deps.nix; see the "deps.nix" alias below.
      {:deps_nix, "~> 3.0", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ash.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ash.setup --quiet", "test"],
      # As for the CLI: --include-paths keeps the path dependencies (the
      # packages) in the generated file, and --no-app-config stops every
      # dependency from being rebuilt whenever config/ changes.
      "deps.nix": [
        "deps.nix --include-paths --no-app-config --output ../../nix/tackle-hub-deps.nix"
      ]
    ]
  end

  defp releases do
    [tackle_hub: [include_executables_for: [:unix]]]
  end
end
