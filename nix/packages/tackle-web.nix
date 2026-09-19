{ pkgs, lib }:
let
  # The flake overlay's beam set (OTP 29 + Elixir 1.20). Unlike the Burrito CLI
  # package this needs no custom ERTS, so the binary cache can supply Erlang.
  beamPackages = pkgs.beamPackages;

  web = ../../frontends/tackle_web;
  root = ../..;

  # Keep worktrees, credentials, sessions, caches and build artifacts out of the
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
      ++ lib.optional (builtins.pathExists (path + /assets)) (path + /assets)
    );

  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (projectFiles web)
      (projectFiles root)
      (projectFiles ../../packages/tackle_lib)
      (projectFiles ../../packages/tackle_phoenix)
      # Hand-written static files. priv/static/assets is produced by the asset
      # pipeline below and is deliberately not taken from the working tree.
      (web + /priv/static/favicon.ico)
      (web + /priv/static/images)
      (web + /priv/static/robots.txt)
    ];
  };

  # Unoverridden call, only so the forcola shim below can read forcola's source.
  # The file lives inside the frontend project because deps_nix derives its
  # relative src/appConfig paths from the output location.
  baseDeps = pkgs.callPackage ../../frontends/tackle_web/nix/tackle-web-deps.nix {
    inherit beamPackages;
  };

  # forcola's compile task takes the "download a precompiled shim from GitHub
  # Releases" branch, because the hex package ships checksum-forcola_shim.exs.
  # The Nix sandbox has neither network nor a CA bundle, so build the shim here
  # from the crates pinned in Cargo.lock and stop the dep running its compiler.
  forcolaShim =
    let
      source = "${baseDeps.forcola.src}/native/forcola_shim";
      vendor = pkgs.rustPlatform.importCargoLock { lockFile = "${source}/Cargo.lock"; };
    in
    pkgs.stdenv.mkDerivation {
      pname = "forcola_shim";
      inherit (baseDeps.forcola) version;
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
        mkdir -p "$out/bin"
        install -m755 target/release/forcola_shim "$out/bin/forcola_shim"
        runHook postInstall
      '';
    };

  # deps_nix discards dependencies that set both `app: false` and `compile:
  # false` -- it special-cases :heroicons only -- so daisyUI never reaches the
  # generated file. The Tailwind config in assets/css/app.css resolves
  # "daisyui/packages/bundle/daisyui" through NODE_PATH=deps, so it has to be
  # present. Shape mirrors deps_nix's own heroicons derivation: mixRelease's
  # configure phase symlinks the `src` attribute of each dep into deps/.
  daisyui = pkgs.stdenv.mkDerivation {
    name = "daisyui";
    src = pkgs.fetchFromGitHub {
      owner = "saadeghi";
      repo = "daisyui";
      rev = "22ecff57f2c391b80a75617325748cf4d13fdf47";
      hash = "sha256-I2LI9VYVxQcvoMDgDWmvNyQToS1rFm12V167YxqDs24=";
    };
    buildPhase = ''
      mkdir $out
      ln -sv $src $out/src
    '';
  };

  # deps_nix's rustlerPrecompiled workaround forces a from-source Rust build
  # (RUSTLER_PRECOMPILED_FORCE_BUILD_ALL), which makes Rustler run `cargo
  # metadata` and friends. The sandbox has no network, so point cargo at the
  # crates pinned in Cargo.lock. Rustler only needs this when building from
  # source; a normal `mix deps.get` still uses the precompiled NIF.
  lumisNifVendor = pkgs.rustPlatform.importCargoLock {
    lockFile = "${baseDeps.lumis.src}/native/lumis_nif/Cargo.lock";
  };

  deps = pkgs.callPackage ../../frontends/tackle_web/nix/tackle-web-deps.nix {
    inherit beamPackages;
    overrides = final: prev: {
      tackle = prev.tackle.override { src = src; };
      tackle_lib = prev.tackle_lib.override { src = "${src}/packages/tackle_lib"; };
      tackle_phoenix = prev.tackle_phoenix.override { src = "${src}/packages/tackle_phoenix"; };
      forcola = prev.forcola.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          mkdir -p priv
          cp ${forcolaShim}/bin/forcola_shim priv/forcola_shim
          chmod u+w priv/forcola_shim
          # The shim is already provided above; without this the compiler would
          # try to download (or rebuild) it.
          substituteInPlace mix.exs \
            --replace-fail "Mix.compilers() ++ [:forcola_shim]" "Mix.compilers()"
        '';
      });

      lumis = prev.lumis.override {
        # rustler parses `cargo metadata` output with Jason, but declares it only
        # as an optional dependency, so it is missing from lumis's isolated build
        # path (a plain `mix deps.get` workspace happens to have it in deps/).
        beamDeps = prev.lumis.beamDeps ++ [ final.jason ];

        nativeBuildInputs = [
          pkgs.cargo
          pkgs.rustc
          # lumis-core's `all-languages` feature pulls in wasmtime, whose
          # wasmtime-c-api-impl crate builds a C API with cmake. Keep cmake from
          # claiming configurePhase: this is a Mix package, not a CMake project.
          pkgs.cmake
          pkgs.pkg-config
        ];

        dontUseCmakeConfigure = true;

        # rustler parses the JSON produced by `cargo metadata` with Jason, but
        # only declares it as an optional dependency. Elixir ignores ERL_LIBS,
        # so an undeclared dep never lands on the compiler's code path (buildMix
        # symlinks deps into _build/ but mix only loads the ones in mix.exs).
        # Declare it for the isolated build; jason is already compiled in the
        # store and mix finds it under _build/prod/lib.
        postPatch = ''
          substituteInPlace mix.exs \
            --replace-fail '{:rustler_precompiled, "~> 0.8"},' \
            '{:rustler_precompiled, "~> 0.8"}, {:jason, "~> 1.4"},'
        '';

        preConfigure = ''
          export CARGO_HOME="$TMPDIR/cargo"
          mkdir -p "$CARGO_HOME"
          # importCargoLock writes a relative cargo-vendor-dir, not @vendor@.
          # Keep its registry/git mappings, but resolve crates from the store.
          substitute ${lumisNifVendor}/.cargo/config.toml "$CARGO_HOME/config.toml" \
            --replace-fail 'directory = "cargo-vendor-dir"' 'directory = "${lumisNifVendor}"'
        '';
      };
    };
  };

  # callPackage also adds override/overrideDerivation helpers to the result.
  # Only package derivations belong in the build inputs or the deps/ symlinks.
  mixNixDeps = (lib.filterAttrs (_: lib.isDerivation) deps) // {
    inherit daisyui;
  };
