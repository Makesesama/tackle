{
  pkgs,
  package,
  commonShellHook,
  preCommitCheck,
}:

let
  platformPackages =
    with pkgs;
    lib.optional stdenv.isLinux inotify-tools
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
  ++ platformPackages;
  shellHook = commonShellHook;
}
