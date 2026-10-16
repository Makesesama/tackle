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
      }
      // args
    );
  package = mkReviewJail { };
in
package.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    tests.smoke = import ../tests/review-jail.nix {
      inherit pkgs mkReviewJail;
      productionJail = package;
    };
  };
})
