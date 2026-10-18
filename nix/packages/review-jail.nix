{
  pkgs,
  jailed-agents,
  system,
}:
let
  mkReviewJail =
    args:
    pkgs.callPackage ./exec-jail.nix (
      {
        inherit jailed-agents system;
        name = "tackle-review-jail";
        network = false;
        readOnlyWorkspace = true;
        enableNix = false;
        restrictSockets = true;
        # A review's commands are read-only searches; the service's cgroup
        # bounds memory and tasks as a whole (nix/modules/tackle-hub.nix).
        limits = {
          tmpfsSize = 256 * 1024 * 1024;
          fileSize = 256 * 1024 * 1024;
          oomScoreAdj = 1000;
        };
      }
      // args
    );
  package = mkReviewJail { };
in
package.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    # The same launcher around another program, for tests that probe the
    # jail from inside without speaking the exec-server protocol.
    withEntry =
      entry:
      mkReviewJail {
        name = "tackle-review-jail-probe";
        inherit entry;
      };
    tests.smoke = import ../tests/review-jail.nix {
      inherit pkgs mkReviewJail;
      productionJail = package;
    };
  };
})
