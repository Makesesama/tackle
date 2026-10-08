{
  pkgs,
  lib,
  jailed-agents,
  system,
}:

# Development launcher: runs `mix tackle` from the checkout on the host with
# commands and workspace file access in a jail that mounts the repository
# root. Host facilities such as the clipboard work directly.
#
# The checkout, including _build, deps, and .nix-mix, is writable from the
# jail, so code the agent changes runs unjailed the next time this launcher
# starts the CLI. Use the `tackle-cli-jail` package when that matters.
let
  combinators = jailed-agents.lib.${system}.internals.jail.combinators;

  execJail = pkgs.callPackage ./exec-jail.nix {
    inherit jailed-agents system;
    name = "tackle-dev-exec-jail";
    # Keep the host Nix daemon outside the development jail; the toolchain
    # is exposed explicitly instead.
    enableNix = false;
    extraPkgs = [
      (pkgs.callPackage ./jail-python.nix { })
      pkgs.elixir
      pkgs.hex
      pkgs.beamPackages.rebar3
      pkgs.stdenv.cc
      pkgs.util-linux
      pkgs.gnumake
      pkgs.pkg-config
      pkgs.rustc
      pkgs.cargo
      pkgs.rustfmt
      pkgs.clippy
      pkgs.watchman
      pkgs.tokei
      pkgs.beamPackages.expert
      pkgs.chromium
    ]
    ++ lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.inotify-tools;
    extraJailOptions = [
      # Same Mix and Hex state as the development shell, kept in the checkout.
      (combinators.add-runtime ''
        RUNTIME_ARGS+=(--setenv MIX_HOME "$PWD/.nix-mix" --setenv HEX_HOME "$PWD/.nix-hex")
      '')
    ];
  };
in
pkgs.writeShellApplication {
  name = "jailed-tackle";
  runtimeInputs = [ pkgs.elixir ];
  text = ''
    if [[ ! -f packages/tackle/mix.exs || ! -f apps/tackle_cli/mix.exs ]]; then
      echo "jailed-tackle must be run from the Tackle repository root" >&2
      exit 2
    fi

    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
    export TACKLE_EXEC_LAUNCHER=${lib.getExe execJail}
    # The jail mounts the repository root; the CLI itself runs in the app.
    TACKLE_EXEC_WORKSPACE=$(pwd -P)
    export TACKLE_EXEC_WORKSPACE

    cd apps/tackle_cli
    exec mix tackle "$@"
  '';
}
