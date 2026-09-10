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
    lib.optional stdenv.hostPlatform.isLinux inotify-tools
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
    pkgs.watchman

    # Development tools
    pkgs.tokei
  ]
  ++ platformPackages
  ++ pkgs.lib.optional (jailedTackle != null) jailedTackle;
  shellHook = commonShellHook;
}
