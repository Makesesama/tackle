{
  pkgs,
  jail,
}:

# Inherits the project's nix-direnv devshell inside the jail.
#
# The CLI starts the launcher with only PATH, HOME, LANG, LC_ALL, TERM, and
# XDG_CACHE_HOME (Tackle.CLI.Jail), so the direnv environment of the shell
# Tackle was started from never reaches the jail. The jail does not need it:
# the launcher runs on the host with the workspace as its working directory,
# so it finds the cached `nix print-dev-env` profile that nix-direnv keeps for
# that directory and reproduces the devshell inside the jail. The agent then
# finds the project's toolchain, `mix`, `cargo`, `treefmt`, and so on, on PATH
# instead of searching /nix/store for it.
#
# Sourcing the cached profile runs the devshell's shellHook inside the jail.
# That is code the user already approved with `direnv allow` on the host; the
# cache files themselves live outside the workspace and are bound read-only.
#
# A cached devshell only names /nix/store paths, so this needs the store
# mounted; exec-jail.nix asserts that.
let
  combinators = jail.combinators;

  coreutils = pkgs.coreutils;
  findutils = pkgs.findutils;

  # Sourced through BASH_ENV by every non-interactive `bash -c` the agent's
  # commands spawn. It selects the cached devshell for that command's $PWD and
  # sources it when it differs from the one the jail already has, so a command
  # in a nested devshell (`cd subdir && mix test`) gets that devshell too.
  hook = pkgs.writeShellScript "tackle-jail-direnv-hook" ''
    _tackle_direnv_rc_for() {
      local dir rc best_dir="" best_rc=""
      while IFS=$'\t' read -r dir rc; do
        if [ -n "$dir" ] && [ -n "$rc" ]; then
          case "''${PWD:-$(pwd)}/" in
            "$dir/"*)
              if [ "''${#dir}" -gt "''${#best_dir}" ]; then
                best_dir="$dir"
                best_rc="$rc"
              fi
              ;;
          esac
        fi
      done <<< "$TACKLE_DIRENV_RC_MAP"
      printf '%s' "$best_rc"
    }

    _tackle_direnv_sync() {
      if [ -z "''${TACKLE_DIRENV_RC_MAP:-}" ]; then
        return 0
      fi

      local rc errexit=0 nounset=0 had_pipefail=0 jail_path
      rc="$(_tackle_direnv_rc_for)"
      # The jail already sourced the devshell for the directory the CLI
      # started in, so most commands have nothing to do here.
      if [ -z "$rc" ] || [ "$rc" = "''${TACKLE_DIRENV_RC_ACTIVE:-}" ] || [ ! -f "$rc" ]; then
        return 0
      fi

      jail_path="''${TACKLE_JAIL_PATH:-$PATH}"
      case "$-" in *e*) errexit=1 ;; esac
      case "$-" in *u*) nounset=1 ;; esac

      export _TACKLE_DIRENV_HOOK_ACTIVE=1
      PATH="''${PATH:-}"
      XDG_DATA_DIRS="''${XDG_DATA_DIRS:-}"
      # Sourced with errexit, nounset, and pipefail off: the rc ends by
      # running the user's shellHook, which direnv runs in a plain shell, so a
      # failing command or pipeline in it must not abort the agent's command
      # or the jail. Its output goes to the jail log rather than to standard
      # output, which carries the exec-server protocol.
      if [[ -o pipefail ]]; then had_pipefail=1; fi
      set +e +u +o pipefail
      eval "$(<"$rc")" >&2
      if [ "$errexit" = 1 ]; then set -e; else set +e; fi
      if [ "$nounset" = 1 ]; then set -u; else set +u; fi
      if [ "$had_pipefail" = 1 ]; then set -o pipefail; else set +o pipefail; fi
      unset _TACKLE_DIRENV_HOOK_ACTIVE

      # The devshell describes the host environment: keep the jail's own
      # tools, its locale, and this hook.
      export PATH="''${PATH}:$jail_path"
      export LANG=C.UTF-8 LC_ALL=C.UTF-8
      if [ -n "''${TACKLE_DIRENV_HOOK:-}" ]; then
        export BASH_ENV="$TACKLE_DIRENV_HOOK"
      fi
      export TACKLE_DIRENV_RC_ACTIVE="$rc"

      # `nix print-dev-env` creates a fresh /tmp/nix-shell.* directory and
      # points TMPDIR and friends at it; nix-direnv removes it the same way.
      if [ -n "''${NIX_BUILD_TOP:-}" ] && [[ "$NIX_BUILD_TOP" == */nix-shell.* ]] &&
        [ -d "$NIX_BUILD_TOP" ]; then
        rm -rf "$NIX_BUILD_TOP"
      fi
      unset NIX_BUILD_TOP TMP TMPDIR TEMP TEMPDIR
      return 0
    }

    # Every `bash -c` starts a fresh shell, so without this a `cd` inside one
    # command would keep the devshell selected for its starting directory.
    if [ -z "''${_TACKLE_DIRENV_WRAPPED:-}" ]; then
      # Unexported, so every new shell wraps its own `cd`.
      _TACKLE_DIRENV_WRAPPED=1
      cd() { builtin cd "$@" && _tackle_direnv_sync; }
      pushd() { builtin pushd "$@" && _tackle_direnv_sync; }
      popd() { builtin popd "$@" && _tackle_direnv_sync; }
      if [ -z "''${PROMPT_COMMAND:-}" ]; then
        PROMPT_COMMAND="_tackle_direnv_sync"
      else
        PROMPT_COMMAND="_tackle_direnv_sync;''${PROMPT_COMMAND}"
      fi
    fi

    _tackle_direnv_sync || true
  '';
