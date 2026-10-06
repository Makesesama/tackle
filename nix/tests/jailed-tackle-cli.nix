{
  pkgs,
  mkJail,
  productionJail,
}:

let
  probe = pkgs.writeShellApplication {
    name = "tackle-jail-probe";
    text = ''
      test "$TACKLE_HOME" = "$HOME/.tackle"
      test "$TACKLE_CLI_INSTALL_DIR" = "$TACKLE_HOME/burrito"
      test ! -e "$HOME/host-only"
      test ! -e "$HOME/.config/ketch/host-only"
      ketch --help > /dev/null
      if [[ "$1" = missing-config ]]; then
        test ! -e "$HOME/.config/ketch/config.json"
        printf 'Ketch without config: OK\n'
        exit 0
      fi
      test "$(cat "$HOME/.config/ketch/config.json")" = '{}'
      test "$NIX_REMOTE" = daemon
      test -S /nix/var/nix/daemon-socket/socket

      # No network, credentials, nixpkgs fetch, or model call. A unique name
      # forces a new output, checking visibility after the jail has started.
      # shellcheck disable=SC2016
      output=$(nix build --offline --no-link --print-out-paths --expr '
        derivation {
          name = "tackle-jail-smoke-'"$1"'";
          system = "${pkgs.stdenv.hostPlatform.system}";
          builder = "${pkgs.bash}/bin/bash";
          args = [ "-c" "echo built-inside-jail > $out" ];
        }
      ')
      test "$(cat "$output")" = built-inside-jail
      ln -s "$output" result
      test "$(cat result)" = built-inside-jail
      printf 'Nix build inside jail: OK\n'
    '';
  };
  probeJail = mkJail probe;
in
# Run on a Linux host, not in a Nix build sandbox: Bubblewrap needs user
# namespaces and this test intentionally requires access to the host daemon.
pkgs.writeShellApplication {
  name = "test-jailed-tackle-cli";
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    mkdir -p "$work/home/.config/ketch" "$work/project"
    export HOME="$work/home"
    touch "$HOME/host-only" "$HOME/.config/ketch/host-only"
    export LANG=C.UTF-8
    export TERM="''${TERM:-xterm}"
    cd "$work/project"
    ${pkgs.lib.getExe probeJail} missing-config
    printf '{}\n' > "$HOME/.config/ketch/config.json"
    ${pkgs.lib.getExe probeJail} "$(date +%s%N)-$$"
    ${pkgs.lib.getExe productionJail} --version
    ${pkgs.lib.getExe productionJail} --help
    ${pkgs.lib.getExe productionJail} models
    test -d "$HOME/.tackle/burrito/.burrito"
    printf 'Production jailed CLI: OK\n'
  '';
}
