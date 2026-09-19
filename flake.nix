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
              credo.enable = true;
              credo.package = pkgs.elixir;
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

          # Common shell hook for both environments
          commonShellHook = ''
            ${preCommitCheck.shellHook}
              # Enable Tackle development-only behaviour (e.g. the elixir_eval tool)
              export TACKLE_DEV=1

              # forcola ships a shim linked against the FHS loader, which does
              # not exist on NixOS. Build it from source (cargo is on PATH)
              # instead of letting the package download the precompiled binary.
              export FORCOLA_BUILD=1

              # Set up `mix` to save dependencies to the local directory
              mkdir -p .nix-mix
              mkdir -p .nix-hex
              export MIX_HOME=$PWD/.nix-mix
              export HEX_HOME=$PWD/.nix-hex
              export PATH=$MIX_HOME/bin:$PATH
              export PATH=$HEX_HOME/bin:$PATH

              # BEAM-specific. C.UTF-8 is available without a separately
              # mounted locale archive, including inside jailed-tackle.
              export LANG=C.UTF-8
              export ERL_AFLAGS="-kernel shell_history enabled"
          '';
        in
        {
          # Development shell with all tools
          default = pkgs.callPackage ./nix/shells/shell.nix {
            inherit preCommitCheck commonShellHook jailedTackle;
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
