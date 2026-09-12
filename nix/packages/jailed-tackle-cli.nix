{
  pkgs,
  jailed-agents,
  system,
  tackle-cli,
}:

let
  jailedAgents = jailed-agents.lib.${system};
  jail = jailedAgents.internals.jail.combinators;

  # Keep the policy shared with the credential-free runtime smoke test.
  mkJail =
    pkg:
    jailedAgents.makeJailedAgent {
      name = "tackle";
      inherit pkg;
      configPaths = [ "~/.tackle" ];

      # Mount /nix read-only and the daemon socket read-write. Unlike a snapshot
      # of individual closures, this also exposes outputs built after launch.
      # This requires a multi-user host Nix installation (including nix.conf).
      enableNix = true;
      extraPkgs = [ tackle-cli ];
      fwdEnv = [
        "TERM"
        "COLORTERM"
        "NO_COLOR"
        "TACKLE_MODEL"
        "TACKLE_THINKING"
      ];
      env = {
        LANG = "C.UTF-8";
        LC_ALL = "C.UTF-8";
        # Do not let Nix fall back to opening the read-only host database locally.
        NIX_REMOTE = "daemon";
        NIX_CONFIG = "experimental-features = nix-command flakes";
        NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      };
      baseJailOptions = jailedAgents.commonJailOptions ++ [
        (jail.add-runtime ''
          if [[ ! -S /nix/var/nix/daemon-socket/socket ]]; then
            echo "tackle jail requires the host Nix daemon socket" >&2
            exit 2
          fi
          mkdir -p "$HOME/.tackle"
          chmod 700 "$HOME/.tackle"
        '')
        (jail.wrap-entry (entry: ''
          # Keep the extracted release persistent without exposing all user data.
          # Do not inherit dev-shell hooks, Mix paths, or TACKLE_DEV in production.
          export TACKLE_HOME="$HOME/.tackle"
          export TACKLE_CLI_INSTALL_DIR="$TACKLE_HOME/burrito"
          exec ${entry}
        ''))
      ];
    };

  package = mkJail tackle-cli;
in
package.overrideAttrs (old: {
  # The store derivation and flake output describe the package; the generated
  # launcher and meta.mainProgram remain "tackle".
  name = "tackle-cli-jail";
  passthru = (old.passthru or { }) // {
    tests.smoke = import ../tests/jailed-tackle-cli.nix {
      inherit pkgs mkJail;
      productionJail = package;
    };
  };
})
