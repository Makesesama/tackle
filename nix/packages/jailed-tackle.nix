{
  pkgs,
  jailed-agents,
  system,
}:

let
  jailedAgents = jailed-agents.lib.${system};
  jail = jailedAgents.internals.jail;
  ketch = pkgs.callPackage ./ketch.nix { };

  tackleDevelopmentWrapper = pkgs.writeShellApplication {
    name = "tackle-development";
    runtimeInputs = [ pkgs.elixir ];
    text = ''
      if [[ ! -f mix.exs || ! -d frontends/tackle_cli ]]; then
        echo "jailed-tackle must be run from the Tackle repository root" >&2
        exit 2
      fi

      # The jail does not mount the host locale archive. C.UTF-8 is provided by
      # glibc itself and keeps Elixir's native filename encoding set to UTF-8.
      export LANG=C.UTF-8
      export LC_ALL=C.UTF-8

      # The jail is a development context, so enable Tackle development-only
      # behaviour (e.g. the elixir_eval tool) unconditionally.
      export TACKLE_DEV=1

      exec mix tackle "$@"
    '';
  };
in
jailedAgents.makeJailedAgent {
  name = "jailed-tackle";
  pkg = tackleDevelopmentWrapper;
  configPaths = [
    "~/.tackle"
    "~/.config/ketch/config.json"
  ];

  # Keep the host Nix daemon outside the jail. The coding toolchain is exposed
  # explicitly instead, while jailed-agents supplies Bash, Git, ripgrep, curl,
  # and the other common command-line utilities.
  enableNix = false;
  extraPkgs = [
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
    ketch
    pkgs.chromium
  ]
  ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.inotify-tools;

  # These are non-secret development settings. Provider credentials remain in
  # the deliberately mounted ~/.tackle directory instead of the environment.
  fwdEnv = [
    "TERM"
    "COLORTERM"
    "NO_COLOR"
    "LANG"
    "LC_ALL"
    "MIX_ENV"
    "MIX_HOME"
    "HEX_HOME"
    "ERL_AFLAGS"
    "TACKLE_DEV"
    "TACKLE_MODEL"
    "TACKLE_THINKING"
  ];

  # A fresh installation might not have TACKLE_HOME yet. This setup runs on
  # the host before Bubblewrap starts and creates only Tackle's state directory.
  baseJailOptions = jailedAgents.commonJailOptions ++ [
    (jail.combinators.add-runtime ''
      mkdir -p "$HOME/.tackle"
      chmod 700 "$HOME/.tackle"
    '')
  ];
}
