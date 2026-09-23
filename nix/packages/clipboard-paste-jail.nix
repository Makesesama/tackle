{ pkgs, jail }:

# A host-only staging directory: jailed code sees completed images read-only.
# The narrow host channel lets jailed code request a PNG clipboard read, but
# does not expose the compositor or allow it to publish arbitrary files.
[
  (jail.add-runtime ''
    TACKLE_PASTE_HOST_DIR=$(mktemp -d /tmp/tackle-paste-XXXXXXXX)
    export TACKLE_PASTE_HOST_DIR
    chmod 700 "$TACKLE_PASTE_HOST_DIR"
    RUNTIME_ARGS+=(--ro-bind "$TACKLE_PASTE_HOST_DIR" /run/tackle-paste)
    echo "Host image paste: tackle-clipboard-paste ''${TACKLE_PASTE_HOST_DIR##*/} (run on host after copying an image)" >&2
  '')
  (jail.add-cleanup ''
    if [[ -n "''${TACKLE_PASTE_HOST_DIR:-}" ]]; then
      ${pkgs.coreutils}/bin/rm -rf -- "$TACKLE_PASTE_HOST_DIR"
    fi
  '')
  # The channel carries only a paste intent and a short status, never image
  # bytes. The host publishes into the existing read-only staging mount.
  (jail.jail-to-host-channel "tacklePasteRequest" ''
    if [[ "''${1:-}" == paste && -n "''${TACKLE_PASTE_HOST_DIR:-}" ]] &&
       ${
         pkgs.lib.getExe (pkgs.callPackage ./clipboard-paste.nix { })
       } "''${TACKLE_PASTE_HOST_DIR##*/}" >/dev/null 2>&1; then
      printf 'ok\n'
    else
      printf 'unavailable\n'
    fi
    # jail-to-host-channel stops listening if its handler fails. A missing
    # clipboard image must not kill the listener for the rest of the session.
    exit 0
  '')
  (jail.set-env "TACKLE_CLIPBOARD_PASTE_DIR" "/run/tackle-paste")
  (jail.set-env "TACKLE_CLIPBOARD_PASTE_CMD" "tacklePasteRequest")
]
