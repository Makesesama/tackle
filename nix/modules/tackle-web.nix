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

      environment = {
        LISTEN_ADDRESS = cfg.listenAddress;
        PORT = toString cfg.port;
        TACKLE_WEB_URL = cfg.url;
        TACKLE_WEB_STATE_DIR = cfg.stateDir;
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

        # Hardening. Two settings are deliberately absent: RestrictNamespaces
        # (the review jail, Bubblewrap, needs unprivileged user namespaces),
        # and MemoryDenyWriteExecute (the BEAM's JIT writes executable code).
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
