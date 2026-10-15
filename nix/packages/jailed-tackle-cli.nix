{
  pkgs,
  lib,
  jailed-agents,
  system,
  tackle-cli,
  # Git configuration for the agent's commands; see exec-jail.nix. Set the
  # commit identity here, since the jail does not see the host's:
  #   tackle-cli-jail.override {
  #     gitConfig.user = { name = "Ada Lovelace"; email = "ada@example.com"; };
  #   }
  gitConfig ? { },
}:

# `tackle` on the host, with every command and workspace file access in a
# Bubblewrap jail. The CLI keeps credentials (~/.tackle), sessions, and the
# clipboard; the jail sees only the project directory and the Nix store.
#
# The jail also reproduces the project's cached nix-direnv devshell, so the
# agent finds `mix`, `cargo`, and the rest of the toolchain on PATH rather than
# searching the store for them. See jail-direnv.nix.
let
  mkExecJail =
    args:
    pkgs.callPackage ./exec-jail.nix (
      {
        inherit jailed-agents system;
      }
      // args
    );

  # Tools the agent's commands get besides the jail's common utilities. The
  # smoke test builds its probes with the same list, so it verifies what this
  # package actually ships.
  jailTools = [ (pkgs.callPackage ./jail-python.nix { }) ];

  execJail = mkExecJail {
    inheritDirenv = true;
    extraPkgs = jailTools;
    inherit gitConfig;
  };

  package = pkgs.writeShellApplication {
    name = "tackle";
    text = ''
      export TACKLE_EXEC_LAUNCHER=${lib.getExe execJail}
      exec ${lib.getExe tackle-cli} "$@"
    '';
  };
in
package.overrideAttrs (old: {
  # The store derivation and flake output describe the package; the program
  # and meta.mainProgram remain "tackle".
  name = "tackle-cli-jail";
  passthru = (old.passthru or { }) // {
    inherit execJail;
    tests.smoke = import ../tests/jailed-tackle-cli.nix {
      inherit
        pkgs
        mkExecJail
        execJail
        jailTools
        ;
      productionJail = package;
    };
  };
})
