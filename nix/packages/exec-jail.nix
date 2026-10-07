{
  pkgs,
  lib,
  jailed-agents,
  system,
  name ? "tackle-exec-jail",
  # Tools available to the agent's commands, besides the common utilities.
  extraPkgs ? [ ],
  # Mount /nix read-only and the host daemon socket, so `nix build` and
  # `nix develop` work inside the jail. This weakens isolation; see README.
  enableNix ? true,
  extraJailOptions ? [ ],
  # The program run inside the jail; tests substitute a probe.
  entry ? pkgs.callPackage ./exec-server.nix { },
}:

# Launcher for the jailed exec-server (Tackle.Exec.Server). The Tackle CLI
# runs on the host and starts this once per process (TACKLE_EXEC_LAUNCHER):
#
#   cwd:   the workspace, mounted read-write at the same path
#   $1:    a host log file for the jail's standard error
#   stdio: the exec-server protocol
#
# Only primitives run here; credentials, sessions, and the clipboard stay on
# the host. Bubblewrap unshares every namespace except the network, starts a
# new session, clears the environment, and dies with the CLI.
let
  jail = jailed-agents.lib.${system}.internals.jail;
  ketch = pkgs.callPackage ./ketch.nix { };

  # The utilities jailed-agents gives every agent.
  basePackages = with pkgs; [
    bashInteractive
    curl
    wget
    jq
    git
    which
    ripgrep
    gnugrep
    gawkInteractive
    ps
    findutils
    gzip
    unzip
    gnutar
    diffutils
    gnused
  ];

  cacert = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  nixAccess = with jail.combinators; [
    (readonly "/nix")
    (readonly "/etc/nix/nix.conf")
    (readwrite "/nix/var/nix/daemon-socket")
    (add-pkg-deps [ pkgs.nix ])
    # Do not let Nix fall back to opening the read-only host database locally.
    (set-env "NIX_REMOTE" "daemon")
    (set-env "NIX_CONFIG" "experimental-features = nix-command flakes")
    (set-env "NIX_SSL_CERT_FILE" cacert)
  ];
in
jail name entry (
  with jail.combinators;
  [
    network
    mount-cwd
    (add-runtime ''
      # Keep the jail's diagnostics, and anything jailed code writes to the
      # inherited standard error, away from the host terminal.
      if [[ $# -ge 1 ]]; then
        exec 2>>"$1"
        shift
      fi

      # Never mount the home directory or anything containing it. Compare
      # resolved paths so symlinked homes are caught too.
      workspace=$(pwd -P)
      home=$(realpath -m -- "$HOME")
      if [[ "$workspace" == / || "$home/" == "$workspace/"* ]]; then
        echo "tackle-exec-jail: refusing to mount $workspace as the workspace" >&2
        exit 2
      fi

      # Git runs hooks and honours core.hooksPath, core.fsmonitor, and other
      # settings from .git/config on the host. Mount .git onto itself so it
      # cannot be renamed or replaced, create hooks and config on the host so
      # jailed code cannot, and mount both read-only. This narrows, but does not
      # remove, the risk of running host Git in a jailed workspace: nested
      # repositories and submodules created in the jail are not covered.
      if [[ -d .git && ! -L .git ]]; then
        if [[ -L .git/hooks || -L .git/config || -e .git/commondir ]]; then
          echo "tackle-exec-jail: unexpected .git/hooks, .git/config, or .git/commondir" >&2
          exit 2
        fi
        mkdir -p .git/hooks
        [[ -e .git/config ]] || : > .git/config
        RUNTIME_ARGS+=(--bind "$workspace/.git" "$workspace/.git")
        RUNTIME_ARGS+=(--ro-bind "$workspace/.git/hooks" "$workspace/.git/hooks")
        RUNTIME_ARGS+=(--ro-bind "$workspace/.git/config" "$workspace/.git/config")
      elif [[ -e .git ]]; then
        # A linked worktree or submodule: its .git file names the real Git
        # directory, which stays outside the jail.
        RUNTIME_ARGS+=(--ro-bind "$workspace/.git" "$workspace/.git")
      fi

      # Ketch works without a configuration; expose only this file when present.
      RUNTIME_ARGS+=(--ro-bind-try "$HOME/.config/ketch/config.json" "$HOME/.config/ketch/config.json")
    '')
    (add-pkg-deps (basePackages ++ [ ketch ] ++ extraPkgs))
    # The jail does not mount the host locale archive. C.UTF-8 is built into
    # glibc and keeps Erlang's filename encoding UTF-8.
    (set-env "LANG" "C.UTF-8")
    (set-env "LC_ALL" "C.UTF-8")
    (set-env "SSL_CERT_FILE" cacert)
  ]
  ++ lib.optionals enableNix nixAccess
  ++ extraJailOptions
)
