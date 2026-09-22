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
      packages = forAllSystems (
        {
          pkgs,
          system,
        }:
        let
          package = pkgs.callPackage ./nix/packages { };
        in
        {
          default = package;
          tackle-cli = package;
          tackle-web = pkgs.callPackage ./nix/packages/tackle-web.nix { };
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
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
        {
          pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              credo = {
                enable = true;
                package = pkgs.elixir;
                entry = "${pkgs.bash}/bin/bash -c 'cd packages/tackle && exec mix credo --strict'";
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
          '';

          commonShellHook = ''
            ${preCommitCheck.shellHook}
            ${projectShellHook}

            # Enable Tackle development-only behaviour (e.g. elixir_eval).
            export TACKLE_DEV=1
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
              pkgs.tailwindcss_4
              pkgs.esbuild
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
