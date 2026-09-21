{ pkgs, lib }:
let
  runtime = pkgs.callPackage ./burrito-runtime.nix { };
  beamPackages = runtime.beamPackages;
  toolchain = pkgs.callPackage ./native-toolchain.nix { };
  linux = pkgs.stdenv.hostPlatform.isLinux;
  cpu = pkgs.stdenv.hostPlatform.parsed.cpu.name;
  target =
    if linux then
      "linux_${cpu}"
    else if cpu == "aarch64" then
      "macos_silicon"
    else
      "macos";

  # Do not copy worktrees, credentials, sessions, caches or build artifacts into
  # the world-readable Nix store. Retain the relative path dependencies.
  root = ../..;
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
    inherit root;
    fileset = lib.fileset.unions [
      (projectFiles ../../packages/tackle)
      (projectFiles ../../packages/tackle_lib)
      (projectFiles ../../packages/tackle_runtime)
      (projectFiles ../../packages/tackle_codex)
      (projectFiles ../../packages/tackle_deepseek)
      (projectFiles ../../apps/tackle_cli)
      (lib.fileset.fileFilter (
        file:
        lib.any file.hasExt [
          "rs"
          "toml"
          "lock"
        ]
      ) ../../apps/tackle_cli/native)
    ];
  };

  # Build NIFs separately using Cargo.lock's per-crate checksums. Mix compilation
  # then only installs these artifacts; Rustler never needs network access.
  native =
    name: source:
    let
      vendor = pkgs.rustPlatform.importCargoLock {
        lockFile = "${source}/Cargo.lock";
      };
      underscored = lib.replaceStrings [ "-" ] [ "_" ] toolchain.triple;
    in
    pkgs.stdenv.mkDerivation {
      pname = "${name}-burrito-nif";
      version = "0.1.0";
      src = source;
      # Keep the musl compiler out of the global stdenv toolchain: Cargo build
      # scripts run on the GNU build host and must use its normal linker. The
      # target-specific variables below select musl only for the NIF itself.
      nativeBuildInputs = [
        toolchain.rust
        pkgs.pkg-config
      ];
      dontConfigure = true;
      dontStrip = true;
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        export HOME="$TMPDIR/home"
        export CARGO_HOME="$TMPDIR/cargo"
        mkdir -p "$CARGO_HOME"
        # importCargoLock uses a relative cargo-vendor-dir, not @vendor@.
        # Keep its registry/git mappings, but resolve crates in the Nix store.
        substitute ${vendor}/.cargo/config.toml "$CARGO_HOME/config.toml" \
          --replace-fail 'directory = "cargo-vendor-dir"' 'directory = "${vendor}"'
        export CC_${underscored}=${toolchain.cc}/bin/cc
        export CARGO_TARGET_${lib.toUpper underscored}_LINKER=${toolchain.cc}/bin/cc
        cargo build --frozen --release --target ${toolchain.triple}
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/lib"
        cp target/${toolchain.triple}/release/lib${name}.${
          if linux then "so" else "dylib"
        } "$out/lib/${name}.so"
        runHook postInstall
      '';
    };

  tackleNif = native "tackle" "${src}/apps/tackle_cli/native/tackle";
  exRatatuiNif = native "ex_ratatui" "${deps.ex_ratatui.src}/native/ex_ratatui";
  nativeConfig = pkgs.writeTextDir "config.exs" ''
    import Config
    config :rustler_precompiled, :force_build, ex_ratatui: true
    config :ex_ratatui, ExRatatui.Native, skip_compilation?: true
  '';
  deps = pkgs.callPackage ../tackle-cli-deps.nix {
    inherit beamPackages;
    overrides = final: prev: {
      tackle = prev.tackle.override { src = "${src}/packages/tackle"; };
      tackle_lib = prev.tackle_lib.override { src = "${src}/packages/tackle_lib"; };
      tackle_runtime = prev.tackle_runtime.override { src = "${src}/packages/tackle_runtime"; };
      tackle_codex = prev.tackle_codex.override { src = "${src}/packages/tackle_codex"; };
      tackle_deepseek = prev.tackle_deepseek.override { src = "${src}/packages/tackle_deepseek"; };
      ex_ratatui = prev.ex_ratatui.override {
        appConfigPath = nativeConfig;
        nativeBuildInputs = [ ];
        preConfigure = ''
          mkdir -p priv/native
          cp ${exRatatuiNif}/lib/ex_ratatui.so priv/native/
        '';
        preBuild = "";
      };
    };
  };
  # callPackage also adds override/overrideDerivation helpers to the result.
  # Only package derivations belong in either the build inputs or source copy.
  mixNixDeps = lib.filterAttrs (_: lib.isDerivation) deps;
