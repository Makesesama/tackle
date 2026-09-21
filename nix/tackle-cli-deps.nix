{
  lib,
  beamPackages,
  cmake,
  extend,
  lexbor,
  fetchFromGitHub,
  oniguruma,
  overrides ? (x: y: { }),
  overrideFenixOverlay ? null,
  rustlerPrecompiledOverrides ? { },
  stdenv,
  pkg-config,
  vips,
  writeText,
}:

let
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;

  workarounds = {
    portCompiler = _unusedArgs: old: {
      buildPlugins = [ beamPackages.pc ];
    };

    rustlerPrecompiled =
      {
        toolchain ? null,
        buildInputs ? [ ],
        nativeBuildInputs ? [ ],
        env ? { },
        ...
      }:
      old:
      let
        extendedPkgs = extend fenixOverlay;
        fenixOverlay =
          if overrideFenixOverlay == null then
            import "${
              fetchTarball {
                url = "https://github.com/nix-community/fenix/archive/6399553b7a300c77e7f07342904eb696a5b6bf9d.tar.gz";
                sha256 = "sha256-C6tT7K1Lx6VsYw1BY5S3OavtapUvEnDQtmQB5DSgbCc=";
              }
            }/overlay.nix"
          else
            overrideFenixOverlay;
        nativeDir = "${old.src}/native/${with builtins; head (attrNames (readDir "${old.src}/native"))}";
        fenix =
          if toolchain == null then
            extendedPkgs.fenix.stable
          else
            extendedPkgs.fenix.fromToolchainName toolchain;
        native =
          (
            (extendedPkgs.makeRustPlatform {
              inherit (fenix) cargo rustc;
            }).buildRustPackage
            {
              inherit env buildInputs;
              pname = "${old.beamModuleName}-native";
              version = old.version;
              src = nativeDir;
              cargoLock = {
                lockFile = "${nativeDir}/Cargo.lock";
              };
              nativeBuildInputs = [ extendedPkgs.cmake ] ++ nativeBuildInputs;
              doCheck = false;
            }
          ).overrideAttrs
            rustlerPrecompiledOverrides.${old.beamModuleName} or { };

      in
      {
        nativeBuildInputs = [ extendedPkgs.cargo ];

        env.RUSTLER_PRECOMPILED_FORCE_BUILD_ALL = "true";
        env.RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = "unused-but-required";

        preConfigure = ''
          mkdir -p priv/native
          for lib in ${native}/lib/*
          do
            dest="$(basename "$lib")"
            if [[ "''${dest##*.}" = "dylib" ]]
            then
              dest="''${dest%.dylib}.so"
            fi
            dest="''${dest#lib}"
            ln -s "$lib" "priv/native/$dest"
          done
        '';

        preBuild = ''
          suggestion() {
            echo "***********************************************"
            echo "                 deps_nix                      "
            echo
            echo " Rust dependency build failed.                 "
            echo
            echo " If you saw network errors, you might need     "
            echo " to disable compilation on the appropriate     "
            echo " RustlerPrecompiled module in your             "
            echo " application config.                           "
            echo
            echo " We think you need this:                       "
            echo
            echo -n " "
            grep -Rl 'use RustlerPrecompiled' lib \
              | xargs grep 'defmodule' \
              | sed 's/defmodule \(.*\) do/config :${old.beamModuleName}, \1, skip_compilation?: true/'
            echo "***********************************************"
            exit 1
          }
          trap suggestion ERR
        '';
      };

    elixirMake = _unusedArgs: old: {
      preConfigure = ''
        export ELIXIR_MAKE_CACHE_DIR="$TEMPDIR/elixir_make_cache"
      '';
    };

    lazyHtml = _unusedArgs: old: {
      preConfigure = ''
        export ELIXIR_MAKE_CACHE_DIR="$TEMPDIR/elixir_make_cache"
      '';

      postPatch = ''
        substituteInPlace mix.exs \
          --replace-fail "Fine.include_dir()" '"${packages.fine}/src/c_include"' \
          --replace-fail '@lexbor_git_sha "244b84956a6dc7eec293781d051354f351274c46"' '@lexbor_git_sha ""'
      '';

      preBuild = ''
        install -Dm644           -t _build/c/third_party/lexbor/$LEXBOR_GIT_SHA/build           ${lexbor}/lib/liblexbor_static.a
      '';
    };
  };

  defaultOverrides = (
    final: prev:

    let
      apps = {
        crc32cer = [
          {
            name = "portCompiler";
          }
        ];
        explorer = [
          {
            name = "rustlerPrecompiled";
            toolchain = {
              name = "nightly-2025-06-23";
              sha256 = "sha256-UAoZcxg3iWtS+2n8TFNfANFt/GmkuOMDf7QAE0fRxeA=";
            };
          }
        ];
        snappyer = [
          {
            name = "portCompiler";
          }
        ];
      };

      applyOverrides =
        appName: drv:
        let
          allOverridesForApp = builtins.foldl' (
            acc: workaround: acc // (workarounds.${workaround.name} workaround) drv
          ) { } apps.${appName};

        in
        if builtins.hasAttr appName apps then drv.override allOverridesForApp else drv;

    in
    builtins.mapAttrs applyOverrides prev
  );

  self = packages // (defaultOverrides self packages) // (overrides self packages);

  packages =
    with beamPackages;
    with self;
    {

      abnf_parsec =
        let
          version = "2.1.0";
          drv = buildMix {
            inherit version;
            name = "abnf_parsec";

            src = fetchHex {
              inherit version;
              pkg = "abnf_parsec";
              sha256 = "e0ed6290c7cc7e5020c006d1003520390c9bdd20f7c3f776bd49bfe3c5cd362a";
            };

            beamDeps = [
              nimble_parsec
            ];
          };
        in
        drv;

      burrito =
        let
          version = "1.6.0";
          drv = buildMix {
            inherit version;
            name = "burrito";

            src = fetchHex {
              inherit version;
              pkg = "burrito";
              sha256 = "e636a00b032c45a69ff755d9fc53fa5fdc9e1d21bdbd229075fe4a15b05355fe";
            };

            beamDeps = [
              jason
              req
              typed_struct
            ];
          };
        in
        drv;

      ex_ratatui =
        let
          version = "0.15.0";
          drv = buildMix {
            inherit version;
            name = "ex_ratatui";

            src = fetchHex {
              inherit version;
              pkg = "ex_ratatui";
              sha256 = "77a576dc6e439cf749e00e06a84290692e5e8d5515110628f2c9b053a19fe932";
            };

            beamDeps = [
              rustler_precompiled
              telemetry
              rustler
            ];
          };
        in
        drv.override (workarounds.rustlerPrecompiled { } drv);

      finch =
        let
          version = "0.23.0";
          drv = buildMix {
            inherit version;
            name = "finch";

            src = fetchHex {
              inherit version;
              pkg = "finch";
              sha256 = "80e58d3f936f57e3fdf404f83a3642897ae6d9fb642934e46da4d8fe761b99d5";
            };

            beamDeps = [
              mime
              mint
              nimble_options
              nimble_pool
              telemetry
            ];
          };
        in
        drv;

      hpax =
        let
          version = "1.0.4";
          drv = buildMix {
            inherit version;
            name = "hpax";

            src = fetchHex {
              inherit version;
              pkg = "hpax";
              sha256 = "afc7cb142ebcc2d01ce7816190b98ce5dd49e799111b24249f3443d730f377ca";
            };
          };
        in
        drv;

      idna =
        let
          version = "7.1.0";
          drv = buildRebar3 {
            inherit version;
            name = "idna";

            src = fetchHex {
              inherit version;
              pkg = "idna";
              sha256 = "6ae959a025bf36df61a8cab8508d9654891b5426a84c44d82deaffd6ddf8c71f";
            };
          };
        in
        drv;

      jason =
        let
          version = "1.4.5";
          drv = buildMix {
            inherit version;
            name = "jason";

            src = fetchHex {
              inherit version;
              pkg = "jason";
              sha256 = "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684";
            };
          };
        in
        drv;

      jsv =
        let
          version = "0.22.0";
          drv = buildMix {
            inherit version;
            name = "jsv";

            src = fetchHex {
              inherit version;
              pkg = "jsv";
              sha256 = "79bae1f970413c86771051a8ea0bd553cc1e866d285270be539f1ef3ca044f3c";
            };

            beamDeps = [
              abnf_parsec
              idna
              jason
              texture
            ];
          };
        in
        drv;

      mime =
        let
          version = "2.0.7";
          drv = buildMix {
            inherit version;
            name = "mime";

            src = fetchHex {
              inherit version;
              pkg = "mime";
              sha256 = "6171188e399ee16023ffc5b76ce445eb6d9672e2e241d2df6050f3c771e80ccd";
            };
          };
        in
        drv;

      mint =
        let
          version = "1.10.0";
          drv = buildMix {
            inherit version;
            name = "mint";

            src = fetchHex {
              inherit version;
              pkg = "mint";
              sha256 = "8b16fb72aaa7531d206a1f05e4cc85509ba531ccec7a17a22736c9c95cbb24d1";
            };

            beamDeps = [
              hpax
            ];
          };
        in
        drv;

      mint_web_socket =
        let
          version = "1.0.6";
          drv = buildMix {
            inherit version;
            name = "mint_web_socket";

            src = fetchHex {
              inherit version;
              pkg = "mint_web_socket";
              sha256 = "0c360e9012413f1c115a63532601eb5d63731aab7010949178769760686c1698";
            };

            beamDeps = [
              mint
            ];
          };
        in
        drv;

      nimble_options =
        let
          version = "1.1.1";
          drv = buildMix {
            inherit version;
            name = "nimble_options";

            src = fetchHex {
              inherit version;
              pkg = "nimble_options";
              sha256 = "821b2470ca9442c4b6984882fe9bb0389371b8ddec4d45a9504f00a66f650b44";
            };
          };
        in
        drv;

      nimble_parsec =
        let
          version = "1.4.2";
          drv = buildMix {
            inherit version;
            name = "nimble_parsec";

            src = fetchHex {
              inherit version;
              pkg = "nimble_parsec";
              sha256 = "4b21398942dda052b403bbe1da991ccd03a053668d147d53fb8c4e0efe09c973";
            };
          };
        in
        drv;

      nimble_pool =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "nimble_pool";

            src = fetchHex {
              inherit version;
              pkg = "nimble_pool";
              sha256 = "af2e4e6b34197db81f7aad230c1118eac993acc0dae6bc83bac0126d4ae0813a";
            };
          };
        in
        drv;

      optimus =
        let
          version = "0.6.1";
          drv = buildMix {
            inherit version;
            name = "optimus";

            src = fetchHex {
              inherit version;
              pkg = "optimus";
              sha256 = "c0db4107a51f5af94de8b05e4208333ebb8016a3bfdbcd74df6e5c99829db17f";
            };
          };
        in
        drv;

      owl =
        let
          version = "0.13.1";
          drv = buildMix {
            inherit version;
            name = "owl";

            src = fetchHex {
              inherit version;
              pkg = "owl";
              sha256 = "351e768af8f2edc575cdaab1a5a2f6d6381be591758a026c701c703145508a0c";
            };

            beamDeps = [
              ucwidth
            ];
          };
        in
        drv;

      req =
        let
          version = "0.8.0-rc.0";
          drv = buildMix {
            inherit version;
            name = "req";

            src = fetchHex {
              inherit version;
              pkg = "req";
              sha256 = "f071cc7bc2bd4ace1a86d7f24b98e7aa2c57cecb228b217e5eb667c934229347";
            };

            beamDeps = [
              finch
              mime
              server_sent_events
            ];
          };
        in
        drv;

      rustler =
        let
          version = "0.38.0";
          drv = buildMix {
            inherit version;
            name = "rustler";

            src = fetchHex {
              inherit version;
              pkg = "rustler";
              sha256 = "704c03c1bf66be12b031c5a389347b91c81c5cb819a24b068b0de36fe4a5652a";
            };

            beamDeps = [
              jason
            ];
          };
        in
        drv;

      rustler_precompiled =
        let
          version = "0.9.0";
          drv = buildMix {
            inherit version;
            name = "rustler_precompiled";

            src = fetchHex {
              inherit version;
              pkg = "rustler_precompiled";
              sha256 = "471d97315bd3bf7b64623418b3693eedd8e47de3d1cb79a0ac8f9da7d770d94c";
            };

            beamDeps = [
              rustler
            ];
          };
        in
        drv;

      server_sent_events =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "server_sent_events";

            src = fetchHex {
              inherit version;
              pkg = "server_sent_events";
              sha256 = "8e164db8e295a2d869a8faafbf4a1eeaa749b62fe93f66271adff6394d93ce15";
            };
          };
        in
        drv;

      tackle =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "tackle";

            src = ../packages/tackle;

            beamDeps = [
              tackle_lib
              tackle_runtime
            ];
          };
        in
        drv;

      tackle_codex =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "tackle_codex";

            src = ../packages/tackle_codex;

            beamDeps = [
              req
              mint_web_socket
              tackle_lib
            ];
          };
        in
        drv;

      tackle_deepseek =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "tackle_deepseek";

            src = ../packages/tackle_deepseek;

            beamDeps = [
              req
              tackle_lib
            ];
          };
        in
        drv;

      tackle_lib =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "tackle_lib";

            src = ../packages/tackle_lib;

            beamDeps = [
              jsv
              telemetry
            ];
          };
        in
        drv;

      tackle_runtime =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "tackle_runtime";

            src = ../packages/tackle_runtime;

            beamDeps = [
              tackle_lib
            ];
          };
        in
        drv;

      telemetry =
        let
          version = "1.4.2";
          drv = buildRebar3 {
            inherit version;
            name = "telemetry";

            src = fetchHex {
              inherit version;
              pkg = "telemetry";
              sha256 = "928f6495066506077862c0d1646609eed891a4326bee3126ba54b60af61febb1";
            };
          };
        in
        drv;

      texture =
        let
          version = "1.2.1";
          drv = buildMix {
            inherit version;
            name = "texture";

            src = fetchHex {
              inherit version;
              pkg = "texture";
              sha256 = "925b1938891ce5c1d589df408faa7ed57dd872e4aac9521b32495a29b265cb17";
            };

            beamDeps = [
              abnf_parsec
            ];
          };
        in
        drv;

      typed_struct =
        let
          version = "0.3.0";
          drv = buildMix {
            inherit version;
            name = "typed_struct";

            src = fetchHex {
              inherit version;
              pkg = "typed_struct";
              sha256 = "c50bd5c3a61fe4e198a8504f939be3d3c85903b382bde4865579bc23111d1b6d";
            };
          };
        in
        drv;

      ucwidth =
        let
          version = "0.2.0";
          drv = buildMix {
            inherit version;
            name = "ucwidth";

            src = fetchHex {
              inherit version;
              pkg = "ucwidth";
              sha256 = "c1efd1798b8eeb11fb2bec3cafa3dd9c0c3647bee020543f0340b996177355bf";
            };
          };
        in
        drv;

    };
in
self
