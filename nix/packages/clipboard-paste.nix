{ pkgs }:

# Runs on the host, never inside the jail. The user (or a host hotkey) explicitly
# chooses when a clipboard image crosses the boundary.
pkgs.writeShellApplication {
  name = "tackle-clipboard-paste";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
  ];
  text = ''
    usage() { echo "Usage: tackle-clipboard-paste SESSION-ID" >&2; exit 2; }
    if [[ $# != 1 || ! "$1" =~ ^tackle-paste-[a-zA-Z0-9]+$ ]]; then usage; fi
    id="$1"
    # The launcher creates this directory with mktemp, mode 0700. Never take
    # an arbitrary path from an untrusted argument.
    dir="/tmp/$id"
    if [[ ! -d "$dir" || -L "$dir" || $(stat -c %u "$dir") != "$UID" || $(stat -c %a "$dir") != 700 ]]; then
      echo "No live Tackle paste session: $id" >&2
      exit 1
    fi
    tmp=$(mktemp "$dir/.incoming.XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    # head bounds memory/disk usage; check the producer too so a timeout or
    # clipboard failure cannot publish a truncated (but magic-valid) image.
    set +o pipefail
    if [[ -n "''${WAYLAND_DISPLAY:-}" ]] && command -v wl-paste >/dev/null; then
      if ! timeout 5s wl-paste --list-types | grep -qx 'image/png'; then
        echo "Clipboard does not offer image/png" >&2; exit 1
      fi
      timeout 5s wl-paste --type image/png | head -c 5242881 > "$tmp"
      statuses=("''${PIPESTATUS[@]}")
    elif [[ -n "''${DISPLAY:-}" ]] && command -v xclip >/dev/null; then
      if ! timeout 5s xclip -selection clipboard -t TARGETS -o 2>/dev/null | grep -qx 'image/png'; then
        echo "Clipboard does not offer image/png" >&2; exit 1
      fi
      timeout 5s xclip -selection clipboard -t image/png -o | head -c 5242881 > "$tmp"
      statuses=("''${PIPESTATUS[@]}")
    else
      echo "Install wl-paste (Wayland) or xclip (X11) on the host" >&2; exit 1
    fi
    if [[ "''${statuses[1]}" != 0 || ( "''${statuses[0]}" != 0 && "''${statuses[0]}" != 141 ) ]]; then
      echo "Host clipboard read failed" >&2; exit 1
    fi
    size=$(wc -c < "$tmp")
    if (( size < 8 || size > 5242880 )) || ! head -c 8 "$tmp" | cmp -s - <(printf '\211PNG\r\n\032\n'); then
      echo "Clipboard image is not a PNG of at most 5 MiB" >&2; exit 1
    fi
    # Rename in the same directory publishes a fully written image atomically.
    chmod 600 "$tmp"
    mv -- "$tmp" "$dir/image-$(printf '%019d' "$(date +%s%N)")-$$.png"
    trap - EXIT
    echo "Image queued for Tackle session $id"
  '';
}
