# NixOS module: `services.tackle-hub`, the pull request review app
# (apps/tackle_hub).
#
#   services.tackle-hub = {
#     enable = true;
#     url = "https://review.example.com";
#     # SECRET_KEY_BASE=... and TACKLE_HUB_CLOAK_KEY=... (see the app README)
#     environmentFile = "/run/secrets/tackle-hub.env";
#   };
#
# It runs the release as a dedicated system user, with a local PostgreSQL
# database reached over the Unix socket with peer authentication (no
# password), and runs migrations before every start. Making the app reachable
# for forge webhooks (TLS, a reverse proxy or tunnel) is the operator's job.
# Forge and provider secrets are entered in the app, not here.
#
# The flake exports it as `nixosModules.tackle-hub`; `self` is this flake,
# which provides the default package.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.tackle-hub;
  inherit (lib) mkOption types;

  user = "tackle-hub";

  # "/var/lib/x/" and "/var/lib/x" name the same directory.
  dir = path: lib.removeSuffix "/" path;

  # The environment config/runtime.exs reads, besides the secrets in
  # `environmentFile`.
  serviceEnvironment = {
    LISTEN_ADDRESS = cfg.listenAddress;
    PORT = toString cfg.port;
    TACKLE_HUB_URL = cfg.url;
    TACKLE_HUB_STATE_DIR = cfg.stateDir;
    TACKLE_HUB_REVIEW_JAIL = lib.getExe cfg.reviewJail;
    HOME = cfg.homeDir;
    LANG = "C.UTF-8";
    # The release's own temporary files; the store copy is read-only.
    RELEASE_TMP = "/run/tackle-hub";
    # One node, no Erlang distribution: nothing listens for other nodes,
    # so the fixed cookie (the package ships none) protects nothing.
    RELEASE_DISTRIBUTION = "none";
    RELEASE_COOKIE = "tackle-hub-no-distribution";
  }
  // lib.optionalAttrs cfg.database.createLocally {
    TACKLE_HUB_DATABASE_SOCKET_DIR = "/run/postgresql";
    TACKLE_HUB_DATABASE = database;
    TACKLE_HUB_DATABASE_USER = user;
  };

  # `tackle-hub-release eval "..."` runs the release's commands as the
  # service user with the service's environment and secrets, beside the
  # running service, for tasks such as
  # `Tackle.Hub.Release.configure_github_app()`. It runs them as a transient
  # systemd unit, so systemd reads `environmentFile` exactly as it does for
  # the service. The caller's TACKLE_HUB_GITHUB_* variables are passed on.
  releaseCommand = pkgs.writeShellApplication {
    name = "tackle-hub-release";
    runtimeInputs = [
      pkgs.coreutils
      config.systemd.package
    ];
    text = ''
      if [[ "$(id -u)" != 0 ]]; then
        echo "tackle-hub-release: run as root; it starts a unit as ${user}" >&2
        exit 1
      fi

      # `--setenv=NAME` takes the value from this environment.
      passed=()
      for name in "''${!TACKLE_HUB_GITHUB_@}"; do
        passed+=("--setenv=$name")
      done

      exec systemd-run --quiet --collect --wait --pipe \
        --service-type=exec \
        --uid=${user} --gid=${user} \
        --property=EnvironmentFile=${lib.escapeShellArg cfg.environmentFile} \
        --property=WorkingDirectory=${lib.escapeShellArg cfg.homeDir} \
        --property=RuntimeDirectory=tackle-hub-release \
        ${
          lib.concatStringsSep " " (
            lib.mapAttrsToList (name: value: "--setenv=${lib.escapeShellArg "${name}=${value}"}") (
              serviceEnvironment // { RELEASE_TMP = "/run/tackle-hub-release"; }
            )
          )
        } \
        "''${passed[@]}" \
        ${cfg.package}/bin/tackle_hub "$@"
    '';
  };

  # Peer authentication maps the system user to the database role of the same
  # name, and `ensureDBOwnership` needs a database of that name too.
  database = user;

  # Newer NixOS reaches postgresql.target once the databases and roles exist;
  # older releases have only the service, which does that in its postStart.
  postgresqlUnit =
    if config.systemd.targets ? postgresql then "postgresql.target" else "postgresql.service";
