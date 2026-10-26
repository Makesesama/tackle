{
  pkgs,
  lib,
  jailed-agents,
  system,
  name ? "tackle-exec-jail",
  # Tools available to the agent's commands, besides the common utilities.
  extraPkgs ? [ ],
  # Review runs must neither reach the network nor mutate shared Git data.
  network ? true,
  readOnlyWorkspace ? false,
  # Mount /nix read-only and the host daemon socket, so `nix build` and
  # `nix develop` work inside the jail. This weakens isolation; see README.
  enableNix ? true,
  # Reproduce the project's cached nix-direnv devshell inside the jail, so the
  # agent finds the project toolchain on PATH. Requires enableNix: the cached
  # devshell only names store paths. See jail-direnv.nix.
  inheritDirenv ? false,
  # Git configuration for commands in the jail, as `lib.generators.toGitINI`
  # attributes, such as the commit identity:
  #   { user = { name = "Ada Lovelace"; email = "ada@example.com"; }; }
  # The jail's home is private and the host's Git configuration is not
  # mounted, so without this Git in the jail has no identity and cannot commit.
  # It is a read-only file in the store, readable by every local user.
  gitConfig ? { },
  extraJailOptions ? [ ],
  # Resource limits on everything in the jail, against runaway or hostile
  # commands; an unset attribute keeps the host's default:
  #   tmpfsSize:   bytes for each private tmpfs (/tmp, the home, /dev/shm),
  #                which otherwise may grow to half the host's memory
  #   fileSize:    bytes for any one file written (RLIMIT_FSIZE)
  #   oomScoreAdj: -1000..1000; 1000 makes the jail's processes the
  #                kernel's first choice when memory runs out, before the
  #                host process that started it
  # Memory as a whole and the number of tasks are bounded by the caller's
  # cgroup (the service's MemoryMax and TasksMax), not here.
  limits ? { },
  # Let jailed code create Unix, IPv4, and IPv6 sockets only; other address
  # families, such as netlink, fail with EAFNOSUPPORT (jail-socket-filter.c).
  # Bubblewrap applies the filter after it has set up the jail, so it can
  # still use netlink to bring up the private loopback interface. A systemd
  # service that runs the launcher must allow AF_NETLINK for that reason.
  restrictSockets ? false,
  # The program run inside the jail; tests substitute a probe.
  entry ? pkgs.callPackage ./exec-server.nix { },
}:

# Launcher for the jailed exec-server (Tackle.Exec.Server). The Tackle CLI
# runs on the host and starts this once per process (TACKLE_EXEC_LAUNCHER):
#
#   cwd:   the workspace, mounted at the same path (read-write by default)
#   $1:    a host log file for the jail's standard error
#   stdio: the exec-server protocol
#
# Only primitives run here; credentials, sessions, and the clipboard stay on
# the host. Bubblewrap unshares every namespace (except network by default), starts a
# new session, clears the environment, and dies with the CLI.
let
  jail = jailed-agents.lib.${system}.internals.jail;
  ketch = pkgs.callPackage ./ketch.nix { };
  direnv = import ./jail-direnv.nix { inherit pkgs jail; };

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

  # Git's global configuration in the jail. Repository configuration still
  # takes precedence, as on the host; jailed code cannot change the file.
  gitConfigPath = "/etc/tackle/gitconfig";
  gitAccess = with jail.combinators; [
    (write-text gitConfigPath (lib.generators.toGitINI gitConfig))
    (set-env "GIT_CONFIG_GLOBAL" gitConfigPath)
  ];

  # First among the runtime arguments: later mounts below /tmp or the home,
  # such as a workspace, must stay on top of these.
  limitsRuntime = ''
    ${lib.optionalString (limits ? oomScoreAdj) ''
      echo ${toString limits.oomScoreAdj} > /proc/self/oom_score_adj
    ''}
    ${lib.optionalString (limits ? fileSize) ''
      # Bash counts in 1024-byte blocks; soft and hard, so the jail cannot raise it.
      ulimit -f ${toString (limits.fileSize / 1024)}
    ''}
    ${lib.optionalString (limits ? tmpfsSize) ''
      # Remounts the base tmpfs mounts, which have no size, with one.
      for dir in /tmp "$HOME" /dev/shm; do
        RUNTIME_ARGS+=(--size ${toString limits.tmpfsSize} --tmpfs "$dir")
      done
    ''}
  '';
  unknownLimits = lib.subtractLists [
    "tmpfsSize"
    "fileSize"
    "oomScoreAdj"
  ] (lib.attrNames limits);
in
assert lib.assertMsg (unknownLimits == [ ]) "exec-jail: unknown limits: ${toString unknownLimits}";
jail name entry (
  with jail.combinators;
  lib.optional (limits != { }) (add-runtime limitsRuntime)
  ++ [
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

      # Keep host-executed Git settings out of the jail's reach, and mount a
      # linked worktree's Git directories so Git works in it. See jail-git.sh.
      ${builtins.readFile ./jail-git.sh}
      RUNTIME_ARGS+=(${if readOnlyWorkspace then "--ro-bind" else "--bind"} "$workspace" "$workspace")
      tackle_jail_git_mounts "$workspace" "$home" ${if readOnlyWorkspace then "readonly" else "readwrite"}

      # Ketch works without a configuration; expose only this file when present.
      ${lib.optionalString (!readOnlyWorkspace) ''
        RUNTIME_ARGS+=(--ro-bind-try "$HOME/.config/ketch/config.json" "$HOME/.config/ketch/config.json")
      ''}
    '')
    (add-pkg-deps (basePackages ++ [ ketch ] ++ extraPkgs))
    # The jail does not mount the host locale archive. C.UTF-8 is built into
    # glibc and keeps Erlang's filename encoding UTF-8.
    (set-env "LANG" "C.UTF-8")
    (set-env "LC_ALL" "C.UTF-8")
    (set-env "SSL_CERT_FILE" cacert)
    # Lets a devshell's shellHook, which jail-direnv.nix sources inside the
    # jail, skip work that cannot succeed here, such as installing Git hooks.
    (set-env "TACKLE_JAIL" "1")
  ]
  ++ lib.optional network jail.combinators.network
  ++ lib.optional readOnlyWorkspace (set-env "GIT_OPTIONAL_LOCKS" "0")
  ++ lib.optional restrictSockets (
    jail.combinators.add-seccomp (pkgs.callPackage ./jail-socket-filter.nix { })
  )
  ++ lib.optionals enableNix nixAccess
  ++ lib.optionals (gitConfig != { }) gitAccess
  ++ lib.optionals inheritDirenv (
    assert lib.assertMsg enableNix
      "exec-jail: inheritDirenv requires enableNix, because a cached devshell only names store paths";
    direnv.combinators
  )
  ++ extraJailOptions
)
