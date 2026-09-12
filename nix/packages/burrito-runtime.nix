{ pkgs, lib }:
let
  # Keep the compiler and the downloaded ERTS on the same OTP patch. Updating
  # nixpkgs must not silently select an artifact BEAM Machine hasn't published.
  version = "29.0.5";
  system = pkgs.stdenv.hostPlatform.system;
  cpu = pkgs.stdenv.hostPlatform.parsed.cpu.name;
  linux = pkgs.stdenv.hostPlatform.isLinux;
  base = "https://beam-machine-universal.b-cdn.net";
  query = "?please-respect-my-bandwidth-costs=thank-you";
  versions = "&openssl=3.5.1&musl=1.2.5";
  hashes = {
    aarch64-linux = "1b9cd527db2deb3d201f5495412dfe188a793d1ab9405806503797a37e2766ac";
    x86_64-linux = "ae18746fdd36e9b8295b27d24bf934f87f2c806b7ceff2900f491fa701dab7e0";
    aarch64-darwin = "fac64d8c0adaf342228fa872c91163f7fe0ae35baccb882d376a90e29dd1407b";
    x86_64-darwin = "fac64d8c0adaf342228fa872c91163f7fe0ae35baccb882d376a90e29dd1407b";
  };
  ertsUrl =
    base
    + (
      if linux then
        "/OTP-${version}/linux/${cpu}/any/otp_${version}_linux_any_${cpu}.tar.gz"
      else
        "/OTP-${version}/macos/universal/otp_${version}_macos_universal.tar.gz"
    )
    + query
    + versions;
  # Content hashes and URL identifiers from Burrito 1.6.0's FetchMusl step.
  muslHash =
    {
      x86_64 = "71c35316aff45bbfd243d8eb9bfc4a58b6eb97cee09514cd2030e145b68107fb";
      aarch64 = "6b558025200a5ed1308e2ce2675217afec71b6c5a9d561e52262ca948d59905e";
    }
    .${cpu};
  muslUrl = "${base}/musl/libc-musl-${muslHash}.so${query}";
  erts = pkgs.fetchurl {
    url = ertsUrl;
    sha256 = hashes.${system};
  };
  musl = pkgs.fetchurl {
    url = muslUrl;
    sha256 = muslHash;
  };
in
{
  inherit version;

  beamPackages = pkgs.beamPackages.overrideScope (
    final: prev: {
      erlang = prev.erlang.overrideAttrs {
        inherit version;
        src = pkgs.fetchurl {
          url = "https://github.com/erlang/otp/archive/refs/tags/OTP-${version}.tar.gz";
          sha256 = "c79e9990832b6b6b6deefb5c7460d55e231c270560e21c6d4e33ccfdfd360820";
        };
      };
      elixir = final.elixir_1_20;
    }
  );

  # Seed Burrito's ordinary cache rather than changing :precompiled to
  # :custom_erts: the latter disables Burrito's musl loader injection.
  # All HTTP happens in fixed-output fetchurl derivations, never in mix release.
  seedCache = ''
    mkdir -p "$XDG_CACHE_HOME/burrito_file_cache"
    cp ${erts} "$XDG_CACHE_HOME/burrito_file_cache/${lib.toUpper (builtins.hashString "sha1" ertsUrl)}"
  ''
  + lib.optionalString linux ''
    cp ${musl} "$XDG_CACHE_HOME/burrito_file_cache/${lib.toUpper (builtins.hashString "sha1" muslUrl)}"
  '';
}
