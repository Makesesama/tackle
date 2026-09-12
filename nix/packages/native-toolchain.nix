{ pkgs }:
let
  fenix = import (builtins.fetchTarball {
    url = "https://github.com/nix-community/fenix/archive/6399553b7a300c77e7f07342904eb696a5b6bf9d.tar.gz";
    sha256 = "sha256-C6tT7K1Lx6VsYw1BY5S3OavtapUvEnDQtmQB5DSgbCc=";
  }) { inherit pkgs; };
  linux = pkgs.stdenv.hostPlatform.isLinux;
  cpu = pkgs.stdenv.hostPlatform.parsed.cpu.name;
  triple = if linux then "${cpu}-unknown-linux-musl" else "${cpu}-apple-darwin";
  rust = fenix.combine (
    [
      fenix.stable.rustc
      fenix.stable.cargo
    ]
    ++ pkgs.lib.optional linux fenix.targets.${triple}.stable.rust-std
  );
in
{
  inherit rust triple;
  cc = if linux then pkgs.pkgsMusl.stdenv.cc else pkgs.stdenv.cc;
}
