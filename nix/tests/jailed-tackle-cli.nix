{
  pkgs,
  mkExecJail,
  execJail,
  productionJail,
  # The tools `tackle-cli-jail` puts on the agent's PATH, so the probes below
  # run against the same jail the package ships.
  jailTools,
}:

# Credential-free host smoke test for the production jail. Run it on a Linux
# host, not in a Nix build sandbox: Bubblewrap needs user namespaces, and the
# Nix check intentionally uses the host daemon.
#
#   nix build .#tackle-cli-jail.tests.smoke && ./result/bin/test-jailed-tackle-cli
let
  inherit (pkgs) lib;
  beamPackages = pkgs.beamPackages;
  tackleExec = pkgs.callPackage ../packages/tackle-exec.nix { inherit beamPackages; };

  # Runs inside the jail, with the same policy as the exec-server, in place of
  # it. Its arguments are the host paths it must not see.
  probe = pkgs.writeShellApplication {
    name = "tackle-jail-probe";
    text = ''
      host_home=$1
      test ! -e "$host_home/host-only"
      test ! -e "$host_home/.tackle/auth.json"
      test ! -e "$HOME/host-only"
      test -z "''${TACKLE_SMOKE_SECRET:-}"
      test "$LANG" = C.UTF-8

      # The workspace is writable, except Git's host-executed settings.
      touch written-in-jail
      git status --short > /dev/null
      if touch .git/hooks/pre-commit 2> /dev/null; then exit 1; fi
      # Redirect stderr before the failing write: bash reports a failed
      # redirection to the still-original stderr, which would leak a
      # confusing "Read-only file system" line into the jail log.
      if printf '[core]\n' 2> /dev/null >> .git/config; then exit 1; fi
      if printf '[core]\n' 2> /dev/null >> .git/config.worktree; then exit 1; fi
      if mv .git .git-moved 2> /dev/null; then exit 1; fi
      # Linked worktrees are created on the host.
      if mkdir .git/worktrees/planted 2> /dev/null; then exit 1; fi

      # The configured Git identity commits, and jailed code cannot change it.
      test "$(git config --global user.name)" = 'Tackle Smoke'
      git commit --quiet --allow-empty -m 'identity from the jail'
      test "$(git log -1 --format='%an <%ae> %cn <%ce>')" = \
        'Tackle Smoke <smoke@tackle.invalid> Tackle Smoke <smoke@tackle.invalid>'
      if git config --global smoke.planted yes 2> /dev/null; then exit 1; fi

      ketch --help > /dev/null
      python3 -c 'import bs4, requests, yaml' > /dev/null
      test "$(cat "$HOME/.config/ketch/config.json")" = '{}'

      test "$NIX_REMOTE" = daemon
      test -S /nix/var/nix/daemon-socket/socket
      # No network, credentials, nixpkgs fetch, or model call. A unique name
      # forces a new output, checking visibility after the jail has started.
      # The builder path reaches the expression as plain text, so it carries no
      # derivation context: without storePath a sandboxed daemon (the NixOS
      # default) does not mount it into the build sandbox. --impure only allows
      # that builtin; --offline still forbids substituters.
      # shellcheck disable=SC2016
      output=$(nix build --impure --offline --no-link --print-out-paths --expr '
        let bash = builtins.storePath "${pkgs.bash}"; in
        derivation {
          name = "tackle-jail-smoke-'"$(date +%s%N)"'";
          system = "${pkgs.stdenv.hostPlatform.system}";
          builder = "''${bash}/bin/bash";
          args = [ "-c" "echo built-inside-jail > $out" ];
        }
      ')
      test "$(cat "$output")" = built-inside-jail
      printf 'Jail policy: OK\n'
    '';
  };
  probeJail = mkExecJail {
    name = "tackle-jail-probe";
    entry = probe;
    extraPkgs = jailTools;
    gitConfig.user = {
      name = "Tackle Smoke";
      email = "smoke@tackle.invalid";
    };
  };

  # Runs inside the jail from a linked worktree, as Herdr creates them, in
  # place of the exec-server. `$1` is the main checkout.
  worktreeProbe = pkgs.writeShellApplication {
    name = "tackle-jail-worktree-probe";
    text = ''
      main=$1
      # Git works: commits, branches, and stashes write objects, refs, and
      # reflogs in the common Git directory.
      git status --short > /dev/null
      echo jailed > from-worktree
      git add from-worktree
      git -c user.name=jail -c user.email=jail@localhost commit --quiet -m 'from the jail'
      git branch scratch
      echo stashed >> from-worktree
      git stash --quiet
      git stash pop --quiet
      git checkout --quiet -- from-worktree

      # The main checkout's Git directory is mounted, its files are not.
      test -d "$main/.git/objects"
      test ! -e "$main/README"

      # Everything else in the common directory is read-only: the main
      # checkout's state and settings, other worktrees' metadata, and new
      # entries such as commondir. Worktrees are created on the host.
      if printf '[core]\n' 2> /dev/null >> "$main/.git/config"; then exit 1; fi
      if touch "$main/.git/hooks/pre-commit" 2> /dev/null; then exit 1; fi
      if printf x 2> /dev/null >> "$main/.git/HEAD"; then exit 1; fi
      if printf x 2> /dev/null >> "$main/.git/index"; then exit 1; fi
      if printf x 2> /dev/null > "$main/.git/commondir"; then exit 1; fi
      if mkdir "$main/.git/worktrees/planted" 2> /dev/null; then exit 1; fi
      # Deleting a ref takes packed-refs.lock in the common directory.
      if git branch --quiet -d scratch 2> /dev/null; then exit 1; fi

      # The worktree's own pointers and configuration are read-only.
      gitdir=$(git rev-parse --absolute-git-dir)
      if printf '[core]\n' 2> /dev/null >> "$gitdir/config.worktree"; then exit 1; fi
      if printf x 2> /dev/null >> "$gitdir/commondir"; then exit 1; fi
      if printf x 2> /dev/null >> "$gitdir/gitdir"; then exit 1; fi
      if printf x 2> /dev/null >> .git; then exit 1; fi
      printf 'Linked worktree: OK\n'
    '';
  };
  worktreeProbeJail = mkExecJail {
    name = "tackle-jail-worktree-probe";
    entry = worktreeProbe;
    extraPkgs = jailTools;
  };

  # Runs inside the jail with the same policy as the exec-server, in place of
  # it. `$1` is `present` when a cached nix-direnv devshell exists for the
  # workspace and `none` when it does not. Named `-entry` to keep its path
  # distinct from the launcher of the same jail in the log.
  direnvProbe = pkgs.writeShellApplication {
    name = "tackle-jail-direnv-probe-entry";
    text = ''
      mode=$1
      # The devshell describes the host environment; the jail keeps its locale.
      test "$LANG" = C.UTF-8
      test "$LC_ALL" = C.UTF-8
      command -v jq > /dev/null

      case "$mode" in
        present)
          # The launcher sourced the devshell cached for the workspace, and
          # the jail kept its own tools and locale.
          test "$TACKLE_DIRENV_CANARY" = launch
          command -v hello > /dev/null
          # Commands inherit it without re-sourcing anything.
          test "$(bash -c 'echo "$TACKLE_DIRENV_CANARY"')" = launch
          # A nested devshell is selected from the command's own directory.
          test "$(bash -c 'cd sub && echo "$TACKLE_DIRENV_CANARY"')" = nested
          test -n "$(bash -c 'cd sub && command -v jq')"
          ;;
        none)
          # Nothing cached: the jail starts with its own environment only.
          test -z "''${TACKLE_DIRENV_CANARY:-}"
          test -z "''${TACKLE_DIRENV_RC_MAP:-}"
          test -z "''${BASH_ENV:-}"
          test "$(bash -c 'echo jailed')" = jailed
          ;;
        *)
          echo "tackle-jail-direnv-probe: unknown mode $mode" >&2
          exit 2
          ;;
      esac

      printf 'Jail devshell inheritance: OK (%s)\n' "$mode"
    '';
  };
  # The production launcher is built with `inheritDirenv = true`.
  direnvProbeJail = mkExecJail {
    name = "tackle-jail-direnv-probe";
    entry = direnvProbe;
    inheritDirenv = true;
    extraPkgs = jailTools;
  };

  # Drives the real exec-server through the protocol client, as the CLI does.
  client = pkgs.writeText "tackle-exec-smoke.exs" ''
    [launcher, log, host_home] = System.argv()
    cwd = File.cwd!()
    alias Tackle.Exec.Client

    {:ok, client} =
      Client.start_link(launcher: {launcher, [log]}, keep_env: ["PATH", "HOME", "LANG"])

    {:ok, %{type: :directory}} = Client.stat(client, cwd)
    {:error, :enoent} = Client.stat(client, Path.join(host_home, ".tackle/auth.json"))

    {:ok, ref} = Client.exec(client, ["sh", "-c", "echo jailed > out.txt; cat out.txt"], cwd: cwd)

    receive do
      {:tackle_exec, ^ref, {:data, "jailed\n"}} -> Client.ack(client, ref, 7)
    after
      10_000 -> raise "no command output"
    end

    receive do
      {:tackle_exec, ^ref, {:exit_status, 0}} -> :ok
    after
      10_000 -> raise "no exit status"
    end

    "jailed\n" = File.read!(Path.join(cwd, "out.txt"))
    IO.puts("Exec-server protocol: OK")
  '';
