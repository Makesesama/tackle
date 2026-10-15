# Home Manager module: `programs.tackle`.
#
#   programs.tackle = {
#     enable = true;
#     settings = {
#       model = "openai-codex/gpt-5.5";
#       thinking = "medium";
#     };
#     git = {
#       name = "Ada Lovelace";
#       email = "ada@example.com";
#     };
#   };
#
# The flake exports it as `homeModules.tackle` (also `homeManagerModules`);
# `self` is this flake, which provides the default package.
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.tackle;
  inherit (pkgs.stdenv.hostPlatform) isLinux system;

  jsonFormat = pkgs.formats.json { };
  flakePackages =
    self.packages.${system}
      or (throw "programs.tackle: the Tackle flake has no packages for ${system}");

  tackleHome = "${config.home.homeDirectory}/.tackle";
  configFile = jsonFormat.generate "tackle-config.json" cfg.settings;

  gitUser = lib.filterAttrs (_name: value: value != null) {
    inherit (cfg.git) name email;
  };
  gitConfig = lib.optionalAttrs (gitUser != { }) { user = gitUser; };
in
{
  _file = toString ./home-manager.nix;
  # One key for every export, so importing it twice is not a conflict.
  key = "tackle#homeModules.tackle";

  options.programs.tackle = {
    enable = lib.mkEnableOption "Tackle, the developer agent CLI";

    package = lib.mkOption {
      type = lib.types.package;
      default = if isLinux then flakePackages.tackle-cli-jail else flakePackages.tackle-cli;
      defaultText = lib.literalExpression ''
        if pkgs.stdenv.hostPlatform.isLinux
        then tackle.packages.''${pkgs.stdenv.hostPlatform.system}.tackle-cli-jail
        else tackle.packages.''${pkgs.stdenv.hostPlatform.system}.tackle-cli
      '';
      description = ''
        The Tackle package. When {option}`programs.tackle.git` sets anything,
        it must accept `gitConfig` through `override`, as `tackle-cli-jail`
        does. {option}`programs.tackle.finalPackage` is what gets installed.
      '';
    };

    finalPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "The installed package: {option}`programs.tackle.package` with the Git configuration applied.";
    };

    settings = lib.mkOption {
      inherit (jsonFormat) type;
      default = { };
      example = lib.literalExpression ''
        {
          model = "openai-codex/gpt-5.5";
          thinking = "medium";
          show_subagent_sidebar = false;
        }
      '';
      description = ''
        Contents of {file}`~/.tackle/config.json`; see the harness README for
        the fields. Tackle rejects unknown fields when it starts.

        When non-empty, activation replaces the file with a regular copy
        (mode 0600) rather than a link into the store, because the CLI saves
        preferences there with an atomic rename. Changes the CLI makes (such
        as the subagent sidebar toggle) last until the next activation. When
        empty, the file is left alone. A custom `TACKLE_HOME` is not followed.
      '';
    };

    git = {
      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = lib.literalExpression "config.programs.git.settings.user.name";
        description = ''
          Name Git uses for commits the agent makes in the jail. The jail does
          not see the host's Git configuration, so it otherwise has none.
          Repository configuration (`user.name` in {file}`.git/config`) still
          takes precedence.
        '';
      };

      email = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = lib.literalExpression "config.programs.git.settings.user.email";
        description = ''
          Email Git uses for commits the agent makes in the jail; see
          {option}`programs.tackle.git.name`.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = gitConfig == { } || isLinux;
        message = ''
          programs.tackle.git configures the jail, which is Linux-only. Elsewhere
          Tackle runs commands on the host, with the host's Git configuration.
        '';
      }
      {
        # makeOverridable copies the package function's arguments to override.
        assertion =
          gitConfig == { } || (cfg.package ? override && lib.functionArgs cfg.package.override ? gitConfig);
        message = ''
          programs.tackle.git needs a package that accepts override { gitConfig = ...; },
          such as tackle-cli-jail.
        '';
      }
    ];

    programs.tackle.finalPackage =
      if gitConfig == { } then cfg.package else cfg.package.override { inherit gitConfig; };

    home.packages = [ cfg.finalPackage ];

    home.activation.tackleConfig = lib.mkIf (cfg.settings != { }) (
      lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        tackleHome=${lib.escapeShellArg tackleHome}
        if [[ ! -d "$tackleHome" ]]; then
          run mkdir -p -m 700 "$tackleHome"
        fi
        # Copy next to the target, then rename over it, so the CLI never reads
        # a partial file and a link left by an earlier setup is replaced.
        run install -m 600 ${configFile} "$tackleHome/.config.json.hm-new"
        run mv -fT "$tackleHome/.config.json.hm-new" "$tackleHome/config.json"
      ''
    );
  };
}
