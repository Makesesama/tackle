{
  pkgs,
  lib,
}:
let
  version = "0.1.0";
  src = ../..;

  deps = pkgs.callPackage ../deps.nix { };
  mixNixDeps = lib.filterAttrs (_name: value: lib.isDerivation value) deps;
in
pkgs.beamPackages.mixRelease {
  inherit
    src
    version
    mixNixDeps
    ;
  pname = "tackle";

  # Don't strip beam files — GNU strip corrupts BEAM file format,
  # breaking module attributes like @behaviour that Oban needs
  dontStrip = true;
}
