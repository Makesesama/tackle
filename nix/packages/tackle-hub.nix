{ pkgs, lib }:

# The tackle_hub OTP release (apps/tackle_hub). A plain glibc release on the
# flake's BEAM (OTP 29, Elixir 1.20): unlike the Burrito CLI it needs no
# custom ERTS, so the binary cache can supply Erlang. Run it through the NixOS
# module (nix/modules/tackle-hub.nix), which supplies the environment that
# config/runtime.exs reads.
let
  beamPackages = pkgs.beamPackages;

  web = ../../apps/tackle_hub;

  # Keep worktrees, credentials, caches, and build artifacts out of the
  # world-readable store. Retain the relative path dependencies.
  projectFiles =
    path:
    lib.fileset.unions (
      [
        (path + /mix.exs)
        (path + /lib)
      ]
      ++ lib.optional (builtins.pathExists (path + /mix.lock)) (path + /mix.lock)
      ++ lib.optional (builtins.pathExists (path + /config)) (path + /config)
    );

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      (projectFiles web)
      # Migrations and the Ash resource snapshots they were generated from.
      (web + /priv)
      (projectFiles ../../packages/tackle_lib)
      (projectFiles ../../packages/tackle_runtime)
      (projectFiles ../../packages/tackle_review)
      (projectFiles ../../packages/tackle_tools)
      (projectFiles ../../packages/tackle_exec)
      (projectFiles ../../packages/tackle_openrouter)
      (projectFiles ../../packages/tackle_codex)
      (projectFiles ../../packages/yaml_frontmatter)
      (projectFiles ../../packages/gix_ex)
      # The gix_ex crate, including its .cargo/config.toml.
      (lib.fileset.fileFilter (
        file:
        lib.any file.hasExt [
          "rs"
          "toml"
          "lock"
        ]
      ) ../../packages/gix_ex/native)
    ];
  };

  # tackle_review reads repositories with gix_ex, a Rustler NIF compiled from
  # source. Rustler would run cargo during the Mix build, which needs the
  # network for crates, so build the crate here from the crates pinned in
  # Cargo.lock, install it into the dependency's priv/native, and have Rustler
  # skip compilation.
  gixNif =
    let
      source = "${src}/packages/gix_ex/native/gix_ex";
      vendor = pkgs.rustPlatform.importCargoLock { lockFile = "${source}/Cargo.lock"; };
    in
    pkgs.stdenv.mkDerivation {
      pname = "gix_ex-nif";
      version = "0.1.0";
      src = source;

      nativeBuildInputs = [
        pkgs.cargo
        pkgs.rustc
      ];

      dontConfigure = true;

      buildPhase = ''
        runHook preBuild
        export HOME="$TMPDIR/home"
        export CARGO_HOME="$TMPDIR/cargo"
        mkdir -p "$CARGO_HOME"
        # importCargoLock writes a relative cargo-vendor-dir, not @vendor@.
        # Keep its registry/git mappings, but resolve crates from the store.
        substitute ${vendor}/.cargo/config.toml "$CARGO_HOME/config.toml" \
          --replace-fail 'directory = "cargo-vendor-dir"' 'directory = "${vendor}"'
        cargo build --frozen --release
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p "$out/lib"
        cp target/release/libgix_ex.${
          if pkgs.stdenv.hostPlatform.isDarwin then "dylib" else "so"
        } "$out/lib/gix_ex.so"
        runHook postInstall
      '';
    };

  # The configuration every Mix dependency is compiled with. The deps file is
  # generated with --no-app-config, so dependencies do not see the app's
  # config/, but Ash's compile-time settings must reach every dependency that
  # defines resources (ash_phoenix does), with the values the app uses at
  # runtime: a release refuses to boot when they differ. config/ash.exs is
  # the single source for them.
  depsConfig = pkgs.runCommand "tackle-hub-deps-config" { } ''
    mkdir -p "$out"
    cp ${web + /config/ash.exs} "$out/ash.exs"
    cat > "$out/config.exs" <<'EOF'
    import Config
    import_config "ash.exs"
    config :gix_ex, GixEx.Native, skip_compilation?: true
    EOF
  '';

  # Rebar3 dependencies take no Elixir configuration.
  withDepsConfig =
    _name: drv:
    if lib.isDerivation drv && (lib.functionArgs drv.override) ? appConfigPath then
      drv.override { appConfigPath = depsConfig; }
    else
      drv;

  deps = pkgs.callPackage ../tackle-hub-deps.nix {
    inherit beamPackages;
    overrides =
      final: prev:
      let
        configured = lib.mapAttrs withDepsConfig prev;
      in
      configured
      // {
        tackle_lib = configured.tackle_lib.override { src = "${src}/packages/tackle_lib"; };
        tackle_runtime = configured.tackle_runtime.override { src = "${src}/packages/tackle_runtime"; };
        tackle_review = configured.tackle_review.override { src = "${src}/packages/tackle_review"; };
        tackle_tools = configured.tackle_tools.override { src = "${src}/packages/tackle_tools"; };
        tackle_exec = configured.tackle_exec.override { src = "${src}/packages/tackle_exec"; };
        tackle_openrouter = configured.tackle_openrouter.override {
          src = "${src}/packages/tackle_openrouter";
        };
        tackle_codex = configured.tackle_codex.override { src = "${src}/packages/tackle_codex"; };
        yaml_frontmatter = configured.yaml_frontmatter.override {
          src = "${src}/packages/yaml_frontmatter";
        };
        # Rustler loads `priv/native/gix_ex.so`, installed from the NIF built above.
        gix_ex = configured.gix_ex.override {
          src = "${src}/packages/gix_ex";
          preConfigure = ''
            mkdir -p priv/native
            cp ${gixNif}/lib/gix_ex.so priv/native/
          '';
        };
      };
  };

  # callPackage also adds override/overrideDerivation helpers to the result.
  # Only package derivations belong in the build inputs or the deps/ symlinks.
  mixNixDeps = lib.filterAttrs (_: lib.isDerivation) deps;
in
beamPackages.mixRelease {
  pname = "tackle-hub";
  version = "0.1.0";
  inherit src mixNixDeps;
  # Dependencies are already compiled by Nix and linked into _build. The
  # nixpkgs deps.compile hook would recompile path deps into read-only store
  # paths, as in the CLI package.
  dontMixDepsCompile = true;

  postUnpack = ''
    sourceRoot="$sourceRoot/apps/tackle_hub"
  '';

  # gix_ex was compiled with the configuration above. The release checks
  # compile-time configuration at boot, so it must carry the same value. Only
  # the Nix build skips Rustler; normal Mix builds are unchanged.
  prePatch = ''
    cat >> config/prod.exs <<'EOF'
    config :gix_ex, GixEx.Native, skip_compilation?: true
    EOF
  '';

  # Nothing secret is embedded: the release reads SECRET_KEY_BASE, the Cloak
  # key, and the database settings from the environment at boot. mixRelease
  # also removes the generated releases/COOKIE, so RELEASE_COOKIE must be set
  # at runtime; the NixOS module sets a fixed one and runs the release without
  # Erlang distribution, so nothing accepts it.
  passthru = {
    inherit mixNixDeps gixNif;
  };

  meta = {
    description = "Tackle web: pull request review app";
    mainProgram = "tackle_hub";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
      "aarch64-darwin"
      "x86_64-darwin"
    ];
  };
}
