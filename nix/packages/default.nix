{
  pkgs,
  lib,
  # Build identity of the checkout, supplied by flake.nix. Both are absent when
  # Nix has no Git checkout, such as a `path:` flake input.
  rev ? null,
  lastModified ? 0,
  # Exact application version, for a release that must not carry a build stamp.
  releaseVersion ? null,
}:
let
  runtime = pkgs.callPackage ./burrito-runtime.nix { };
  beamPackages = runtime.beamPackages;
  toolchain = pkgs.callPackage ./native-toolchain.nix { };
  linux = pkgs.stdenv.hostPlatform.isLinux;
  cpu = pkgs.stdenv.hostPlatform.parsed.cpu.name;
  # Cargo's per-target environment variable infix, e.g. x86_64_unknown_linux_musl.
  underscored = lib.replaceStrings [ "-" ] [ "_" ] toolchain.triple;
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
      (projectFiles ../../packages/tackle_exec)
      (projectFiles ../../packages/tackle_codex)
      (projectFiles ../../packages/tackle_deepseek)
      (projectFiles ../../packages/tackle_anthropic)
      (projectFiles ../../packages/tackle_openrouter)
      (projectFiles ../../packages/tackle_ollama)
      (projectFiles ../../packages/tackle_mcp)
      (projectFiles ../../packages/tackle_sdk)
      (projectFiles ../../packages/clipboard_ex)
      (projectFiles ../../apps/tackle_cli)
      # Listed unconditionally because `mix.exs` reads it: a source copy without it
      # must fail at evaluation here, not inside the build.
      (../../apps/tackle_cli + /VERSION)
      (lib.fileset.fileFilter (
        file:
        lib.any file.hasExt [
          "rs"
          "toml"
          "lock"
        ]
      ) ../../apps/tackle_cli/native)
      (lib.fileset.fileFilter (
        file:
        lib.any file.hasExt [
          "rs"
          "toml"
          "lock"
        ]
      ) ../../packages/clipboard_ex/native)
    ];
  };

  # Burrito keys its extracted OTP release by application version and re-uses
  # an existing extraction whenever that version is unchanged, so a rebuilt
  # binary with a stale version silently runs the previous payload. Stamp every
  # build, so each one extracts its own payload.
  appVersion =
    if releaseVersion != null then
      releaseVersion
    else
      let
        base = lib.trim (builtins.readFile ../../apps/tackle_cli/VERSION);
        # Everything that shapes the payload: the sources `src` was built from,
        # the recipe that builds them, the nixpkgs revision, and the target
        # platform. Sources alone would ignore a recipe-only rebuild, which would
        # then re-use the extraction of the build before it.
        recipe = lib.fileset.toSource {
          root = ../..;
          fileset = lib.fileset.unions (
            [
              ../../nix
              ../../flake.nix
            ]
            ++ lib.optional (builtins.pathExists ../../flake.lock) ../../flake.lock
          );
        };
        inputs = toString src + toString recipe + toString pkgs.path + pkgs.stdenv.hostPlatform.system;
        content = builtins.substring 0 12 (builtins.hashString "sha256" inputs);
        revision = if rev == null then "src" else "g${rev}";
        # The source timestamp orders builds of successive revisions, which is
        # when Burrito removes the extraction it replaced. Rebuilds of one
        # revision differ only in the content above, so they still extract their
        # own payload, but neither extraction is removed.
        stamp = if lastModified != null && lastModified > 0 then toString lastModified else "0";
      in
      "${base}-dev.${stamp}+${revision}.${content}";

  # Build NIFs separately using Cargo.lock's per-crate checksums. Mix compilation
  # then only installs these artifacts; Rustler never needs network access.
  native =
    name: source:
    let
      vendor = pkgs.rustPlatform.importCargoLock {
        lockFile = "${source}/Cargo.lock";
      };
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

  # Unlike ExRatatui and the Tackle crate, lumis_nif has no build.rs that
  # embeds the unwinder. Its musl cdylib disables crt-static, so rustc links
  # `-lgcc_s`, which Burrito's runtime does not ship. Shadow that lookup with
  # the toolchain's static unwinder, as those build scripts do. Repeat
  # -crt-static in case Cargo prefers this variable to the crate's target
  # rustflags. The trailing -lgcc resolves aarch64 outline-atomics helpers.
  lumisUnwinderShim = lib.optionalString linux ''
    shim="$TMPDIR/gcc_s_shim"
    mkdir -p "$shim"
    cp "$(${toolchain.cc}/bin/cc -print-file-name=libgcc_eh.a)" "$shim/libgcc_s.a"
    cp "$(${toolchain.cc}/bin/cc -print-file-name=libgcc.a)" "$shim/libgcc.a"
    export CARGO_TARGET_${lib.toUpper underscored}_RUSTFLAGS="-C target-feature=-crt-static -C link-arg=-static-libgcc -L native=$shim -C link-arg=-lgcc"
  '';
  # Fail here rather than at NIF load inside the wrapped binary. These are the
  # markers Tackle.CLI.Release.verify_linux_nifs/1 rejects.
  lumisMuslCheck = ''
    runHook preInstallCheck
    if grep -qaE 'libc[.]so[.]6|GLIBC_|libgcc_s[.]so[.]1' "$out/lib/lumis_nif.so"; then
      echo "lumis_nif.so depends on glibc or libgcc_s.so.1" >&2
      exit 1
    fi
    runHook postInstallCheck
  '';

  tackleNif = native "tackle" "${src}/apps/tackle_cli/native/tackle";
  # Like the Tackle crate, clipboard_ex's build.rs shadows the shared unwinder
  # for the musl target, so no Nix-level shim is needed here.
  clipboardNif = native "clipboard_ex" "${src}/packages/clipboard_ex/native/clipboard_ex";
  exRatatuiNif = native "ex_ratatui" "${deps.ex_ratatui.src}/native/ex_ratatui";
  # Lumis, like ExRatatui, is a RustlerPrecompiled package. deps_nix's generic
  # workaround would have Rustler build it with a glibc toolchain during the Mix
  # build, so build its NIF here for the Burrito musl target instead.
  lumisNif = (native "lumis_nif" "${deps.lumis.src}/native/lumis_nif").overrideAttrs (old: {
    # wasmtime-c-api-impl's build script runs `cmake -P` to install headers.
    # dontConfigure keeps cmake's setup hook from configuring anything.
    nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.cmake ];
    preBuild = lumisUnwinderShim;
    doInstallCheck = linux;
    installCheckPhase = lumisMuslCheck;
  });
  nativeConfig = pkgs.writeTextDir "config.exs" ''
    import Config
    config :rustler_precompiled, :force_build, ex_ratatui: true, lumis: true
    config :ex_ratatui, ExRatatui.Native, skip_compilation?: true
    config :lumis, Lumis.Native, skip_compilation?: true
    config :clipboard_ex, Clipboard.Native, skip_compilation?: true
  '';
  deps = pkgs.callPackage ../tackle-cli-deps.nix {
    inherit beamPackages;
    overrides = final: prev: {
      tackle = prev.tackle.override { src = "${src}/packages/tackle"; };
      tackle_lib = prev.tackle_lib.override { src = "${src}/packages/tackle_lib"; };
      tackle_runtime = prev.tackle_runtime.override { src = "${src}/packages/tackle_runtime"; };
      tackle_exec = prev.tackle_exec.override { src = "${src}/packages/tackle_exec"; };
      tackle_codex = prev.tackle_codex.override { src = "${src}/packages/tackle_codex"; };
      tackle_deepseek = prev.tackle_deepseek.override { src = "${src}/packages/tackle_deepseek"; };
      tackle_anthropic = prev.tackle_anthropic.override { src = "${src}/packages/tackle_anthropic"; };
      tackle_openrouter = prev.tackle_openrouter.override {
        src = "${src}/packages/tackle_openrouter";
      };
      tackle_ollama = prev.tackle_ollama.override { src = "${src}/packages/tackle_ollama"; };
      tackle_mcp = prev.tackle_mcp.override { src = "${src}/packages/tackle_mcp"; };
      tackle_sdk = prev.tackle_sdk.override { src = "${src}/packages/tackle_sdk"; };
      # Rustler would otherwise compile the crate with the GNU toolchain during
      # the Mix build; the musl NIF built above is installed instead.
      clipboard_ex = prev.clipboard_ex.override {
        src = "${src}/packages/clipboard_ex";
        appConfigPath = nativeConfig;
        nativeBuildInputs = [ ];
        preConfigure = ''
          mkdir -p priv/native
          cp ${clipboardNif}/lib/clipboard_ex.so priv/native/
        '';
        preBuild = "";
      };
      ex_ratatui = prev.ex_ratatui.override {
        appConfigPath = nativeConfig;
        nativeBuildInputs = [ ];
        preConfigure = ''
          mkdir -p priv/native
          cp ${exRatatuiNif}/lib/ex_ratatui.so priv/native/
        '';
        preBuild = "";
      };
      # Rustler loads `priv/native/<crate>` when RustlerPrecompiled force-builds.
      lumis = prev.lumis.override {
        appConfigPath = nativeConfig;
        nativeBuildInputs = [ ];
        preConfigure = ''
          mkdir -p priv/native
          cp ${lumisNif}/lib/lumis_nif.so priv/native/
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
  version = appVersion;
  inherit src;
  inherit mixNixDeps;
  # Dependencies are already compiled by Nix and linked into _build. The
  # nixpkgs deps.compile hook would recompile path deps into read-only store
  # paths. Only Burrito needs a writable rebuild, handled in configurePhase.
  dontMixDepsCompile = true;
  # Zig is used by Burrito during release wrapping, not as the app builder.
  dontUseZigBuild = true;
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
    # The build sandbox has no Git checkout, so the application version is
    # decided here; `mix.exs` reads it for the project Burrito wraps.
    TACKLE_VERSION = appVersion;
    CARGO_NET_OFFLINE = "true";
  };
  prePatch = ''
    # These NIFs were compiled from the exact locked sources above. Only the
    # Nix build skips Rustler; normal Mix/dev-shell builds remain unchanged.
    cat >> config/prod.exs <<'EOF'
    config :ex_ratatui, ExRatatui.Native, skip_compilation?: true
    config :lumis, Lumis.Native, skip_compilation?: true
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
    # Let nixpkgs link dependency sources before replacing Burrito's source
    # symlink. Pre-populating deps/ conflicts with mixNixDepsPostConfigure.
    runHook postConfigure
    # Burrito locates its Zig sources via __ENV__.file and writes beside them.
    # Recompile it in this writable build tree, not its buildMix source path.
    rm deps/burrito
    cp -R ${deps.burrito.src} deps/burrito
    chmod -R u+w deps/burrito
    rm _build/prod/lib/burrito
    (cd deps/burrito && MIX_BUILD_PATH="$PWD/../../_build/prod" mix compile --no-deps-check)
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
    # Exit status alone is insufficient: Elixir's own CLI can consume these
    # flags after release boot and report its version instead of Tackle's.
    "$out/bin/tackle" --version > version.txt
    cat version.txt
    grep -F 'Tackle developer harness ${appVersion}' version.txt
    "$out/bin/tackle" --help > help.txt
    cat help.txt
    grep -F -- '--model' help.txt
    "$out/bin/tackle" models > models.txt
    cat models.txt
    grep -F 'ollama-cloud/gpt-oss:120b' models.txt
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