in
beamPackages.mixRelease {
  pname = "tackle-web";
  version = "0.1.0";
  inherit src mixNixDeps;

  postUnpack = ''
    sourceRoot="$sourceRoot/frontends/tackle_web"
  '';

  # mixRelease's build phase has already run `mix compile --no-deps-check`.
  # Build the assets the endpoint serves. The Tailwind and Esbuild packages
  # expect their executables at bin_path(); point those at the nixpkgs builds so
  # nothing is downloaded. mixRelease already symlinked the deps that carry a
  # `src` attribute (daisyui, heroicons) into deps/, which is what NODE_PATH and
  # the heroicons plugin read.
  postBuild = ''
    tailwind_path="$(mix do app.config --no-deps-check --no-compile, eval 'Tailwind.bin_path() |> IO.puts()')"
    esbuild_path="$(mix do app.config --no-deps-check --no-compile, eval 'Esbuild.bin_path() |> IO.puts()')"

    ln -sfvn ${pkgs.tailwindcss_4}/bin/tailwindcss "$tailwind_path"
    ln -sfvn ${pkgs.esbuild}/bin/esbuild "$esbuild_path"

    mix do app.config --no-deps-check --no-compile, assets.deploy --no-deps-check
  '';

  # The release reads SECRET_KEY_BASE, PORT and PHX_SERVER from the environment
  # at boot (config/runtime.exs); nothing secret is embedded here.
  passthru = {
    inherit mixNixDeps forcolaShim daisyui;
  };

  meta = {
    description = "Tackle web frontend: Phoenix LiveView PR review interface";
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
      "aarch64-darwin"
      "x86_64-darwin"
    ];
  };
}
