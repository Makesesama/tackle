{
  pkgs,
  jailed-agents,
  system,
}:

let
  jailedAgents = jailed-agents.lib.${system};
  jail = jailedAgents.internals.jail;

  tackleDevelopmentWrapper = pkgs.writeShellApplication {
    name = "tackle-development";
    runtimeInputs = [ pkgs.elixir ];
    text = ''
      if [[ ! -f mix.exs || ! -d frontends/tackle_cli ]]; then
        echo "jailed-tackle must be run from the Tackle repository root" >&2
        exit 2
      fi

      exec mix tackle "$@"
    '';
  };
in
jailedAgents.makeJailedAgent {
  name = "jailed-tackle";
  pkg = tackleDevelopmentWrapper;
  configPaths = [ "~/.tackle" ];

  # Keep the host Nix daemon outside the jail. The coding toolchain is exposed
  # explicitly instead, while jailed-agents supplies Bash, Git, ripgrep, curl,
  # and the other common command-line utilities.
  enableNix = false;
  extraPkgs = [
    pkgs.elixir
    pkgs.hex
    pkgs.beamPackages.rebar3
    pkgs.stdenv.cc
    pkgs.gnumake
    pkgs.pkg-config
    pkgs.rustc
    pkgs.cargo
    pkgs.watchman
    pkgs.tokei
    pkgs.beamPackages.expert
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