in
beamPackages.mixRelease {
  pname = "tackle-cli";
  version = "0.1.0";
  inherit src;
  inherit mixNixDeps;
  nativeBuildInputs = [
    pkgs.zig_0_16
    pkgs.xz
  ]
  ++ lib.optional linux pkgs.util-linux;

  postUnpack = ''
    sourceRoot="$sourceRoot/apps/tackle_cli"
  '';
  env = {
    BURRITO_TARGET = target;
    TACKLE_MUSL_CC = "${toolchain.cc}/bin/cc";
    CARGO_NET_OFFLINE = "true";
  };
  prePatch = ''
    # These NIFs were compiled from the exact locked sources above. Only the
    # Nix build skips Rustler; normal Mix/dev-shell builds remain unchanged.
    cat >> config/prod.exs <<'EOF'
    config :ex_ratatui, ExRatatui.Native, skip_compilation?: true
    config :tackle_cli, Tackle.CLI.Native, skip_compilation?: true
    EOF
    mkdir -p priv/native
    cp ${tackleNif}/lib/tackle.so priv/native/
  '';

  configurePhase = ''
    runHook preConfigure
    export HOME="$TMPDIR/home"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
    mkdir -p "$HOME" deps
    ${runtime.seedCache}
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: dep: ''
        cp -R ${dep.src} deps/${name}
        chmod -R u+w deps/${name}
      '') mixNixDeps
    )}
    # Burrito locates its Zig sources via __ENV__.file and writes beside them.
    # Recompile it in this writable build tree, not its buildMix source path.
    rm _build/prod/lib/burrito
    (cd deps/burrito && MIX_BUILD_PATH="$PWD/../../_build/prod" mix compile --no-deps-check)
    runHook postConfigure
  '';

  installPhase = ''
    runHook preInstall
    # A fixed, non-secret cookie: this standalone distribution does not enable
    # Erlang distribution. Do not embed a randomly generated release secret.
    RELEASE_COOKIE=tackle-standalone mix release --no-deps-check
    mkdir -p "$out/bin"
    install -m755 burrito_out/tackle_cli_${target} "$out/bin/tackle"
    runHook postInstall
  '';

  # Do not wrap or rewrite the self-extracting artifact as an ordinary OTP
  # release. It must remain the same single executable users can copy elsewhere.
  dontFixup = true;
  dontStrip = true;
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME="$TMPDIR/smoke-home"
    export XDG_CACHE_HOME="$HOME/cache"
    export TACKLE_HOME="$HOME/tackle"
    mkdir -p "$HOME"
    "$out/bin/tackle" --version
    "$out/bin/tackle" --help
    "$out/bin/tackle" models
    ${lib.optionalString linux ''
      # The informational commands above do not mount the TUI and therefore do
      # not load every OTP and Rust NIF it needs. Start it under a pseudo-TTY
      # and send Ctrl+C; a mixed glibc/musl release fails here before input is
      # handled (notably while :crypto is loaded).
      (sleep 2; printf '\003') | timeout 15s script -qec "$out/bin/tackle" /dev/null
    ''}
    runHook postInstallCheck
  '';

  passthru = {
    inherit target;
    otpVersion = runtime.version;
  };
  meta = {
    description = "Tackle CLI, packaged as a standalone Burrito executable";
    mainProgram = "tackle";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
      "aarch64-darwin"
      "x86_64-darwin"
    ];
  };
}
