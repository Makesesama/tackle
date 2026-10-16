# NixOS module: `services.tackle-web`, the pull request review app
# (apps/tackle_web).
#
#   services.tackle-web = {
#     enable = true;
#     url = "https://review.example.com";
#     # SECRET_KEY_BASE=... and TACKLE_WEB_CLOAK_KEY=... (see the app README)
#     environmentFile = "/run/secrets/tackle-web.env";
#   };
#
# It runs the release as a dedicated system user, with a local PostgreSQL
# database reached over the Unix socket with peer authentication (no
# password), and runs migrations before every start. Making the app reachable
# for forge webhooks (TLS, a reverse proxy or tunnel) is the operator's job.
# Forge and provider secrets are entered in the app, not here.
#
# The flake exports it as `nixosModules.tackle-web`; `self` is this flake,
# which provides the default package.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.tackle-web;
  inherit (lib) mkOption types;

  user = "tackle-web";

  # "/var/lib/x/" and "/var/lib/x" name the same directory.
  dir = path: lib.removeSuffix "/" path;

  # The environment config/runtime.exs reads, besides the secrets in
  # `environmentFile`.
  serviceEnvironment = {
    LISTEN_ADDRESS = cfg.listenAddress;
    PORT = toString cfg.port;
    TACKLE_WEB_URL = cfg.url;
    TACKLE_WEB_STATE_DIR = cfg.stateDir;
    TACKLE_WEB_REVIEW_JAIL = lib.getExe cfg.reviewJail;
    HOME = cfg.homeDir;
    LANG = "C.UTF-8";
    # The release's own temporary files; the store copy is read-only.
    RELEASE_TMP = "/run/tackle-web";
    # One node, no Erlang distribution: nothing listens for other nodes,
    # so the fixed cookie (the package ships none) protects nothing.
    RELEASE_DISTRIBUTION = "none";
    RELEASE_COOKIE = "tackle-web-no-distribution";
  }
  // lib.optionalAttrs cfg.database.createLocally {
    TACKLE_WEB_DATABASE_SOCKET_DIR = "/run/postgresql";
    TACKLE_WEB_DATABASE = database;
    TACKLE_WEB_DATABASE_USER = user;
  };

  # `tackle-web-release eval "..."` runs the release's commands as the
  # service user with the service's environment and secrets, beside the
  # running service, for tasks such as
  # `Tackle.Web.Release.configure_github_app()`. It runs them as a transient
  # systemd unit, so systemd reads `environmentFile` exactly as it does for
  # the service. The caller's TACKLE_WEB_GITHUB_* variables are passed on.
  releaseCommand = pkgs.writeShellApplication {
    name = "tackle-web-release";
    runtimeInputs = [
      pkgs.coreutils
      config.systemd.package
    ];
    text = ''
      if [[ "$(id -u)" != 0 ]]; then
        echo "tackle-web-release: run as root; it starts a unit as ${user}" >&2
        exit 1
      fi

      # `--setenv=NAME` takes the value from this environment.
      passed=()
      for name in "''${!TACKLE_WEB_GITHUB_@}"; do
        passed+=("--setenv=$name")
      done

      exec systemd-run --quiet --collect --wait --pipe \
        --service-type=exec \
        --uid=${user} --gid=${user} \
        --property=EnvironmentFile=${lib.escapeShellArg cfg.environmentFile} \
        --property=WorkingDirectory=${lib.escapeShellArg cfg.homeDir} \
        --property=RuntimeDirectory=tackle-web-release \
        ${
          lib.concatStringsSep " " (
            lib.mapAttrsToList (name: value: "--setenv=${lib.escapeShellArg "${name}=${value}"}") (
              serviceEnvironment // { RELEASE_TMP = "/run/tackle-web-release"; }
            )
          )
        } \
        "''${passed[@]}" \
        ${cfg.package}/bin/tackle_web "$@"
    '';
  };

  # Peer authentication maps the system user to the database role of the same
  # name, and `ensureDBOwnership` needs a database of that name too.
  database = user;
in
{
  options.services.tackle-web = {
    enable = lib.mkEnableOption "the Tackle pull request review app";

    package = mkOption {
      type = types.package;
      default =
        self.packages.${pkgs.stdenv.hostPlatform.system}.tackle-web
          or (throw "services.tackle-web: the Tackle flake has no package for ${pkgs.stdenv.hostPlatform.system}");
      defaultText = lib.literalExpression "tackle.packages.\${system}.tackle-web";
      description = "The tackle_web release to run.";
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
      defaultText = lib.literalExpression ''"http://localhost:''${toString config.services.tackle-web.port}"'';
      example = "https://review.example.com";
      description = ''
        The public URL, as the forge and browsers reach the app; behind a
        reverse proxy, the proxy's URL.
      '';
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/tackle-web";
      description = ''
        Directory for the app's state, such as repository clones and review
        worktrees. Exported as `TACKLE_WEB_STATE_DIR`.
      '';
    };

    homeDir = mkOption {
      type = types.str;
      default = "/var/lib/tackle-web-home";
      description = ''
        The service user's home directory. It must not contain
        {option}`stateDir`: the review jail covers the home directory with a
        private one, which would hide the checkouts below it.
      '';
    };

    environmentFile = mkOption {
      type = types.str;
      example = "/run/secrets/tackle-web.env";
      description = ''
        Environment file with the secrets, outside the Nix store:
        `SECRET_KEY_BASE` and `TACKLE_WEB_CLOAK_KEY`, optionally
        `TACKLE_WEB_CLOAK_RETIRED_KEYS`, and `DATABASE_URL` when
        {option}`database.createLocally` is off. See
        apps/tackle_web/README.md.
      '';
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
        message = "services.tackle-web: stateDir must not be homeDir or lie inside it";
      }
      {
        assertion =
          lib.hasPrefix "/" cfg.environmentFile && !(lib.hasPrefix "/nix/store/" cfg.environmentFile);
        message = "services.tackle-web: environmentFile must be an absolute path outside the Nix store";
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

    systemd.tmpfiles.settings.tackle-web.${cfg.stateDir}.d = {
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

    systemd.services.tackle-web = {
      description = "Tackle pull request review app";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ] ++ lib.optional cfg.database.createLocally "postgresql.target";
      requires = lib.optional cfg.database.createLocally "postgresql.target";

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
        ExecStartPre = "${cfg.package}/bin/tackle_web eval \"Tackle.Web.Release.migrate()\"";
        ExecStart = "${cfg.package}/bin/tackle_web start";
        Restart = "on-failure";
        RestartSec = 5;
        RuntimeDirectory = "tackle-web";
        UMask = "0077";

        # MemoryDenyWriteExecute is deliberately absent: the BEAM JIT writes executable code.
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
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ProtectProc = "invisible";
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        SystemCallArchitectures = "native";
      };
    };
  };
}
