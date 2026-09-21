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

      assent =
        let
          version = "0.3.1";
          drv = buildMix {
            inherit version;
            name = "assent";

            src = fetchHex {
              inherit version;
              pkg = "assent";
              sha256 = "3597b31f9eb556d97e64cf60c00d3451f7353d7b465a71d33530b870ebed1ff1";
            };

            beamDeps = [
              finch
              req
            ];
          };
        in
        drv;

      bandit =
        let
          version = "1.12.5";
          drv = buildMix {
            inherit version;
            name = "bandit";

            src = fetchHex {
              inherit version;
              pkg = "bandit";
              sha256 = "c5684ca062fa407cac115aec3256383f3e2ec9fdced7904d59cf5a7bb7ed6181";
            };

            beamDeps = [
              hpax
              plug
              telemetry
              thousand_island
              websock
            ];
          };
        in
        drv;

      esbuild =
        let
          version = "0.10.0";
          drv = buildMix {
            inherit version;
            name = "esbuild";

            src = fetchHex {
              inherit version;
              pkg = "esbuild";
              sha256 = "468489cda427b974a7cc9f03ace55368a83e1a7be12fba7e30969af78e5f8c70";
            };

            beamDeps = [
              jason
            ];
          };
        in
        drv;

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

      forcola =
        let
          version = "0.3.3";
          drv = buildMix {
            inherit version;
            name = "forcola";

            src = fetchHex {
              inherit version;
              pkg = "forcola";
              sha256 = "488e8678683c25e7c9660a8a501743b4e334d91ca5fbc130afb3368a19ed2b10";
            };
          };
        in
        drv;

      git =
        let
          version = "0.7.0";
          drv = buildMix {
            inherit version;
            name = "git";

            src = fetchHex {
              inherit version;
              pkg = "git";
              sha256 = "f506599d72cff64ebbc03363bba35fb44d71d7efceb4edd5200c1f767e7144ba";
            };

            beamDeps = [
              forcola
            ];
          };
        in
        drv;

      git_diff =
        let
          version = "0.6.4";
          drv = buildMix {
            inherit version;
            name = "git_diff";

            src = fetchHex {
              inherit version;
              pkg = "git_diff";
              sha256 = "9e05563c136c91e960a306fd296156b2e8d74e294ae60961e69a36e118023a5f";
            };
          };
        in
        drv;

      heroicons = stdenv.mkDerivation {
        name = "heroicons";
        src = fetchFromGitHub {
          owner = "tailwindlabs";
          repo = "heroicons";
          rev = "0435d4ca364a608cc75e2f8683d374e55abbae26";
          hash = "sha256-Jcxr1fSbmXO9bZKeg39Z/zVN0YJp17TX3LH5Us4lsZU=";
        };
        buildPhase = ''
          mkdir $out
          ln -sv $src $out/src
        '';
      };

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
          version = "0.23.0";
          drv = buildMix {
            inherit version;
            name = "jsv";

            src = fetchHex {
              inherit version;
              pkg = "jsv";
              sha256 = "3876f6ada437b3a7ec6214c9b942bd218f25d245b92a7970a034a7cf06dbe925";
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

      lumis =
        let
          version = "0.8.0";
          drv = buildMix {
            inherit version;
            name = "lumis";

            src = fetchHex {
              inherit version;
              pkg = "lumis";
              sha256 = "d5b71a5b082f32fc1d007d02f03922db95b9caec335b03a1985edb726c59f63e";
            };

            beamDeps = [
              nimble_options
              rustler
              rustler_precompiled
            ];
          };
        in
        drv.override (workarounds.rustlerPrecompiled { } drv);

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

      phoenix =
        let
          version = "1.8.14";
          drv = buildMix {
            inherit version;
            name = "phoenix";

            src = fetchHex {
              inherit version;
              pkg = "phoenix";
              sha256 = "2782ff375824b2b5e41561fbae4764ee7b875af6898483bca49f24a9d1e37816";
            };

            beamDeps = [
              bandit
              jason
              phoenix_pubsub
              phoenix_template
              plug
              plug_crypto
              telemetry
              websock_adapter
            ];
          };
        in
        drv;

      phoenix_html =
        let
          version = "4.3.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_html";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_html";
              sha256 = "3eaa290a78bab0f075f791a46a981bbe769d94bc776869f4f3063a14f30497ad";
            };
          };
        in
        drv;

      phoenix_live_dashboard =
        let
          version = "0.8.7";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_dashboard";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_dashboard";
              sha256 = "3a8625cab39ec261d48a13b7468dc619c0ede099601b084e343968309bd4d7d7";
            };

            beamDeps = [
              mime
              phoenix_live_view
              telemetry_metrics
            ];
          };
        in
        drv;

      phoenix_live_view =
        let
          version = "1.1.33";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_view";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_view";
              sha256 = "2030f7987f641a269634e021bcde9373e5dea993f9373e628a44da86b2330b6c";
            };

            beamDeps = [
              jason
              phoenix
              phoenix_html
              phoenix_template
              plug
              telemetry
            ];
          };
        in
        drv;

      phoenix_pubsub =
        let
          version = "2.3.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_pubsub";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_pubsub";
              sha256 = "eec7be6e9cf02e2551d389b558402d6c637cd3973796326e7ba4bb03c6b2e91d";
            };
          };
        in
        drv;

      phoenix_template =
        let
          version = "1.0.4";
          drv = buildMix {
            inherit version;
            name = "phoenix_template";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_template";
              sha256 = "2c0c81f0e5c6753faf5cca2f229c9709919aba34fab866d3bc05060c9c444206";
            };

            beamDeps = [
              phoenix_html
            ];
          };
        in
        drv;

      plug =
        let
          version = "1.20.3";
          drv = buildMix {
            inherit version;
            name = "plug";

            src = fetchHex {
              inherit version;
              pkg = "plug";
              sha256 = "be266aee1b8536ef6409d58cf39a3121319f0ec47cfa1b24024485aa0e76ad76";
            };

            beamDeps = [
              mime
              plug_crypto
              telemetry
            ];
          };
        in
        drv;

      plug_crypto =
        let
          version = "2.2.0";
          drv = buildMix {
            inherit version;
            name = "plug_crypto";

            src = fetchHex {
              inherit version;
              pkg = "plug_crypto";
              sha256 = "83a95744ab1c75876542b6fab135fcc176280e0f301a111c1f757fddcec95d2c";
            };
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
              plug
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

            src = ../../..;

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

            src = ../../../plugins/tackle_codex;

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

            src = ../../../plugins/tackle_deepseek;

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

            src = ../../../packages/tackle_lib;

            beamDeps = [
              jsv
              telemetry
            ];
          };
        in
        drv;

      tackle_phoenix =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "tackle_phoenix";

            src = ../../../packages/tackle_phoenix;

            beamDeps = [
              tackle_lib
              tackle_runtime
              phoenix_live_view
              phoenix_pubsub
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

            src = ../../../packages/tackle_runtime;

            beamDeps = [
              tackle_lib
            ];
          };
        in
        drv;

      tailwind =
        let
          version = "0.5.1";
          drv = buildMix {
            inherit version;
            name = "tailwind";

            src = fetchHex {
              inherit version;
              pkg = "tailwind";
              sha256 = "c4e26302a59fec72abc5610ecb6ad2116d9aa31f31aab2d4b8eb6e95d25a689c";
            };
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

      telemetry_metrics =
        let
          version = "1.2.0";
          drv = buildMix {
            inherit version;
            name = "telemetry_metrics";

            src = fetchHex {
              inherit version;
              pkg = "telemetry_metrics";
              sha256 = "71dde12fc29b58b9c77ec17ec319109e5ca848d010fc1965ed4463bba1837c07";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      telemetry_poller =
        let
          version = "1.3.0";
          drv = buildRebar3 {
            inherit version;
            name = "telemetry_poller";

            src = fetchHex {
              inherit version;
              pkg = "telemetry_poller";
              sha256 = "51f18bed7128544a50f75897db9974436ea9bfba560420b646af27a9a9b35211";
            };

            beamDeps = [
              telemetry
            ];
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

      thousand_island =
        let
          version = "1.5.0";
          drv = buildMix {
            inherit version;
            name = "thousand_island";

            src = fetchHex {
              inherit version;
              pkg = "thousand_island";
              sha256 = "708923d40523e43cf99041ab37a0d4b0ec426ac6438fa3716ab23d919eaeb412";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      websock =
        let
          version = "0.5.3";
          drv = buildMix {
            inherit version;
            name = "websock";

            src = fetchHex {
              inherit version;
              pkg = "websock";
              sha256 = "6105453d7fac22c712ad66fab1d45abdf049868f253cf719b625151460b8b453";
            };
          };
        in
        drv;

      websock_adapter =
        let
          version = "0.6.0";
          drv = buildMix {
            inherit version;
            name = "websock_adapter";

            src = fetchHex {
              inherit version;
              pkg = "websock_adapter";
              sha256 = "50021a85bce8f203b086705d9e0c5415e2c7eb05d319111b0428fe71f9934617";
            };

            beamDeps = [
              bandit
              plug
              websock
            ];
          };
        in
        drv;

    };
in
self
