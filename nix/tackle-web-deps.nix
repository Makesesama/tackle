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

      ash =
        let
          version = "3.36.1";
          drv = buildMix {
            inherit version;
            name = "ash";

            src = fetchHex {
              inherit version;
              pkg = "ash";
              sha256 = "b198d2ac54a9948f1ccab649502e910f7fd0b7639e0280704432a52088ed1c28";
            };

            beamDeps = [
              crux
              decimal
              ecto
              ets
              jason
              plug
              reactor
              spark
              splode
              stream_data
              telemetry
            ];
          };
        in
        drv;

      ash_cloak =
        let
          version = "0.4.0";
          drv = buildMix {
            inherit version;
            name = "ash_cloak";

            src = fetchHex {
              inherit version;
              pkg = "ash_cloak";
              sha256 = "d55bde03e90f8e31436ebec069681cbdab0875de52efe0939e5e2c3f32b91efd";
            };

            beamDeps = [
              ash
            ];
          };
        in
        drv;

      ash_oban =
        let
          version = "0.10.1";
          drv = buildMix {
            inherit version;
            name = "ash_oban";

            src = fetchHex {
              inherit version;
              pkg = "ash_oban";
              sha256 = "1a1c2fc708641742d25cc8e7e4ebb66d86e76b3dbec62d49cefa5e6a57d2f73a";
            };

            beamDeps = [
              ash
              oban
              postgrex
            ];
          };
        in
        drv;

      ash_phoenix =
        let
          version = "2.3.25";
          drv = buildMix {
            inherit version;
            name = "ash_phoenix";

            src = fetchHex {
              inherit version;
              pkg = "ash_phoenix";
              sha256 = "2ca4039c85041c2f59933a9ae1df20397a6d416772473a7baa5ff7c55df64f06";
            };

            beamDeps = [
              ash
              phoenix
              phoenix_html
              phoenix_live_view
              spark
            ];
          };
        in
        drv;

      ash_postgres =
        let
          version = "2.14.5";
          drv = buildMix {
            inherit version;
            name = "ash_postgres";

            src = fetchHex {
              inherit version;
              pkg = "ash_postgres";
              sha256 = "e2993a5ba796b613870e7ee5d47f7e7a007e87061d475a916d1158b58fcd8fdd";
            };

            beamDeps = [
              ash
              ash_sql
              ecto
              ecto_sql
              jason
              postgrex
              spark
            ];
          };
        in
        drv;

      ash_sql =
        let
          version = "0.8.2";
          drv = buildMix {
            inherit version;
            name = "ash_sql";

            src = fetchHex {
              inherit version;
              pkg = "ash_sql";
              sha256 = "b80e5ec9c59bfc9753ff1636498838b5c75aac03de3f78d6dd444dd96510e142";
            };

            beamDeps = [
              ash
              ecto
              ecto_sql
              jason
            ];
          };
        in
        drv;

      bandit =
        let
          version = "1.13.1";
          drv = buildMix {
            inherit version;
            name = "bandit";

            src = fetchHex {
              inherit version;
              pkg = "bandit";
              sha256 = "39028f0b5a21404661410a6c19275060a9822c9dcca70b7c3e4e4fa50b11da58";
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

      cloak =
        let
          version = "1.1.4";
          drv = buildMix {
            inherit version;
            name = "cloak";

            src = fetchHex {
              inherit version;
              pkg = "cloak";
              sha256 = "92b20527b9aba3d939fab0dd32ce592ff86361547cfdc87d74edce6f980eb3d7";
            };

            beamDeps = [
              jason
            ];
          };
        in
        drv;

      crux =
        let
          version = "0.1.4";
          drv = buildMix {
            inherit version;
            name = "crux";

            src = fetchHex {
              inherit version;
              pkg = "crux";
              sha256 = "ff7d880cf732d82360aa81e439b8d4831cd30768061c9233f90c97e10162b9c0";
            };

            beamDeps = [
              stream_data
            ];
          };
        in
        drv;

      db_connection =
        let
          version = "2.10.2";
          drv = buildMix {
            inherit version;
            name = "db_connection";

            src = fetchHex {
              inherit version;
              pkg = "db_connection";
              sha256 = "510b14482330f1af6490a2fa0efd8d4f1435d1529b165647df22ac0f2df0fa93";
            };

            beamDeps = [
              telemetry
            ];
          };
        in
        drv;

      decimal =
        let
          version = "3.2.0";
          drv = buildMix {
            inherit version;
            name = "decimal";

            src = fetchHex {
              inherit version;
              pkg = "decimal";
              sha256 = "190bca80580ce61aa69bb0eacadd7677710205c770225c2c2c07e32a5c31b234";
            };
          };
        in
        drv;

      ecto =
        let
          version = "3.14.2";
          drv = buildMix {
            inherit version;
            name = "ecto";

            src = fetchHex {
              inherit version;
              pkg = "ecto";
              sha256 = "25d60b8c816a07d19d85b80bdf60978bd8b102209dda198d768cd7c6745339a6";
            };

            beamDeps = [
              decimal
              jason
              telemetry
            ];
          };
        in
        drv;

      ecto_sql =
        let
          version = "3.14.0";
          drv = buildMix {
            inherit version;
            name = "ecto_sql";

            src = fetchHex {
              inherit version;
              pkg = "ecto_sql";
              sha256 = "f4d8d36faf294c9417b5a37ec7ac8217ee2abdef5fcf197ba690f361548d3949";
            };

            beamDeps = [
              db_connection
              decimal
              ecto
              postgrex
              telemetry
            ];
          };
        in
        drv;

      ets =
        let
          version = "0.9.0";
          drv = buildMix {
            inherit version;
            name = "ets";

            src = fetchHex {
              inherit version;
              pkg = "ets";
              sha256 = "2861fdfb04bcaeff370f1a5904eec864f0a56dcfebe5921ea9aadf2a481c822b";
            };
          };
        in
        drv;

      finch =
        let
          version = "0.24.0";
          drv = buildMix {
            inherit version;
            name = "finch";

            src = fetchHex {
              inherit version;
              pkg = "finch";
              sha256 = "33ba40069c3587c2f99f9125b766e19dad87d6d54be3c6961db2304df04cef00";
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

      gix_ex =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "gix_ex";

            src = ../packages/gix_ex;

            beamDeps = [
              rustler
            ];
          };
        in
        drv;

      hpax =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "hpax";

            src = fetchHex {
              inherit version;
              pkg = "hpax";
              sha256 = "0b8d0f05832f55571d65ac720f79bf8994138ffbb133209dc4685eae0ad456a8";
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

      iterex =
        let
          version = "0.1.2";
          drv = buildMix {
            inherit version;
            name = "iterex";

            src = fetchHex {
              inherit version;
              pkg = "iterex";
              sha256 = "2e103b8bcc81757a9af121f6dc0df312c9a17220f302b1193ef720460d03029d";
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

            beamDeps = [
              decimal
            ];
          };
        in
        drv;

      jsv =
        let
          version = "0.26.1";
          drv = buildMix {
            inherit version;
            name = "jsv";

            src = fetchHex {
              inherit version;
              pkg = "jsv";
              sha256 = "039971fbdddc3d49e88fc8a2bb7ad51ac409f97ca1db4c95a56cc1afa3c1c3d4";
            };

            beamDeps = [
              abnf_parsec
              decimal
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
          version = "1.11.0";
          drv = buildMix {
            inherit version;
            name = "mint";

            src = fetchHex {
              inherit version;
              pkg = "mint";
              sha256 = "c6279ba2d6aa3a383a1d4cfbe7b59f42e6efd400f58d8e2acfeac48a438693ab";
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

      multigraph =
        let
          version = "0.16.1-mg.5";
          drv = buildMix {
            inherit version;
            name = "multigraph";

            src = fetchHex {
              inherit version;
              pkg = "multigraph";
              sha256 = "d7e3511f1d29e96ed7e7cd01b92bb52eea487b6c61da838f1e61a2ec6838799d";
            };
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

      oban =
        let
          version = "2.24.2";
          drv = buildMix {
            inherit version;
            name = "oban";

            src = fetchHex {
              inherit version;
              pkg = "oban";
              sha256 = "605a3b61d554ab416e0cf462b5ea060f7d19ae3dbf1516ec6b5ee30aeb1a5d0b";
            };

            beamDeps = [
              ecto_sql
              jason
              postgrex
              telemetry
            ];
          };
        in
        drv;

      phoenix =
        let
          version = "1.8.15";
          drv = buildMix {
            inherit version;
            name = "phoenix";

            src = fetchHex {
              inherit version;
              pkg = "phoenix";
              sha256 = "7b83ed6b3d544f24a29277eab7f051be38b76f390bb511bb6ddb7ec6e8e05b95";
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

      phoenix_live_view =
        let
          version = "1.2.12";
          drv = buildMix {
            inherit version;
            name = "phoenix_live_view";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_live_view";
              sha256 = "656810d716e3369545dd63981196a5d68b77fdb253afe02ef0c6fa14cfd8dc2b";
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
          version = "2.4.1";
          drv = buildMix {
            inherit version;
            name = "phoenix_pubsub";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_pubsub";
              sha256 = "352fba7a87bf61395b6e97da66944ad9b1bfe5459e5981039f60d68270bd9700";
            };
          };
        in
        drv;

      phoenix_template =
        let
          version = "1.1.0";
          drv = buildMix {
            inherit version;
            name = "phoenix_template";

            src = fetchHex {
              inherit version;
              pkg = "phoenix_template";
              sha256 = "eba70070de79b2c3501ef205a74a69f98ab352f3785aa15da9ed161f9fe0fd5d";
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

      postgrex =
        let
          version = "0.22.4";
          drv = buildMix {
            inherit version;
            name = "postgrex";

            src = fetchHex {
              inherit version;
              pkg = "postgrex";
              sha256 = "4aae45a2d60e35b04eea2602440be152fae332901f1fc7a60fc7cb7f0f9a9c5a";
            };

            beamDeps = [
              db_connection
              decimal
              jason
            ];
          };
        in
        drv;

      reactor =
        let
          version = "1.0.7";
          drv = buildMix {
            inherit version;
            name = "reactor";

            src = fetchHex {
              inherit version;
              pkg = "reactor";
              sha256 = "d5eddbdcdf1016d76d713c927741f6db21421271cea015b0d355d6b1097206a4";
            };

            beamDeps = [
              iterex
              jason
              multigraph
              spark
              splode
              telemetry
              yaml_elixir
              ymlr
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

      spark =
        let
          version = "2.7.8";
          drv = buildMix {
            inherit version;
            name = "spark";

            src = fetchHex {
              inherit version;
              pkg = "spark";
              sha256 = "9d75a06369f6a70116b1a256a7fcf5c2442798623bbdd8802364859bf3dc4a8e";
            };

            beamDeps = [
              jason
            ];
          };
        in
        drv;

      splode =
        let
          version = "0.3.2";
          drv = buildMix {
            inherit version;
            name = "splode";

            src = fetchHex {
              inherit version;
              pkg = "splode";
              sha256 = "08fd658f80da7f1cd254b149164dcff8acd44b22f032001d5416b97223d32bc9";
            };
          };
        in
        drv;

      stream_data =
        let
          version = "1.4.0";
          drv = buildMix {
            inherit version;
            name = "stream_data";

            src = fetchHex {
              inherit version;
              pkg = "stream_data";
              sha256 = "2b0ee3a340dcce1c8cf6302a763ee757d1e01c54d6e16d9069062509d68b1dc9";
            };
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

      tackle_exec =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "tackle_exec";

            src = ../packages/tackle_exec;

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

      tackle_openrouter =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "tackle_openrouter";

            src = ../packages/tackle_openrouter;

            beamDeps = [
              req
              tackle_lib
            ];
          };
        in
        drv;

      tackle_review =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "tackle_review";

            src = ../packages/tackle_review;

            beamDeps = [
              tackle_lib
              tackle_runtime
              gix_ex
              yaml_frontmatter
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

      tackle_tools =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "tackle_tools";

            src = ../packages/tackle_tools;

            beamDeps = [
              tackle_lib
              tackle_exec
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
          version = "2.0.0";
          drv = buildMix {
            inherit version;
            name = "texture";

            src = fetchHex {
              inherit version;
              pkg = "texture";
              sha256 = "c85cbac5f456f4c9867deb0f70c45daa8a536142a8c8c5403401bd51962660bc";
            };

            beamDeps = [
              abnf_parsec
            ];
          };
        in
        drv;

      thousand_island =
        let
          version = "1.6.0";
          drv = buildMix {
            inherit version;
            name = "thousand_island";

            src = fetchHex {
              inherit version;
              pkg = "thousand_island";
              sha256 = "4d4720470f091fc21a1311777c2ac66916c43621bffc068590c9f9bb3cd057a3";
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

      yamerl =
        let
          version = "0.10.0";
          drv = buildRebar3 {
            inherit version;
            name = "yamerl";

            src = fetchHex {
              inherit version;
              pkg = "yamerl";
              sha256 = "346adb2963f1051dc837a2364e4acf6eb7d80097c0f53cbdc3046ec8ec4b4e6e";
            };
          };
        in
        drv;

      yaml_elixir =
        let
          version = "2.12.2";
          drv = buildMix {
            inherit version;
            name = "yaml_elixir";

            src = fetchHex {
              inherit version;
              pkg = "yaml_elixir";
              sha256 = "e7c1b10122f973e6558462d51c39026ba0e14afbc6745318e990ea82cfe9e159";
            };

            beamDeps = [
              yamerl
            ];
          };
        in
        drv;

      yaml_frontmatter =
        let
          version = "0.1.0";
          drv = buildMix {
            inherit version;
            name = "yaml_frontmatter";

            src = ../packages/yaml_frontmatter;

          };
        in
        drv;

      ymlr =
        let
          version = "5.1.6";
          drv = buildMix {
            inherit version;
            name = "ymlr";

            src = fetchHex {
              inherit version;
              pkg = "ymlr";
              sha256 = "b36d7c72384d2cb2094d2a3c8b0c3b12303e0ccd1b7b12333b81d75b1fe0b53a";
            };
          };
        in
        drv;

    };
in
self
