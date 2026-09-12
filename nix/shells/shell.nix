{
  pkgs,
  commonShellHook,
  preCommitCheck,
  jailedTackle ? null,
}:

let
  platformPackages =
    with pkgs;
    lib.optionals stdenv.hostPlatform.isLinux [
      inotify-tools
      util-linux
    ]
    ++ lib.optionals stdenv.isDarwin (
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

    # Development tools
    pkgs.rustfmt
    pkgs.clippy
    pkgs.tokei
  ]
  ++ platformPackages
  ++ pkgs.lib.optional (jailedTackle != null) jailedTackle;
  shellHook = commonShellHook + muslToolchainEnv;
}
