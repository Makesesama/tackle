{
  pkgs,
  commonShellHook,
  preCommitCheck,
  jailedTackle ? null,
  reviewJail ? null,
}:

let
  platformPackages =
    with pkgs;
    lib.optionals stdenv.hostPlatform.isLinux [
      inotify-tools
      util-linux
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin (
      with darwin.apple_sdk.frameworks;
      [
        CoreServices
        Foundation
      ]
    );

  # Share the NIF toolchain with the package, without pulling the entire
  # packaged CLI (and its private dependency fetch) into every dev shell.
  toolchain = pkgs.callPackage ../packages/native-toolchain.nix { };
  muslCc = toolchain.cc;
  muslRust = toolchain.rust;

  muslToolchainEnv = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
    # Consumed by config/prod.exs for the Linux Burrito targets. Keep the
    # host `cargo`/`rustc` in PATH for everyday work; these name the musl
    # toolchain the release uses explicitly.
    export TACKLE_MUSL_CC=${muslCc}/bin/cc
    export TACKLE_MUSL_CARGO=${muslRust}/bin/cargo
    export TACKLE_MUSL_RUSTC=${muslRust}/bin/rustc
  '';
  # apps/tackle_hub runs reviews only in this jail (config/runtime.exs). An
  # explicitly set TACKLE_HUB_REVIEW_JAIL still wins.
  reviewJailEnv = pkgs.lib.optionalString (reviewJail != null) ''
    export TACKLE_HUB_REVIEW_JAIL=''${TACKLE_HUB_REVIEW_JAIL:-${pkgs.lib.getExe reviewJail}}
  '';
in
pkgs.mkShell {
  buildInputs = preCommitCheck.enabledPackages;
  packages = [
    pkgs.elixir
    pkgs.hex
    pkgs.beamPackages.rebar3
    # Language servers
    pkgs.beamPackages.expert

    # Build tools
    pkgs.cargo
    pkgs.rustc
    pkgs.watchman
    pkgs.xz
    pkgs.zig_0_16

    # apps/tackle_hub's optional local cluster (apps/tackle_hub/scripts/db.sh)
    pkgs.postgresql

    # Development tools
    pkgs.rustfmt
    pkgs.clippy
    pkgs.tokei
    pkgs.emacs
  ]
  ++ platformPackages
  ++ pkgs.lib.optional (jailedTackle != null) jailedTackle;
  shellHook = commonShellHook + muslToolchainEnv + reviewJailEnv;
}