in
{
  options.services.tackle-hub = {
    enable = lib.mkEnableOption "the Tackle pull request review app";

    package = mkOption {
      type = types.package;
      default =
        self.packages.${pkgs.stdenv.hostPlatform.system}.tackle-hub
          or (throw "services.tackle-hub: the Tackle flake has no package for ${pkgs.stdenv.hostPlatform.system}");
      defaultText = lib.literalExpression "tackle.packages.\${system}.tackle-hub";
      description = "The tackle_hub release to run.";
    };

    reviewJail = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.tackle-review-jail;
      defaultText = lib.literalExpression "tackle.packages.\${system}.tackle-review-jail";
      description = "Read-only, network-isolated exec-server launcher for each review run.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "IP address the HTTP server listens on.";
    };

    port = mkOption {
      type = types.port;
      default = 4000;
      description = "Port the HTTP server listens on.";
    };

    url = mkOption {
      type = types.str;
      default = "http://localhost:${toString cfg.port}";
      defaultText = lib.literalExpression ''"http://localhost:''${toString config.services.tackle-hub.port}"'';
      example = "https://review.example.com";
      description = ''
        The public URL, as the forge and browsers reach the app; behind a
        reverse proxy, the proxy's URL.
      '';
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/tackle-hub";
      description = ''
        Directory for the app's state, such as repository clones and review
        worktrees. Exported as `TACKLE_HUB_STATE_DIR`.
      '';
    };

    homeDir = mkOption {
      type = types.str;
      default = "/var/lib/tackle-hub-home";
      description = ''
        The service user's home directory. It must not contain
        {option}`stateDir`: the review jail covers the home directory with a
        private one, which would hide the checkouts below it.
      '';
    };

    environmentFile = mkOption {
      type = types.str;
      example = "/run/secrets/tackle-hub.env";
      description = ''
        Environment file with the secrets, outside the Nix store:
        `SECRET_KEY_BASE` and `TACKLE_HUB_CLOAK_KEY`, optionally
        `TACKLE_HUB_CLOAK_RETIRED_KEYS`, and `DATABASE_URL` when
        {option}`database.createLocally` is off. See
        apps/tackle_hub/README.md.
      '';
    };

    limits = {
      memory = mkOption {
        type = types.nullOr types.str;
        default = "4G";
        example = "8G";
        description = ''
          Memory for the whole service (systemd's `MemoryMax`): the app,
          its Git processes, and every review jail, including what jailed
          commands write to their private tmpfs mounts. Raise it for large
          repositories, whose clones need more. Jailed processes are killed
          first when it runs out, and the service keeps running. `null`
          leaves memory unbounded.
        '';
      };

      tasks = mkOption {
        type = types.nullOr types.ints.positive;
        default = 2048;
        description = ''
          Processes and threads of the whole service (systemd's
          `TasksMax`), so a fork bomb in a review jail cannot exhaust the
          host's. It counts the app's own threads and a jail's, which grow
          with the number of CPUs. `null` keeps systemd's default.
        '';
      };

      cpuQuota = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "200%";
        description = ''
          CPU time of the whole service (systemd's `CPUQuota`), as a
          percentage of one CPU. `null` leaves it unbounded.
        '';
      };
    };

    database.createLocally = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run PostgreSQL on this host with a `${database}` database owned by
        the `${user}` role, reached over the Unix socket with peer
        authentication. Otherwise set `DATABASE_URL` in
        {option}`environmentFile`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(lib.hasPrefix "${dir cfg.homeDir}/" "${dir cfg.stateDir}/");
        message = "services.tackle-hub: stateDir must not be homeDir or lie inside it";
      }
      {
        assertion =
          lib.hasPrefix "/" cfg.environmentFile && !(lib.hasPrefix "/nix/store/" cfg.environmentFile);
        message = "services.tackle-hub: environmentFile must be an absolute path outside the Nix store";
      }
      {
        # Tackle.Hub.Repo.min_pg_version. NixOS picks PostgreSQL's version
        # by system.stateVersion: hosts from before 24.11 get 15 or older.
        assertion =
          !cfg.database.createLocally || lib.versionAtLeast config.services.postgresql.package.version "16";
        message = ''
          services.tackle-hub needs PostgreSQL 16 or later, but
          services.postgresql.package is ${config.services.postgresql.package.version}.
          Set services.postgresql.package to pkgs.postgresql_16 or later
          (upgrading an existing cluster's major version needs its data
          migrated, see the NixOS manual), or set
          services.tackle-hub.database.createLocally = false and point
          DATABASE_URL at another server.
        '';
      }
    ];

    environment.systemPackages = [ releaseCommand ];

    users.users.${user} = {
      isSystemUser = true;
      group = user;
      home = cfg.homeDir;
      createHome = true;
    };
    users.groups.${user} = { };

    systemd.tmpfiles.settings.tackle-hub.${cfg.stateDir}.d = {
      inherit user;
      group = user;
      mode = "0750";
    };

    services.postgresql = lib.mkIf cfg.database.createLocally {
      enable = true;
      ensureDatabases = [ database ];
      ensureUsers = [
        {
          name = user;
          ensureDBOwnership = true;
        }
      ];
    };

    systemd.services.tackle-hub = {
      description = "Tackle pull request review app";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ] ++ lib.optional cfg.database.createLocally postgresqlUnit;
      requires = lib.optional cfg.database.createLocally postgresqlUnit;

      # Host checkout uses a scrubbed environment and resolves these explicitly.
      path = [
        pkgs.bash
        pkgs.git
        pkgs.util-linux
        pkgs.coreutils
      ];
      environment = serviceEnvironment;

      serviceConfig = {
        Type = "exec";
        User = user;
        Group = user;
        EnvironmentFile = cfg.environmentFile;
        ExecStartPre = "${cfg.package}/bin/tackle_hub eval \"Tackle.Hub.Release.migrate()\"";
        ExecStart = "${cfg.package}/bin/tackle_hub start";
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = "tackle-hub";
        UMask = "0077";

        # Bounds against runaway or hostile review commands (see `limits`).
        # The review jail raises its processes' OOM score, so the kernel
        # kills them first when MemoryMax is reached; the service must then
        # keep running instead of being stopped by systemd's default policy.
        MemoryMax = lib.mkIf (cfg.limits.memory != null) cfg.limits.memory;
        TasksMax = lib.mkIf (cfg.limits.tasks != null) cfg.limits.tasks;
        CPUQuota = lib.mkIf (cfg.limits.cpuQuota != null) cfg.limits.cpuQuota;
        OOMPolicy = "continue";

        # Sandboxing. Every review runs Bubblewrap (the review jail) inside
        # this sandbox, which rules out a few settings; the VM test starts
        # the jail under these exact settings (nix/tests/tackle-hub.nix).
        #
        #  * MemoryDenyWriteExecute: the BEAM JIT writes executable code.
        #  * ProtectKernelTunables, ProtectKernelLogs: they mount over parts
        #    of /proc, and the kernel then refuses the jail a /proc of its
        #    own. The service runs without root or capabilities, so the
        #    kernel already refuses it writes to /proc/sys and reads of
        #    /proc/kmsg; SystemCallFilter keeps ProtectKernelLogs' syslog(2)
        #    ban.
        #  * AF_NETLINK must be allowed: Bubblewrap brings up the jail's
        #    loopback interface over netlink. Without CAP_NET_ADMIN the app
        #    can only read network state with it. The jail's own seccomp
        #    filter takes netlink away again from the code that runs in it
        #    (`restrictSockets`, nix/packages/jail-socket-filter.c).
        #
        # Explicitly allow the namespace types Bubblewrap creates, including user.
        RestrictNamespaces = [
          "user"
          "mnt"
          "pid"
          "net"
          "ipc"
          "uts"
          "cgroup"
        ];
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          cfg.stateDir
          cfg.homeDir
        ];
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectProc = "invisible";
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
        ];
        SystemCallFilter = [ "~syslog" ];
        SystemCallErrorNumber = "EPERM";
        SystemCallArchitectures = "native";
      };
    };
  };
}