in
pkgs.writeShellApplication {
  name = "test-jailed-tackle-cli";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.git
    pkgs.gnugrep
    beamPackages.elixir
  ];
  text = ''
    # Not under /tmp: the jail replaces /tmp anyway, which would hide a leak.
    # Resolved, since the jail mounts resolved paths.
    work=$(mktemp -d -p "$(pwd -P)" .tackle-jail-smoke.XXXXXX)
    # The jail redirects its stderr to the log file inside $work, so a
    # failure would otherwise be silent. Keep the work dir for diagnosis.
    trap 'if [ "$?" -eq 0 ]; then rm -rf "$work"; else echo "smoke test failed; kept $work (exec-server log: $work/exec-server.log)" >&2; fi' EXIT
    mkdir -p "$work/home/.config/ketch" "$work/home/.tackle" "$work/project"
    export HOME="$work/home"
    touch "$HOME/host-only"
    printf '{"secret": true}\n' > "$HOME/.tackle/auth.json"
    printf '{}\n' > "$HOME/.config/ketch/config.json"
    export TACKLE_SMOKE_SECRET=leaked
    export LANG=C.UTF-8
    export TERM="''${TERM:-xterm}"

    cd "$work/project"
    git init --quiet
    log="$work/exec-server.log"

    ${lib.getExe probeJail} "$log" "$HOME"
    test -e written-in-jail
    test -f .git/config

    # A Git common directory planted in an earlier session blocks the launch.
    touch .git/commondir
    if ${lib.getExe probeJail} "$log" "$HOME"; then exit 1; fi
    rm .git/commondir
    printf 'Planted .git/commondir refused: OK\n'

    # Linked worktrees, as Herdr creates them, outside the main checkout:
    # one with absolute pointers and one with relative ones.
    printf 'main\n' > README
    git add README
    git -c user.name=host -c user.email=host@localhost commit --quiet -m init
    git worktree add --quiet "$work/worktree"
    git worktree add --quiet --relative-paths "$work/relative"
    for tree in worktree relative; do
      (cd "$work/$tree" && ${lib.getExe worktreeProbeJail} "$log" "$work/project")
      test "$(git -C "$work/$tree" log -1 --format=%s)" = 'from the jail'
      git -C "$work/$tree" branch --quiet -d scratch
    done

    # Refusals: a .git file aimed at another worktree's Git directory, a
    # moved worktree, and a commondir planted in the common Git directory.
    refused() {
      local dir=$1 message=$2
      : > "$log"
      if (cd "$dir" && ${lib.getExe worktreeProbeJail} "$log" "$work/project"); then exit 1; fi
      grep -qF -- "$message" "$log"
    }
    mkdir "$work/crafted"
    printf 'gitdir: %s\n' "$work/project/.git/worktrees/worktree" > "$work/crafted/.git"
    refused "$work/crafted" "crafted/.git; run 'git worktree repair'"
    mv "$work/relative" "$work/moved"
    refused "$work/moved" "moved/.git; run 'git worktree repair'"
    mv "$work/moved" "$work/relative"
    touch .git/commondir
    refused "$work/worktree" "project/.git/commondir"
    rm .git/commondir
    mkdir "$work/linked"
    ln -s "$work/project/.git" "$work/linked/.git"
    refused "$work/linked" "refusing the symbolic link $work/linked/.git"
    printf 'Crafted worktree pointers refused: OK\n'

    # nix-direnv inheritance: the launcher finds the devshell cached for the
    # workspace in the layout direnv's wiki recommends, and the one cached for
    # a nested project in direnv's default layout, and the jail sources them.
    project="$work/project"
    export XDG_CACHE_HOME="$HOME/.cache"
    hash=$(sha1sum <<< "$project")
    slug="''${project//[^a-zA-Z0-9]/-}"
    cache="$XDG_CACHE_HOME/direnv/layouts/''${hash:0:40}$slug"
    mkdir -p "$cache" "$project/sub/.direnv"
    cat > "$cache/flake-profile.rc" <<'EOF'
    export TACKLE_DIRENV_CANARY=launch
    export PATH="${pkgs.hello}/bin:''${PATH}"
    export LANG=xx_XX.UTF-8
    export LC_ALL=xx_XX.UTF-8
    EOF
    touch "$project/sub/.envrc"
    cat > "$project/sub/.direnv/flake-profile.rc" <<'EOF'
    export TACKLE_DIRENV_CANARY=nested
    EOF

    ${lib.getExe direnvProbeJail} "$log" present

    # A devshell that is no longer cached is not required: the jail still
    # starts, with its own environment only.
    rm -rf "$XDG_CACHE_HOME/direnv" "$project/sub/.direnv"
    ${lib.getExe direnvProbeJail} "$log" none
    printf 'nix-direnv devshell inheritance: OK\n'

    elixir -pa ${tackleExec}/lib/erlang/lib/tackle_exec-0.1.0/ebin \
      ${client} ${lib.getExe execJail} "$log" "$HOME"

    # The production CLI boots Tackle.Auth.Store on the host, which validates
    # the auth file. The canary is deliberately invalid (it only exists to
    # prove the jail cannot see it), so point the CLI at an empty Tackle home:
    # a missing auth file is the normal credential-free state. Keep Burrito
    # extraction out of the user's real ~/.tackle as well.
    mkdir -p "$work/tackle-home" "$work/burrito"
    TACKLE_HOME="$work/tackle-home" TACKLE_CLI_INSTALL_DIR="$work/burrito" \
      ${lib.getExe productionJail} --version
    TACKLE_HOME="$work/tackle-home" TACKLE_CLI_INSTALL_DIR="$work/burrito" \
      ${lib.getExe productionJail} --help > /dev/null
    printf 'Production jailed CLI: OK\n'
  '';
}
