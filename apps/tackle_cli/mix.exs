defmodule Tackle.CLI.MixProject do
  use Mix.Project

  @app :tackle_cli
  # Human-facing release version, bumped when a release is cut. Distribution
  # builds add a development stamp to it; see `version/0`.
  @base_version Path.join(__DIR__, "VERSION") |> File.read!() |> String.trim()

  def project do
    [
      app: @app,
      version: version(),
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      escript: escript(),
      releases: releases()
    ]
  end

  # Test-only modules (the Lumis stand-in) compile with the test suite.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Burrito extracts the release into `.../<release>_erts-<erts>_<version>` and
  # re-uses that extraction whenever the version is unchanged, so one version per
  # release would keep running the previous payload after a rebuild. Every build
  # therefore stamps its own version: the release version in `VERSION` plus a
  # stamp for the build, or `TACKLE_VERSION` as a whole, which is how the Nix
  # build sets it, its sandbox having no Git checkout to stamp from.
  #
  # Mix writes the version into `.app` only when its own inputs change, so a long
  # lived build tree can report the stamp of an earlier compile; a fresh tree,
  # which is what a distribution build is, reads it exactly.
  defp version do
    System.get_env("TACKLE_VERSION") || dev_version()
  end

  defp dev_version do
    with revision when is_binary(revision) <- git(["rev-parse", "--short", "HEAD"]),
         committed_at when is_binary(committed_at) <- git(["log", "-1", "--format=%ct"]),
         true <- revision =~ ~r/\A[0-9a-f]+\z/ and committed_at =~ ~r/\A\d+\z/ do
      # Only a successful, empty status means a clean tree; an unreadable one
      # counts as dirty, because re-using a stale extraction is worse than
      # extracting the payload again. Uncommitted changes have no timestamp of
      # their own, so those builds are ordered by build time instead.
      case git(["status", "--porcelain", "--untracked-files=normal"]) do
        "" -> "#{@base_version}-dev.#{committed_at}+g#{revision}"
        _dirty -> "#{@base_version}-dev.#{System.os_time(:second)}+g#{revision}.dirty"
      end
    else
      # No commit to stamp from, or output the version format does not accept:
      # the release version, rather than a stamp that Mix or Burrito rejects.
      _no_stamp -> @base_version
    end
  end

  defp git(args) do
    with executable when is_binary(executable) <- System.find_executable("git"),
         {output, 0} <- System.cmd(executable, args) do
      String.trim(output)
    else
      _unavailable -> nil
    end
  end

  def application do
    [
      extra_applications: [
        :logger,
        :tackle_codex,
        :tackle_deepseek,
        :tackle_anthropic,
        :tackle_openrouter,
        :tackle_ollama,
        :tackle_mcp,
        :tackle_sdk,
        :clipboard_ex,
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
      {:tackle_ollama, path: "../../packages/tackle_ollama"},
      {:tackle_mcp, path: "../../packages/tackle_mcp"},
      {:tackle_sdk, path: "../../packages/tackle_sdk"},
      {:clipboard_ex, path: "../../packages/clipboard_ex"},
      {:optimus, "~> 0.6"},
      {:owl, "~> 0.13"},
      # Not referenced directly: Owl declares it optional, and listing it here
      # switches on its unicode-aware table padding (CJK alignment in
      # `tackle sessions` and other non-TUI output).
      {:ucwidth, "~> 0.2"},
      {:ex_ratatui, "~> 0.15.0"},
      {:rustler, ">= 0.0.0"},
      # Syntax highlighting for tool cards (tree-sitter, precompiled NIF).
      # Pinned to the version the web app runs: 0.9+ moved parser
      # distribution to per-language `lumis_wasm_*` Hex packages, while 0.8
      # downloads them from the CDN on demand. Nix builds the NIF from
      # source, which needs rustler present above.
      {:lumis, "== 0.8.0"},
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
