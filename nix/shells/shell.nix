{
  pkgs,
  package,
  commonShellHook,
  preCommitCheck,
  jailedTackle ? null,
}:

let
  platformPackages =
    with pkgs;
    lib.optionals stdenv.hostPlatform.isLinux [
      inotify-tools
      util-linux
    ]
    ++ lib.optionals stdenv.isDarwin (
      with darwin.apple_sdk.frameworks;
      [
        CoreServices
        Foundation
      ]
    );
in
pkgs.mkShell {
  buildInputs = preCommitCheck.enabledPackages;
  inputsFrom = [ package ];
  packages = [
    # Language servers
    pkgs.beamPackages.expert

    # Build tools
    pkgs.cargo
    pkgs.rustc
    pkgs.watchman

    # Development tools
    pkgs.rustfmt
    pkgs.clippy
    pkgs.tokei
  ]
  ++ platformPackages
  ++ pkgs.lib.optional (jailedTackle != null) jailedTackle;
  shellHook = commonShellHook;
}