in
{
  inherit hook;

  # Appended after the jail's own options (exec-jail.nix), so the rc binds
  # land after the read-write workspace mount.
  combinators = [
    # The launcher computes the map; the jail only reads it.
    (combinators.try-fwd-env "TACKLE_DIRENV_RC_MAP")
    (combinators.add-runtime ''
      # Locate the nix-direnv cache for this project. The CLI starts the
      # launcher with a filtered environment, so the direnv variables of the
      # user's shell are not available; the cache itself is on disk.
      #
      # The devshell is a bonus: a failure below must not stop the jail, so
      # errexit stays off for the whole block.
      set +e
      _tackle_direnv_cache="''${XDG_CACHE_HOME:-$HOME/.cache}/direnv/layouts"
      _tackle_direnv_map=""
      _tackle_saw_envrc=""

      # Newest cached `nix print-dev-env` rc in a layout directory.
      _tackle_rc_in_layout() {
        local entry newest=""
        for entry in "$1"/*flake-profile*.rc "$1"/*nix-profile*.rc; do
          if [ -f "$entry" ]; then
            if [ -z "$newest" ] || [ "$entry" -nt "$newest" ]; then
              newest="$entry"
            fi
          fi
        done
        printf '%s' "$newest"
      }

      # The rc direnv uses for a directory. nix-direnv keys its cache on the
      # directory direnv was activated for: `$dir/.direnv` by default, or
      # `$XDG_CACHE_HOME/direnv/layouts/<sha1(path)><sanitised path>` for the
      # layout direnv's wiki recommends.
      _tackle_rc_for() {
        local dir="$1" candidate found best="" hash slug
        # direnv hashes <<< "$PWD", including the newline; slice in bash
        # rather than piping, since the launcher runs with `pipefail`.
        hash="$(${coreutils}/bin/sha1sum <<< "$dir")"
        hash="''${hash:0:40}"
        slug="''${dir//[^a-zA-Z0-9]/-}"
        for candidate in "$_tackle_direnv_cache/$hash$slug" "$dir/.direnv"; do
          found="$(_tackle_rc_in_layout "$candidate")"
          if [ -n "$found" ]; then
            if [ -z "$best" ] || [ "$found" -nt "$best" ]; then
              best="$found"
            fi
          fi
        done
        printf '%s' "$best"
      }

      # Records the rc for a directory, and binds it when it is outside the
      # workspace, which is mounted read-write already.
      _tackle_record() {
        local dir="$1" rc
        rc="$(_tackle_rc_for "$dir")"
        if [ -z "$rc" ]; then
          return 0
        fi
        case "$rc" in
          "$PWD"/*) ;;
          *) RUNTIME_ARGS+=(--ro-bind-try "$rc" "$rc") ;;
        esac
        _tackle_direnv_map="''${_tackle_direnv_map}''${dir}"$'\t'"''${rc}"$'\n'
        return 0
      }

      # The working directory is where the user started the CLI, which is the
      # directory direnv was activated for. Its ancestors cover a devshell for
      # a parent project, which is what direnv gives the user in a subdirectory.
      _tackle_dir="$PWD"
      while [ -n "$_tackle_dir" ] && [ "$_tackle_dir" != "/" ]; do
        if [ -z "$_tackle_saw_envrc" ] && [ -e "$_tackle_dir/.envrc" ]; then
          _tackle_saw_envrc="$_tackle_dir"
        fi
        _tackle_record "$_tackle_dir"
        _tackle_dir="$(${coreutils}/bin/dirname "$_tackle_dir")"
      done

      # Nested projects: devshells the agent reaches by changing directory.
      while IFS= read -r _tackle_envrc; do
        if [ -n "$_tackle_envrc" ]; then
          if [ -z "$_tackle_saw_envrc" ]; then
            _tackle_saw_envrc="''${_tackle_envrc%/.envrc}"
          fi
          _tackle_record "''${_tackle_envrc%/.envrc}"
        fi
      done < <(${findutils}/bin/find "$PWD" -maxdepth 6 \
        \( -name .git -o -name node_modules -o -name _build -o -name deps \
        -o -name .direnv -o -name result \) -prune \
        -o -name .envrc -type f -print 2>/dev/null || true)
      unset _tackle_envrc _tackle_dir

      if [ -n "$_tackle_direnv_map" ]; then
        export TACKLE_DIRENV_RC_MAP="$_tackle_direnv_map"
      elif [ -n "$_tackle_saw_envrc" ]; then
        # A project directory with an .envrc but no cache direnv can inherit:
        # say so instead of leaving the agent without its toolchain.
        echo "tackle-exec-jail: $_tackle_saw_envrc has no cached nix-direnv devshell; run 'direnv reload' there on the host to inherit its toolchain" >&2
      fi
      unset _tackle_direnv_map _tackle_direnv_cache _tackle_saw_envrc
      set -e
    '')
    # Reproduce the devshell for the workspace before the exec-server starts,
    # then let every command refresh it for its own $PWD.
    (combinators.wrap-entry (entry: ''
      export TACKLE_JAIL_PATH="$PATH"
      if [ -n "''${TACKLE_DIRENV_RC_MAP:-}" ]; then
        export TACKLE_DIRENV_HOOK=${hook}
        # The hook defines the functions and selects the devshell for $PWD.
        # shellcheck source=/dev/null
        . ${hook}
        export BASH_ENV=${hook}
      fi
      exec ${entry}
    ''))
  ];
}
