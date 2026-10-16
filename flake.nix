{
  description = "An Elixir development shell.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    pre-commit-hooks.url = "github:cachix/git-hooks.nix";

    jailed-agents = {
      url = "github:andersonjoseph/jailed-agents";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      pre-commit-hooks,
      jailed-agents,
      ...
    }@inputs:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      overlays = [
        (
          final: prev:
          let
            beamPkgs = prev.beam29Packages.overrideScope (_final: prevBeam: { elixir = prevBeam.elixir_1_20; });
          in
          {
            beamPackages = beamPkgs;
            elixir = beamPkgs.elixir;
            hex = beamPkgs.hex;

          }
        )
      ];

      forAllSystems =
        function:
        nixpkgs.lib.genAttrs supportedSystems (
          system:
          function rec {
            inherit system;
            pkgs = import nixpkgs { inherit overlays system; };
          }
        );

      mkJailedTackle =
        {
          pkgs,
          system,
        }:
        pkgs.callPackage ./nix/packages/jailed-tackle.nix {
          inherit jailed-agents system;
        };

      treefmtEval = forAllSystems (
        {
          pkgs,
          system,
        }:
        treefmt-nix.lib.evalModule pkgs ./nix/treefmt.nix
      );
    in
    {
      # Home Manager module: `programs.tackle`. See nix/modules/home-manager.nix.
      homeModules = {
        tackle = import ./nix/modules/home-manager.nix self;
        default = self.homeModules.tackle;
      };
      homeManagerModules = self.homeModules;

      # NixOS module: `services.tackle-web`. See nix/modules/tackle-web.nix.
      nixosModules.tackle-web = import ./nix/modules/tackle-web.nix self;

      packages = forAllSystems (
        {
          pkgs,
          system,
        }:
        let
          # Burrito keys its extracted release by application version, so the
          # CLI carries one of its own per build. These are the only Git identity
          # data Nix keeps for the flake; a `path:` input has none, and the
          # package then falls back to the content of the sources.
          dirty = (self.dirtyRev or null) != null;
          rev = if dirty then (self.dirtyShortRev or null) else (self.shortRev or null);
          lastModified = if (self.lastModified or 0) == null then 0 else self.lastModified;
          package = pkgs.callPackage ./nix/packages {
            inherit rev lastModified;
            # No exact version: stamp this build from the checkout.
            releaseVersion = null;
          };
        in
        {
          default = package;
          tackle-cli = package;
          tackle-web = pkgs.callPackage ./nix/packages/tackle-web.nix { };
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          tackle-review-jail = pkgs.callPackage ./nix/packages/review-jail.nix {
            inherit jailed-agents system;
          };
          jailed-tackle = mkJailedTackle { inherit pkgs system; };
          tackle-cli-jail = pkgs.callPackage ./nix/packages/jailed-tackle-cli.nix {
            inherit jailed-agents system;
            tackle-cli = package;
          };
        }
      );
      checks = forAllSystems (
        {
          pkgs,
          system,
        }:
        pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          tackle-web-vm = pkgs.testers.runNixOSTest (import ./nix/tests/tackle-web.nix self);
        }
        // {
          pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              credo = {
                enable = true;
                package = pkgs.elixir;
                entry = "${pkgs.bash}/bin/bash -c 'cd packages/tackle && mix credo --strict && cd ../tackle_review && mix credo --strict && cd ../tackle_tools && mix credo --strict && cd ../../apps/tackle_web && mix format --check-formatted && exec mix credo --strict'";
                pass_filenames = false;
              };
              # dialyzer.enable = true;
              # dialyzer.package = pkgs.elixir;
              treefmt = {
                enable = true;
                package = treefmtEval.${system}.config.build.wrapper;
              };
            };
          };
        }
      );
      devShells = forAllSystems (
        {
          pkgs,
          system,
        }:
        let
          preCommitCheck = self.checks.${system}.pre-commit-check;
          jailedTackle =
            if pkgs.stdenv.hostPlatform.isLinux then mkJailedTackle { inherit pkgs system; } else null;

          projectShellHook = ''
            # Keep Mix and Hex state in the checkout so commands do not depend
            # on or modify the invoking user's home directory.
            mkdir -p .nix-mix .nix-hex
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex
            export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH

            export LANG=C.UTF-8

            # Build forcola from source because its precompiled binary expects
            # an FHS loader that is not present on NixOS.
            export FORCOLA_BUILD=1
          '';

          ciShellHook = ''
            ${projectShellHook}
            export MIX_ENV=test

            # Mix's downloaded rebar3 uses /usr/bin/env, which NixOS does not
            # provide. Force Mix to use the rebar3 from this shell instead.
            export MIX_REBAR3=${pkgs.beamPackages.rebar3}/bin/rebar3
          '';

          commonShellHook = ''
            ${preCommitCheck.shellHook}
            ${projectShellHook}

            export ERL_AFLAGS="-kernel shell_history enabled"
          '';
        in
        {
          # Development shell with all tools
          default = pkgs.callPackage ./nix/shells/shell.nix {
            inherit preCommitCheck commonShellHook jailedTackle;
          };

          # Lean, non-interactive shell used by the Woodpecker local backend.
          ci = pkgs.mkShell {
            packages = [
              pkgs.elixir
              pkgs.hex
              pkgs.beamPackages.rebar3
              pkgs.git
              pkgs.stdenv.cc
              pkgs.gnumake
              pkgs.pkg-config
              pkgs.cargo
              pkgs.rustc
              pkgs.rustfmt
              # apps/tackle_web's tests run against a throwaway cluster.
              pkgs.postgresql
            ];
            shellHook = ciShellHook;
          };
        }
      );
      formatter = forAllSystems (
        {
          pkgs,
          system,
        }:
        treefmtEval.${system}.config.build.wrapper
      );
    };

}
